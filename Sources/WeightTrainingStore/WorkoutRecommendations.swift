import Foundation
import WeightTrainingCore

extension TrainingStore {
    /// Builds one shared evidence snapshot and coordinates the entire roster
    /// before any exercise is activated. Reads never persist an allocation.
    public func workoutRecommendations(
        for roster: [Exercise], workoutID: UUID? = nil, now: Date = Date(),
        priorities: [UUID: Int] = [:]
    ) throws -> [UUID: ExerciseRecommendation] {
        try workoutRecommendations(
            for: roster, workoutID: workoutID, now: now, priorities: priorities,
            history: RecommendationHistory(sets: allSets(), sessions: exerciseSessions()),
            library: exercises(), config: gymConfig())
    }

    func workoutRecommendations(
        for roster: [Exercise], workoutID: UUID?, now: Date,
        priorities: [UUID: Int] = [:], history snapshot: RecommendationHistory,
        library: [Exercise], config: GymConfig
    ) throws -> [UUID: ExerciseRecommendation] {
        let history = snapshot.sets
        let sessions = snapshot.sessions
        let setsByExercise = snapshot.setsByExercise
        let sessionsByExercise = snapshot.sessionsByExercise
        let exposures = snapshot.exposures(excluding: workoutID)
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
            // Only sets done by `now` count as done, matching the trailing
            // history below. Counting later sets here while the history
            // omits them made a start-time view undercount the muscle, so
            // the recommendation a workout shows (as of its start) and the
            // one activation checks it against (as of now) disagreed, and
            // the lift couldn't be logged (#316 review).
            let completed = snapshot.records(exerciseID: session.exerciseID, workoutID: session.workoutID)
                .filter { !$0.isWarmup && $0.performedAt <= now }.count
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
                    let done = snapshot.records(exerciseID: id, workoutID: draft.id)
                        .filter { !$0.isWarmup && $0.performedAt <= now }.count
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

    /// A draft owns its precise order and substitutions. Before a draft exists,
    /// use the selected routine's due candidates; ad-hoc lifts stand alone.
    func recommendationRoster(
        for exercise: Exercise, workoutID: UUID?, library: [Exercise],
        history: [SetRecord], config: GymConfig
    ) throws -> [Exercise] {
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        if let workoutID, let draft = try workoutDraft(), draft.id == workoutID {
            var roster = draft.exerciseIDs.compactMap { byID[$0] }
            if !roster.contains(where: { $0.id == exercise.id }) { roster.append(exercise) }
            return roster
        }
        let templates = try storedTemplatesOrLibrary()
        if workoutID == nil, let template = templates.first(where: {
            $0.slots.contains { $0.candidateExerciseIDs.contains(exercise.id) }
        }) {
            let split = config.effectiveTrainingSplit
            let completed = CycleEngine.completedSessions(of: template.kind, history: history,
                                                           templates: templates, startingAt: split.startedAt)
            var roster = template.slots.compactMap { slot -> Exercise? in
                if slot.candidateExerciseIDs.contains(exercise.id) { return exercise }
                let candidates = [slot.dueCandidate(completionCount: completed)].compactMap { $0 } + slot.candidateExerciseIDs
                return candidates.lazy.compactMap { byID[$0] }.first
            }
            if !roster.contains(where: { $0.id == exercise.id }) { roster.append(exercise) }
            return roster
        }
        return [exercise]
    }
}
