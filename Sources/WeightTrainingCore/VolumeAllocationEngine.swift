import Foundation

/// Applies the weekly-volume review after ordinary load/rep progression has
/// had the first chance to act. It can add one set and cannot write or accept
/// the result on the lifter's behalf.
public enum VolumeAllocationEngine {
    public static let ruleVersion = "weekly-volume-v1"

    public static func applyingWeeklyVolume(
        to recommendation: ExerciseRecommendation,
        exercise: Exercise,
        report: VolumeReport,
        maximumSetsPerExercise: Int = 8
    ) -> ExerciseRecommendation {
        guard recommendation.action == .hold,
              recommendation.evidence == .consistent,
              recommendation.reason == .noHeavierLoad
                || recommendation.reason == .loadStepTooLarge,
              !recommendation.sets.isEmpty,
              recommendation.sets.count < maximumSetsPerExercise else {
            return recommendation
        }

        let volumes = Dictionary(uniqueKeysWithValues: report.muscles.map { ($0.muscle, $0) })
        let primaryBelowBudget = exercise.muscles.compactMap { involvement -> Muscle? in
            guard involvement.role == .primary,
                  let volume = volumes[involvement.muscle],
                  volume.projectedSets < Double(volume.target.lowerBound) else { return nil }
            return involvement.muscle
        }
        guard !primaryBelowBudget.isEmpty else { return recommendation }

        // A set is rejected if any involved muscle would cross its ceiling.
        // Secondary credit matters here: adding a chest press can be blocked
        // by a triceps budget that is already full.
        guard exercise.muscles.allSatisfy({ involvement in
            guard let volume = volumes[involvement.muscle] else { return false }
            return volume.projectedSets + involvement.role.volumeWeight
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
