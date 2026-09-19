import Foundation

/// Accepted work that has not yet been logged. It is derived from an active
/// exercise plan and its current set rows; it is never a second stored total.
public struct PlannedExerciseWork: Hashable, Sendable {
    public let exerciseID: UUID
    public let remainingSets: Int

    public init(exerciseID: UUID, remainingSets: Int) {
        self.exerciseID = exerciseID
        self.remainingSets = max(0, remainingSets)
    }
}

/// How one muscle is doing against its weekly target.
public struct MuscleVolume: Hashable, Sendable, Identifiable {
    public var id: Muscle { muscle }
    public let muscle: Muscle

    /// Hard sets credited, counting secondary involvement as a half set.
    ///
    /// Fractional on purpose: a push day full of pressing gives the triceps
    /// real work, and rounding it to whole sets would either erase it or
    /// overstate it into a rest day nobody needs.
    public let sets: Double

    /// Completed working-set credit before the effort threshold is applied.
    public let totalWorkingSets: Double
    public let directSets: Double
    public let secondarySets: Double
    public let knownHardSets: Double
    public let unknownEffortSets: Double
    public let exerciseCount: Int
    public let exposureFrequency: Int
    /// Accepted sets still remaining in active workouts.
    public let plannedSets: Double

    public let target: ClosedRange<Int>

    public init(
        muscle: Muscle,
        sets: Double,
        target: ClosedRange<Int>,
        totalWorkingSets: Double? = nil,
        directSets: Double? = nil,
        secondarySets: Double = 0,
        knownHardSets: Double? = nil,
        unknownEffortSets: Double = 0,
        exerciseCount: Int = 0,
        exposureFrequency: Int = 0,
        plannedSets: Double = 0
    ) {
        self.muscle = muscle
        self.sets = sets
        self.target = target
        self.totalWorkingSets = totalWorkingSets ?? sets
        self.directSets = directSets ?? sets
        self.secondarySets = secondarySets
        self.knownHardSets = knownHardSets ?? max(0, sets - unknownEffortSets)
        self.unknownEffortSets = unknownEffortSets
        self.exerciseCount = exerciseCount
        self.exposureFrequency = exposureFrequency
        self.plannedSets = plannedSets
    }

    public enum Standing: Hashable, Sendable {
        /// Below the bottom of the band — the hole this report exists to find.
        case starved
        case onTarget
        /// Above the top of the band. Not a failure, but worth seeing before it
        /// becomes one.
        case overreaching
    }

    public var standing: Standing {
        if sets < Double(target.lowerBound) { return .starved }
        if sets > Double(target.upperBound) { return .overreaching }
        return .onTarget
    }

    /// How far through the band, 0 to 1, for a bar. Clamped, so overreaching
    /// reads as full rather than overflowing.
    public var progress: Double {
        guard target.upperBound > 0 else { return 0 }
        return min(1, sets / Double(target.upperBound))
    }

    public var projectedSets: Double { sets + plannedSets }
    public var remainingToMinimum: Double {
        max(0, Double(target.lowerBound) - projectedSets)
    }
    public var remainingToMaximum: Double {
        max(0, Double(target.upperBound) - projectedSets)
    }

    /// `4.5 of 10–20`.
    public var displayLine: String {
        let count = Self.format(sets)
        return "\(count) of \(target.lowerBound)–\(target.upperBound)"
    }


    public var effortLine: String {
        var parts = ["\(Self.format(totalWorkingSets)) working"]
        if knownHardSets > 0 { parts.append("\(Self.format(knownHardSets)) known hard") }
        if unknownEffortSets > 0 { parts.append("\(Self.format(unknownEffortSets)) effort unknown") }
        return parts.joined(separator: " · ")
    }

    public var detailLine: String {
        var parts = ["\(Self.format(directSets)) direct", "\(Self.format(secondarySets)) secondary"]
        if plannedSets > 0 { parts.append("\(Self.format(plannedSets)) planned") }
        return parts.joined(separator: " · ")
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

/// Weekly volume by muscle, over a rolling window.
///
/// The guard against flexible exercise selection quietly creating holes. Days
/// are shapes and slots offer choices (#16), which is what keeps a busy rack
/// from costing a session — but it also means nobody is counting, and a lift
/// skipped three times running is invisible until something stops growing.
public struct VolumeReport: Hashable, Sendable {

    /// The window in days. Rolling, never calendar weeks.
    ///
    /// A PPL cycle at three to four sessions a week drifts against the
    /// calendar, so "this week" would report a different answer depending on
    /// which day you asked. Seven days back from now always means the same
    /// thing.
    public static let windowDays = 7

    public let muscles: [MuscleVolume]
    public let from: Date
    public let to: Date

    public init(muscles: [MuscleVolume], from: Date, to: Date) {
        self.muscles = muscles
        self.from = from
        self.to = to
    }

    public var starved: [MuscleVolume] { muscles.filter { $0.standing == .starved } }
    public var overreaching: [MuscleVolume] { muscles.filter { $0.standing == .overreaching } }

    /// Builds the report.
    ///
    /// - Parameters:
    ///   - history: every set logged. Warmups and sets under RPE 7 are excluded
    ///     by `isHardSet`, so junk volume can't paper over a hole.
    ///   - exercises: needed for the muscle tags; a set on its own doesn't know
    ///     what it trained.
    public static func trailing(
        days: Int = windowDays,
        history: [SetRecord],
        exercises: [Exercise],
        budgets: [MuscleSetBudget] = MuscleSetBudget.defaults,
        plannedWork: [PlannedExerciseWork] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VolumeReport {
        let from = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        let budgetByMuscle = Dictionary(budgets.map { ($0.muscle, $0.target) },
                                        uniquingKeysWith: { _, latest in latest })
        var totals: [Muscle: Double] = [:]
        var totalWorking: [Muscle: Double] = [:]
        var direct: [Muscle: Double] = [:]
        var secondary: [Muscle: Double] = [:]
        var knownHard: [Muscle: Double] = [:]
        var unknownEffort: [Muscle: Double] = [:]
        var exerciseIDs: [Muscle: Set<UUID>] = [:]
        var exposureIDs: [Muscle: Set<String>] = [:]

        for set in history where !set.isWarmup && set.performedAt >= from && set.performedAt <= now {
            guard let exercise = byID[set.exerciseID] else { continue }
            for involvement in exercise.muscles {
                let muscle = involvement.muscle
                let credit = involvement.role.volumeWeight
                totalWorking[muscle, default: 0] += credit
                guard set.isHardSet else { continue }
                totals[muscle, default: 0] += credit
                if involvement.role == .primary {
                    direct[muscle, default: 0] += credit
                } else {
                    secondary[muscle, default: 0] += credit
                }
                if set.rpe == nil {
                    unknownEffort[muscle, default: 0] += credit
                } else {
                    knownHard[muscle, default: 0] += credit
                }
                exerciseIDs[muscle, default: []].insert(exercise.id)
                let exposure = set.workoutID.map { "workout:\($0.uuidString)" }
                    ?? "day:\(calendar.startOfDay(for: set.performedAt).timeIntervalSince1970)"
                exposureIDs[muscle, default: []].insert(exposure)
            }
        }

        var planned: [Muscle: Double] = [:]
        for work in plannedWork where work.remainingSets > 0 {
            guard let exercise = byID[work.exerciseID] else { continue }
            for involvement in exercise.muscles {
                planned[involvement.muscle, default: 0]
                    += Double(work.remainingSets) * involvement.role.volumeWeight
            }
        }

        // Every tracked muscle appears, including the ones on zero. A muscle
        // missing from the report is exactly the hole being looked for, so it
        // must not be missing from the list.
        let muscles = Muscle.allCases.map { muscle in
            MuscleVolume(
                muscle: muscle,
                sets: totals[muscle] ?? 0,
                target: budgetByMuscle[muscle] ?? muscle.weeklySetTarget,
                totalWorkingSets: totalWorking[muscle] ?? 0,
                directSets: direct[muscle] ?? 0,
                secondarySets: secondary[muscle] ?? 0,
                knownHardSets: knownHard[muscle] ?? 0,
                unknownEffortSets: unknownEffort[muscle] ?? 0,
                exerciseCount: exerciseIDs[muscle]?.count ?? 0,
                exposureFrequency: exposureIDs[muscle]?.count ?? 0,
                plannedSets: planned[muscle] ?? 0
            )
        }

        return VolumeReport(muscles: muscles, from: from, to: now)
    }
}
