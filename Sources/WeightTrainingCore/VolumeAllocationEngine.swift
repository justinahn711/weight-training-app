import Foundation

/// Applies the weekly-volume review after ordinary load/rep progression has
/// had the first chance to act. It can add one set and cannot write or accept
/// the result on the lifter's behalf.
public enum VolumeAllocationEngine {
    public static let ruleVersion = "weekly-volume-v1"

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
