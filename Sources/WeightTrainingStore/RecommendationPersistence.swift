import Foundation
import SwiftData
import WeightTrainingCore

public enum PlanStoreError: Error, LocalizedError {
    case workoutFinished, workingSetsAlreadyLogged, invalidPlan, exerciseChanged

    public var errorDescription: String? {
        switch self {
        case .workoutFinished: return "This workout has already finished. Start a new workout to log more work."
        case .workingSetsAlreadyLogged: return "Working sets are already logged. Set a new plan before your next workout."
        case .invalidPlan: return "Choose achievable weights and reps within this exercise's range."
        case .exerciseChanged: return "This exercise changed. Reopen the plan and review its targets."
        }
    }
}

extension TrainingStore {
    public func exerciseSessions() throws -> [RecordedExerciseSession] {
        let values = try modelContext.fetch(FetchDescriptor<StoredExerciseSession>()).map { try $0.toDomain() }
        return Dictionary(grouping: values, by: \.id).values.map { copies in
            let newest = copies.map(\.updatedAt).max()!
            let latest = copies.filter { $0.updatedAt == newest }
            var winner = latest[0]
            // Equal-time conflicts cannot prove which plan was followed.
            if latest.contains(where: { $0 != winner }) {
                winner.plan = nil
                winner.recommendationTrace = nil
                winner.completion = .unknown
                winner.completedAt = latest.compactMap(\.completedAt).max()
            }
            return winner
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }

    public func exerciseSession(workoutID: UUID, exerciseID: UUID) throws -> RecordedExerciseSession? {
        try exerciseSessions().first { $0.workoutID == workoutID && $0.exerciseID == exerciseID }
    }

    public func latestExercisePlan(for exerciseID: UUID, excluding workoutID: UUID? = nil) throws -> ExercisePlan? {
        try exerciseSessions().last { $0.exerciseID == exerciseID && $0.workoutID != workoutID && $0.plan != nil }?.plan
    }

    public func latestNonDeloadExercisePlan(
        for exerciseID: UUID, excluding workoutID: UUID? = nil
    ) throws -> ExercisePlan? {
        try exerciseSessions().last {
            $0.exerciseID == exerciseID && $0.workoutID != workoutID && $0.plan?.isDeload == false
        }?.plan
    }

    /// Accept before the first working set. Repeating an unchanged prescription
    /// preserves its revision ID; any accepted edit creates a fresh segment.
    @discardableResult
    public func acceptExercisePlan(
        _ proposed: ExercisePlan, workoutID: UUID, startedAt: Date, now: Date = Date()
    ) throws -> ExercisePlan {
        guard let exercise = try exercise(id: proposed.exercise.id), exercise == proposed.exercise else {
            throw PlanStoreError.exerciseChanged
        }
        var intent = try exerciseSession(workoutID: workoutID, exerciseID: exercise.id)
            ?? RecordedExerciseSession(workoutID: workoutID, exerciseID: exercise.id,
                                       startedAt: startedAt, updatedAt: now)
        guard intent.completedAt == nil else { throw PlanStoreError.workoutFinished }
        // Include legacy logs in a resumed old draft, but never turn them into
        // evidence by accepting a plan after the fact.
        guard try sets(forExercise: exercise.id).allSatisfy({
            $0.isWarmup || !($0.workoutID == workoutID || ($0.workoutID == nil && $0.performedAt >= startedAt))
        }) else { throw PlanStoreError.workingSetsAlreadyLogged }
        let checked = RecommendationEngine.recommend(
            exercise: exercise, plan: proposed, history: [], policy: exercise.recommendationPolicy, now: now)
        guard !checked.sets.isEmpty, checked.sets == proposed.sets,
              checked.reason == .newPrescription || checked.reason == .acceptedDeload else {
            throw PlanStoreError.invalidPlan
        }
        let previous: ExercisePlan?
        if let active = intent.plan {
            previous = active
        } else {
            previous = try latestExercisePlan(for: exercise.id, excluding: workoutID)
        }
        var accepted = ExercisePlan(exercise: exercise, sets: proposed.sets,
                                   restSeconds: proposed.restSeconds,
                                   techniqueRevision: proposed.techniqueRevision, isDeload: proposed.isDeload)
        if let previous {
            var comparable = accepted
            comparable = ExercisePlan(id: previous.id, exercise: comparable.exercise, sets: comparable.sets,
                                     restSeconds: comparable.restSeconds, techniqueRevision: comparable.techniqueRevision,
                                     isDeload: comparable.isDeload)
            if comparable == previous { accepted = previous }
        }
        if intent.recommendationTrace == nil {
            let recommendation = try recommendation(
                for: exercise, excluding: workoutID, now: now
            )
            if !recommendation.sets.isEmpty {
                intent.recommendationTrace = RecommendationTrace(recommendation: recommendation)
            }
        }
        intent.recommendationTrace?.recordDecision(for: accepted)
        intent.plan = accepted
        intent.updatedAt = now
        do {
            try writeExerciseSession(intent)
            try saveChanges()
        } catch { modelContext.rollback(); throw error }
        return accepted
    }

    /// Sets and their workout association land in one save. A lock-screen
    /// action can safely retry the same set ID without creating extra evidence.
    @discardableResult
    public func logWorkoutSet(
        _ record: SetRecord, workoutID: UUID, startedAt: Date, effortReported: Bool
    ) throws -> (record: SetRecord, inserted: Bool) {
        let setID = record.id
        let existing = try modelContext.fetch(FetchDescriptor<StoredSetLog>(predicate: #Predicate { $0.id == setID }))
        if let existing = existing.first {
            guard existing.workoutID == workoutID, existing.exerciseID == record.exerciseID else {
                throw PlanStoreError.exerciseChanged
            }
            return (existing.toDomain(), false)
        }
        var intent = try exerciseSession(workoutID: workoutID, exerciseID: record.exerciseID)
            ?? RecordedExerciseSession(workoutID: workoutID, exerciseID: record.exerciseID,
                                       startedAt: startedAt, updatedAt: record.performedAt)
        guard intent.completedAt == nil else { throw PlanStoreError.workoutFinished }
        var logged = record
        logged.workoutID = workoutID
        logged.acceptedPlanID = intent.plan?.id
        logged.effortWasReported = !record.isWarmup && effortReported && record.rpe != nil
        if logged.effortWasReported != true { logged.rpe = nil }
        intent.completion = .unknown
        intent.updatedAt = record.performedAt
        do {
            try writeExerciseSession(intent)
            modelContext.insert(StoredSetLog(logged))
            try saveChanges()
        } catch { modelContext.rollback(); throw error }
        return (logged, true)
    }

    public func recordExerciseCompletion(
        workoutID: UUID, exerciseID: UUID, completion: ExerciseExposure.Completion, now: Date = Date()
    ) throws {
        guard var intent = try exerciseSession(workoutID: workoutID, exerciseID: exerciseID) else { return }
        guard intent.completedAt == nil else { throw PlanStoreError.workoutFinished }
        intent.completion = completion
        intent.updatedAt = now
        do { try writeExerciseSession(intent); try saveChanges() }
        catch { modelContext.rollback(); throw error }
    }

    /// Finalize every exercise in this workout, including lifts swapped out
    /// after they were logged. An early finish reason applies only to accepted
    /// plans that still have work remaining. Pain is movement-specific, so it
    /// applies only to the focused exercise and can create an intent when that
    /// movement had not yet logged a set. Repeated Finish does not move the
    /// timestamp.
    public func finishExerciseSessions(
        workoutID: UUID,
        at date: Date = Date(),
        earlyCompletion: ExerciseExposure.Completion? = nil,
        focusedExerciseID: UUID? = nil,
        workoutStartedAt: Date? = nil
    ) throws {
        let logs = try allSets().filter { $0.workoutID == workoutID && !$0.isWarmup }
        do {
            var intents = try exerciseSessions().filter {
                $0.workoutID == workoutID && $0.completedAt == nil
            }
            if earlyCompletion == .stoppedForPain,
               let focusedExerciseID,
               !intents.contains(where: { $0.exerciseID == focusedExerciseID }) {
                intents.append(RecordedExerciseSession(
                    workoutID: workoutID,
                    exerciseID: focusedExerciseID,
                    startedAt: workoutStartedAt ?? date,
                    updatedAt: date
                ))
            }

            for var intent in intents {
                let working = logs.filter { $0.exerciseID == intent.exerciseID }
                let remainingAcceptedWork = intent.plan.map { working.count < $0.sets.count } ?? false
                if earlyCompletion == .stoppedForPain,
                   intent.exerciseID == focusedExerciseID {
                    intent.completion = .stoppedForPain
                } else if intent.completion == .unknown {
                    if remainingAcceptedWork,
                       let earlyCompletion,
                       earlyCompletion != .completed,
                       earlyCompletion != .stoppedForPain {
                        intent.completion = earlyCompletion
                    } else if let plan = intent.plan, working.count == plan.sets.count {
                        intent.completion = .completed
                    }
                }
                intent.completedAt = max(date, working.map(\.performedAt).max() ?? date)
                intent.updatedAt = intent.completedAt!
                try writeExerciseSession(intent)
            }
            try saveChanges()
        } catch { modelContext.rollback(); throw error }
    }

    public func exerciseExposures(for exerciseID: UUID, excluding workoutID: UUID? = nil) throws -> [ExerciseExposure] {
        let sets = try sets(forExercise: exerciseID)
        return try exerciseSessions().filter { $0.exerciseID == exerciseID && $0.workoutID != workoutID }.map { intent in
            let records = sets.filter { $0.workoutID == intent.workoutID }.sorted {
                if $0.performedAt != $1.performedAt { return $0.performedAt < $1.performedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            return ExerciseExposure(
                id: intent.workoutID, exerciseID: exerciseID, plan: intent.plan,
                sets: records.map {
                    ExposureSet(record: $0, effortSource:
                        $0.effortWasReported == true && $0.acceptedPlanID == intent.plan?.id ? .reported : .unknown)
                },
                completion: intent.completedAt == nil ? .unknown : intent.completion,
                completedAt: intent.completedAt ?? max(intent.updatedAt, records.map(\.performedAt).max() ?? intent.updatedAt)
            )
        }
    }

    public func allExerciseExposures(excluding workoutID: UUID? = nil) throws -> [ExerciseExposure] {
        try exercises().flatMap {
            try exerciseExposures(for: $0.id, excluding: workoutID)
        }
    }

    /// Optional starting bands derived from the last two or three fully
    /// completed, explicitly tolerated calendar weeks. Nothing is saved until
    /// the lifter reviews and accepts the suggestion in Settings.
    public func volumeBudgetSuggestion(
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> VolumeBudgetSuggestion? {
        let exercises = try exercises()
        let exposures = try allExerciseExposures()
        return VolumeBudgetSuggestionEngine.suggest(
            history: exposures, exercises: exercises, now: now, calendar: calendar
        )
    }

    public func trainingBlockStatus(
        for config: TrainingBlockConfig? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> TrainingBlockStatus? {
        let resolved: TrainingBlockConfig?
        if let config {
            resolved = config
        } else {
            resolved = try gymConfig().trainingBlock
        }
        guard let resolved else { return nil }
        return TrainingBlockEngine.status(
            config: resolved, history: try allExerciseExposures(), now: now, calendar: calendar
        )
    }

    /// Review data is derived from the proposal snapshot, current accepted
    /// plans, and corrected set rows. No mutable success counters are stored.
    public func recommendationFeedbackReport(
        now: Date = Date(), days: Int = 28
    ) throws -> RecommendationFeedbackReport {
        RecommendationFeedbackEngine.report(
            sessions: try exerciseSessions(),
            exposures: try allExerciseExposures(),
            now: now,
            days: days
        )
    }

    public func recommendation(for exercise: Exercise, excluding workoutID: UUID? = nil,
                               now: Date = Date()) throws -> ExerciseRecommendation {
        let plan = try latestExercisePlan(for: exercise.id, excluding: workoutID)
        let progression = RecommendationEngine.recommend(
            exercise: exercise, plan: plan,
            history: try exerciseExposures(for: exercise.id, excluding: workoutID),
            policy: exercise.recommendationPolicy, now: now)
        let allocated = VolumeAllocationEngine.applyingWeeklyVolume(
            to: progression,
            exercise: exercise,
            report: try volumeReport(now: now, excludingWorkoutID: workoutID)
        )
        guard let plan, let block = try gymConfig().trainingBlock else { return allocated }
        let history = try allExerciseExposures(excluding: workoutID)
        return TrainingBlockEngine.applyingDeload(
            to: allocated,
            plan: plan,
            phase: TrainingBlockEngine.phase(for: block, now: now),
            adaptiveDeload: TrainingBlockEngine.adaptiveDeloadNeeded(history: history, now: now),
            resumePlan: try latestNonDeloadExercisePlan(for: exercise.id, excluding: workoutID)
        )
    }

    /// Internal for archive merge and deduplication; callers own the transaction.
    func writeExerciseSession(_ intent: RecordedExerciseSession) throws {
        let workout = intent.workoutID, exercise = intent.exerciseID
        let rows = try modelContext.fetch(FetchDescriptor<StoredExerciseSession>(predicate: #Predicate {
            $0.workoutID == workout && $0.exerciseID == exercise
        }))
        if let first = rows.first {
            first.update(from: intent)
            for duplicate in rows.dropFirst() { modelContext.delete(duplicate) }
        } else { modelContext.insert(StoredExerciseSession(intent)) }
    }
}
