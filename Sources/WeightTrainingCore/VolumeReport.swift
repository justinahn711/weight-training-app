import Foundation

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

    public let target: ClosedRange<Int>

    public init(muscle: Muscle, sets: Double, target: ClosedRange<Int>) {
        self.muscle = muscle
        self.sets = sets
        self.target = target
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

    /// `4.5 of 10–20`.
    public var displayLine: String {
        let count = sets == sets.rounded()
            ? String(format: "%.0f", sets)
            : String(format: "%.1f", sets)
        return "\(count) of \(target.lowerBound)–\(target.upperBound)"
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
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VolumeReport {
        let from = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        var totals: [Muscle: Double] = [:]
        for set in history where set.isHardSet && set.performedAt >= from && set.performedAt <= now {
            guard let exercise = byID[set.exerciseID] else { continue }
            for involvement in exercise.muscles {
                totals[involvement.muscle, default: 0] += involvement.role.volumeWeight
            }
        }

        // Every tracked muscle appears, including the ones on zero. A muscle
        // missing from the report is exactly the hole being looked for, so it
        // must not be missing from the list.
        let muscles = Muscle.allCases.map { muscle in
            MuscleVolume(
                muscle: muscle,
                sets: totals[muscle] ?? 0,
                target: muscle.weeklySetTarget
            )
        }

        return VolumeReport(muscles: muscles, from: from, to: now)
    }
}
