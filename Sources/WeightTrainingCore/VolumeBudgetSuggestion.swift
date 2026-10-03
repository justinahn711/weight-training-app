import Foundation

/// A reviewable starting point for weekly set-credit targets.
///
/// Suggestions are derived from completed history and never applied by the
/// engine. The caller must show them to the lifter and persist an explicit
/// choice through `GymConfig.volumeBudgets`.
public struct VolumeBudgetSuggestion: Hashable, Sendable {
    public let budgets: [MuscleSetBudget]
    public let weeksAnalyzed: Int
    public let from: Date
    public let to: Date

    public init(budgets: [MuscleSetBudget], weeksAnalyzed: Int, from: Date, to: Date) {
        self.budgets = budgets
        self.weeksAnalyzed = weeksAnalyzed
        self.from = from
        self.to = to
    }
}

/// Derives optional set bands from recent weeks that were completed as
/// prescribed and reported at or below target effort.
public enum VolumeBudgetSuggestionEngine {
    public static let minimumWeeks = 2
    public static let maximumWeeks = 3

    public static func suggest(
        history: [ExerciseExposure],
        exercises: [Exercise],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VolumeBudgetSuggestion? {
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let completedWeeks = (1...maximumWeeks).compactMap { offset -> DateInterval? in
            guard let date = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek.start),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return nil }
            return interval
        }.reversed()

        let byExercise = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var eligible: [(interval: DateInterval, credits: [Muscle: Double])] = []

        for interval in completedWeeks {
            let week = history.filter {
                $0.completedAt >= interval.start && $0.completedAt < interval.end
            }
            // Consecutive evidence matters. A blank, shortened, painful, or
            // fatiguing week ends the run instead of being skipped over.
            guard !week.isEmpty, week.allSatisfy(isExplicitlyTolerated) else {
                eligible.removeAll()
                continue
            }

            var credits: [Muscle: Double] = [:]
            for exposure in week {
                guard let exercise = byExercise[exposure.exerciseID] else { continue }
                for set in exposure.workingSets where set.record.isHardSet {
                    for involvement in exercise.muscles {
                        credits[involvement.muscle, default: 0] += involvement.role.volumeWeight
                    }
                }
            }
            guard !credits.isEmpty else {
                eligible.removeAll()
                continue
            }
            eligible.append((interval, credits))
        }

        guard eligible.count >= minimumWeeks else { return nil }
        let considered = Array(eligible.suffix(maximumWeeks))
        let budgets = Muscle.allCases.compactMap { muscle -> MuscleSetBudget? in
            let samples = considered.compactMap { $0.credits[muscle] }
            // A zero week is missing evidence for this muscle, not evidence
            // that zero is a well-tolerated target.
            guard samples.count == considered.count, samples.allSatisfy({ $0 > 0 }) else { return nil }
            let sorted = samples.sorted()
            let median = sorted.count.isMultiple(of: 2)
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                : sorted[sorted.count / 2]
            let lower = Int(floor(min(sorted.first!, median * 0.9)))
            let upper = Int(ceil(max(sorted.last!, median * 1.1)))
            return MuscleSetBudget(muscle: muscle, minimum: lower, maximum: upper)
        }
        guard !budgets.isEmpty else { return nil }
        return VolumeBudgetSuggestion(
            budgets: budgets,
            weeksAnalyzed: considered.count,
            from: considered.first!.interval.start,
            to: considered.last!.interval.end
        )
    }

    private static func isExplicitlyTolerated(_ exposure: ExerciseExposure) -> Bool {
        guard exposure.completion == .completed,
              exposure.techniqueChanged != true,
              let plan = exposure.plan,
              exposure.workingSets.count == plan.sets.count else { return false }
        return zip(exposure.workingSets, plan.sets).allSatisfy { performed, target in
            performed.effortSource == .reported
                && performed.record.rpe.map { $0.value <= target.rpe.value } == true
                && performed.record.load == target.load
                && performed.record.reps >= target.reps
        }
    }
}
