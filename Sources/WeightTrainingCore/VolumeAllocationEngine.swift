import Foundation

/// Applies the weekly-volume review after ordinary load/rep progression has
/// had the first chance to act. It can add one set and cannot write or accept
/// the result on the lifter's behalf.
public enum VolumeAllocationEngine {
    public static let ruleVersion = "weekly-volume-v2"

    /// A fixed UTC week (Monday through Sunday), independent of locale, DST,
    /// screen openings, and when the lifter first installs the app.
    public static func allocationPeriod(containing date: Date) -> DateInterval {
        let duration: TimeInterval = 7 * 86_400
        let anchor: TimeInterval = 4 * 86_400 // Monday, 1970-01-05 UTC
        let start = anchor + floor((date.timeIntervalSince1970 - anchor) / duration) * duration
        return DateInterval(start: Date(timeIntervalSince1970: start), duration: duration)
    }

    public struct Candidate: Hashable, Sendable {
        public let exercise: Exercise
        public let recommendation: ExerciseRecommendation
        public let routineOrder: Int
        /// Larger values rank first; absent user priorities all have rank zero.
        public let priority: Int

        public init(exercise: Exercise, recommendation: ExerciseRecommendation,
                    routineOrder: Int, priority: Int = 0) {
            self.exercise = exercise
            self.recommendation = recommendation
            self.routineOrder = routineOrder
            self.priority = priority
        }
    }

    /// `report` includes logged work and other active/upcoming reservations,
    /// but excludes these candidates. Reserve every full baseline before
    /// choosing one extra set, including exercises not yet opened by the user.
    /// A repeated evaluation is pure: only an activated/reviewed decision can
    /// consume the allocation period in the persistence layer.
    public static func coordinating(
        _ candidates: [Candidate], report: VolumeReport,
        allocationAlreadyUsed: Bool = false, workloadIsKnown: Bool = true
    ) -> [UUID: ExerciseRecommendation] {
        var results = Dictionary(candidates.map { ($0.exercise.id, $0.recommendation) },
                                 uniquingKeysWith: { first, _ in first })
        guard !allocationAlreadyUsed, workloadIsKnown else { return results }
        let unique = Dictionary(candidates.map { ($0.exercise.id, $0) },
                                uniquingKeysWith: { first, _ in first }).values
        let reserved = report.muscles.map { volume in
            let credit = unique.reduce(0.0) { total, candidate in
                total + candidate.exercise.muscles.filter { $0.muscle == volume.muscle }
                    .reduce(0.0) { $0 + Double(candidate.recommendation.sets.count) * $1.role.volumeWeight }
            }
            return MuscleVolume(muscle: volume.muscle, sets: volume.sets, target: volume.target,
                                totalWorkingSets: volume.totalWorkingSets, directSets: volume.directSets,
                                secondarySets: volume.secondarySets, knownHardSets: volume.knownHardSets,
                                unknownEffortSets: volume.unknownEffortSets, exerciseCount: volume.exerciseCount,
                                exposureFrequency: volume.exposureFrequency,
                                plannedSets: volume.plannedSets + credit)
        }
        let fullReport = VolumeReport(muscles: reserved, from: report.from, to: report.to)
        let ranked = unique.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.routineOrder != $1.routineOrder { return $0.routineOrder < $1.routineOrder }
            return $0.exercise.id.uuidString < $1.exercise.id.uuidString
        }
        for candidate in ranked {
            let allocated = applyingWeeklyVolume(
                to: candidate.recommendation, exercise: candidate.exercise, report: fullReport,
                reservedSetsForExercise: candidate.recommendation.sets.count)
            if allocated.action == .addSet {
                results[candidate.exercise.id] = allocated
                break
            }
        }
        return results
    }

    /// `reservedSetsForExercise` counts only this candidate workout's baseline
    /// sets already included in `report.plannedSets`; use zero when its workout
    /// is excluded from the report. Other workouts' reservations remain intact.
    public static func applyingWeeklyVolume(
        to recommendation: ExerciseRecommendation,
        exercise: Exercise,
        report: VolumeReport,
        reservedSetsForExercise: Int = 0,
        maximumSetsPerExercise: Int = 8
    ) -> ExerciseRecommendation {
        guard (0...recommendation.sets.count).contains(reservedSetsForExercise),
              recommendation.exerciseID == exercise.id,
              recommendation.action == .hold,
              recommendation.evidence == .consistent,
              recommendation.reason == .noHeavierLoad
                || recommendation.reason == .loadStepTooLarge,
              !recommendation.sets.isEmpty,
              recommendation.sets.count < maximumSetsPerExercise else {
            return recommendation
        }

        let volumes = Dictionary(uniqueKeysWithValues: report.muscles.map { ($0.muscle, $0) })
        // The report may already reserve this workout's accepted remaining
        // sets. Everything else in the full proposed workout is new demand.
        let baselineSets = recommendation.sets.count - reservedSetsForExercise
        let proposedSets = baselineSets + 1
        let primaryBelowBudget = exercise.muscles.compactMap { involvement -> Muscle? in
            guard involvement.role == .primary,
                  let volume = volumes[involvement.muscle],
                  volume.projectedSets + Double(baselineSets) * involvement.role.volumeWeight
                    < Double(volume.target.lowerBound) else { return nil }
            return involvement.muscle
        }
        guard !primaryBelowBudget.isEmpty else { return recommendation }

        // Validate the full workout, not just its extra set: the report may
        // exclude the workout being proposed. Secondary credit matters too.
        guard exercise.muscles.allSatisfy({ involvement in
            guard let volume = volumes[involvement.muscle] else { return false }
            return volume.projectedSets + Double(proposedSets) * involvement.role.volumeWeight
                <= Double(volume.target.upperBound)
        }) else { return recommendation }

        var sets = recommendation.sets
        sets.append(sets.last!)
        return ExerciseRecommendation(
            exerciseID: recommendation.exerciseID,
            basedOnPlanID: recommendation.basedOnPlanID,
            generatedAt: recommendation.generatedAt,
            action: .addSet,
            sets: sets,
            reason: .weeklyVolumeBelowBudget(muscles: primaryBelowBudget),
            evidence: recommendation.evidence,
            supportingExposureIDs: recommendation.supportingExposureIDs,
            ruleVersion: "\(recommendation.ruleVersion)+\(ruleVersion)"
        )
    }
}
