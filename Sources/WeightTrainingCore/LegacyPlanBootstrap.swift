import Foundation

/// Turns recent pre-plan history into a reviewable starting prescription.
/// Legacy sets cannot prove that a plan was completed or that effort was easy,
/// so this establishes a baseline only; it never earns progression.
public enum LegacyPlanBootstrapEngine {
    public static let ruleVersion = "legacy-plan-bootstrap-v2"

    public static func recommend(
        exercise: Exercise,
        history: [SetRecord],
        exposures: [ExerciseExposure] = [],
        context: RecommendationContext = RecommendationContext(),
        now: Date = Date(),
        freshness: TimeInterval = 21 * 86_400,
        calendar: Calendar = .current
    ) -> ExerciseRecommendation? {
        let pain = RecommendationEngine.latestPainExposure(
            exerciseID: exercise.id, history: exposures, now: now
        )
        if context.painReported || pain != nil {
            return ExerciseRecommendation(
                exerciseID: exercise.id, basedOnPlanID: nil, generatedAt: now,
                action: .stop, sets: [], reason: .pain, evidence: .insufficient,
                supportingExposureIDs: pain.map { [$0.id] } ?? [], ruleVersion: ruleVersion
            )
        }
        guard exercise.supportsPlannedProgression,
              now.timeIntervalSince1970.isFinite,
              freshness.isFinite,
              freshness > 0 else { return nil }
        let eligible = history.filter {
            $0.exerciseID == exercise.id
                && !$0.isWarmup
                && $0.performedAt <= now
                && $0.performedAt.timeIntervalSince1970.isFinite
        }
        guard let latest = LastPerformance.mostRecent(in: eligible, calendar: calendar),
              now.timeIntervalSince(latest.performedAt) <= freshness,
              let lightestRecentLoad = latest.sets.map(\.load).min()
        else { return nil }

        // Bodyweight history stores frozen total loads. Do not snap the
        // lifter's weight or flatten mixed weighted/unweighted sets into a new
        // prescription. A straight-set baseline must already be comparable.
        let load: Load
        if exercise.isBodyweight {
            guard lightestRecentLoad.pounds.isFinite,
                  lightestRecentLoad.pounds > 0, lightestRecentLoad.pounds <= 100_000,
                  latest.sets.allSatisfy({
                      $0.load.pounds.isFinite && abs($0.load.pounds - lightestRecentLoad.pounds) < 0.000_001
                  }) else { return nil }
            load = lightestRecentLoad
        } else {
            load = exercise.nearestAchievable(lightestRecentLoad)
            guard load >= exercise.lightestUsableLoad, exercise.canBuild(load) else { return nil }
        }
        let range = exercise.recommendationPolicy.repRange
        let targetRPE = exercise.progressionRule.displayRPETarget
        let targets = latest.sets.prefix(8).map {
            PlannedWorkingSet(
                load: load,
                reps: min(max($0.reps, range.bottom), range.top),
                rpe: targetRPE
            )
        }
        guard !targets.isEmpty else { return nil }

        return ExerciseRecommendation(
            exerciseID: exercise.id,
            basedOnPlanID: nil,
            generatedAt: now,
            action: .establish,
            sets: targets,
            reason: .legacyBaseline,
            evidence: .limited,
            supportingExposureIDs: [],
            ruleVersion: ruleVersion
        )
    }
}
