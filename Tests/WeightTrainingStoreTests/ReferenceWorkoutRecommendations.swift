// Frozen pre-indexing implementation: independent decision-equivalence oracle.
// Keep this read-only reference separate from production snapshot helpers.
@testable import WeightTrainingStore
import Foundation
import WeightTrainingCore

extension TrainingStore {
    /// Builds one shared evidence snapshot and coordinates the entire roster
    /// before any exercise is activated. Reads never persist an allocation.
    func referenceWorkoutRecommendations(
        for roster: [Exercise], workoutID: UUID? = nil, now: Date = Date(),
        priorities: [UUID: Int] = [:]
    ) throws -> [UUID: ExerciseRecommendation] {
        let history = try allSets()
        let sessions = try exerciseSessions()
        let library = try exercises()
        let config = try gymConfig()
        let setsByExercise = Dictionary(grouping: history, by: \.exerciseID)
        let sessionsByExercise = Dictionary(grouping: sessions, by: \.exerciseID)
        let exposures = sessions.filter { $0.workoutID != workoutID }.map { intent in
            let records = (setsByExercise[intent.exerciseID] ?? []).filter { $0.workoutID == intent.workoutID }
                .sorted {
                    if $0.performedAt != $1.performedAt { return $0.performedAt < $1.performedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            return ExerciseExposure(
                id: intent.workoutID, exerciseID: intent.exerciseID, plan: intent.plan,
                sets: records.map {
                    ExposureSet(record: $0, effortSource:
                        $0.effortWasReported == true && $0.acceptedPlanID == intent.plan?.id ? .reported : .unknown)
                },
                completion: intent.completedAt == nil ? .unknown : intent.completion,
                completedAt: intent.completedAt ?? max(intent.updatedAt, records.map(\.performedAt).max() ?? intent.updatedAt))
        }
        let exposuresByExercise = Dictionary(grouping: exposures, by: \.exerciseID)
        let adaptiveDeload = config.trainingBlock != nil
            && TrainingBlockEngine.adaptiveDeloadNeeded(history: exposures, now: now)
        let period = VolumeAllocationEngine.allocationPeriod(containing: now)
        let allocationUsed = sessions.contains { session in
            guard let trace = session.recommendationTrace, trace.action == .addSet else { return false }
            let decisionAt = trace.automaticallyActivatedAt ?? trace.generatedAt
            return decisionAt >= period.start && decisionAt < period.end
        }
        var candidates: [VolumeAllocationEngine.Candidate] = []
        var active: [UUID: ExerciseRecommendation] = [:]
        var workloadIsKnown = true
        var seen = Set<UUID>()
        for (order, exercise) in roster.enumerated() where seen.insert(exercise.id).inserted {
            let intents = sessionsByExercise[exercise.id] ?? []
            if let current = intents.first(where: { $0.workoutID == workoutID }), let plan = current.plan {
                // Return the historical display alongside the historical plan.
                // Its activation has already consumed any extra-set allocation.
                active[exercise.id] = current.recommendationTrace?.displayedRecommendation
                    ?? ExerciseRecommendation(exerciseID: exercise.id, basedOnPlanID: plan.id,
                        generatedAt: current.startedAt, action: plan.isDeload ? .deload : .hold,
                        sets: plan.sets, reason: plan.isDeload ? .acceptedDeload : .newPrescription,
                        evidence: .limited, supportingExposureIDs: [], ruleVersion: RecommendationEngine.ruleVersion)
                continue
            }
            let previous = intents.last { $0.workoutID != workoutID && $0.plan != nil }?.plan
            let exerciseExposures = exposuresByExercise[exercise.id] ?? []
            let base = previous == nil ? LegacyPlanBootstrapEngine.recommend(
                exercise: exercise,
                history: (setsByExercise[exercise.id] ?? []).filter { workoutID == nil || $0.workoutID != workoutID },
                exposures: exerciseExposures, now: now) : nil
            var recommendation = base ?? RecommendationEngine.recommend(
                exercise: exercise, plan: previous, history: exerciseExposures,
                policy: exercise.recommendationPolicy, now: now)
            if let previous {
                recommendation = TrainingBlockEngine.applyingDeload(
                    to: recommendation, plan: previous,
                    phase: config.trainingBlock.map { TrainingBlockEngine.phase(for: $0, now: now) }
                        ?? .accumulation(week: 1),
                    adaptiveDeload: adaptiveDeload,
                    resumePlan: intents.last { $0.workoutID != workoutID && $0.plan?.isDeload == false }?.plan)
            }
            // Unknown starting weights and unsupported movements still occupy
            // the routine; an empty target is not proof they require no work.
            if recommendation.sets.isEmpty && recommendation.action != .stop { workloadIsKnown = false }
            if !exercise.supportsPlannedProgression { workloadIsKnown = false }
            candidates.append(.init(exercise: exercise, recommendation: recommendation,
                                    routineOrder: order, priority: priorities[exercise.id] ?? 0))
        }

        // Keep sibling, overlapping workout, and dated future reservations.
        // Current unstarted candidates are supplied by the batch allocator.
        let from = now.addingTimeInterval(-7 * 86_400)
        let upcomingThrough = now.addingTimeInterval(7 * 86_400)
        var planned = sessions.compactMap { session -> PlannedExerciseWork? in
            guard session.completedAt == nil, session.startedAt >= from,
                  session.startedAt <= upcomingThrough, let plan = session.plan else { return nil }
            let completed = (setsByExercise[session.exerciseID] ?? []).filter {
                $0.workoutID == session.workoutID && !$0.isWarmup
            }.count
            return PlannedExerciseWork(exerciseID: session.exerciseID,
                                       remainingSets: max(0, plan.sets.count - completed))
        }
        // There is one draft today. If it is a different/upcoming session,
        // reserve its unactivated roster too, using known baseline targets.
        if let draft = try workoutDraft(), draft.id != workoutID,
           draft.startedAt >= from, draft.startedAt <= upcomingThrough {
            for id in draft.exerciseIDs {
                if sessions.contains(where: { $0.workoutID == draft.id && $0.exerciseID == id && $0.plan != nil }) { continue }
                if let plan = sessionsByExercise[id]?.last(where: { $0.plan != nil })?.plan {
                    let done = (setsByExercise[id] ?? []).filter { $0.workoutID == draft.id && !$0.isWarmup }.count
                    planned.append(.init(exerciseID: id, remainingSets: max(0, plan.sets.count - done)))
                } else { workloadIsKnown = false }
            }
        }
        let report = VolumeReport.trailing(history: history, exercises: library,
                                           budgets: config.volumeBudgets, plannedWork: planned, now: now)
        let coordinated = VolumeAllocationEngine.coordinating(candidates, report: report,
            allocationAlreadyUsed: allocationUsed, workloadIsKnown: workloadIsKnown)
        return coordinated.merging(active, uniquingKeysWith: { _, frozen in frozen })
    }

}
