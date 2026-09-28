import XCTest
@testable import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class AutomaticPrescriptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func fixture() throws -> (TrainingStore, Exercise, ExerciseRecommendation) {
        let store = try TrainingStore.inMemory()
        let exercise = Exercise(name: "Automatic press", muscles: [.primary(.chest)],
                                equipment: .barbell,
                                progressionRule: .doubleProgression(range: RepRange(8, 12)))
        try store.upsert(exercise)
        for (index, reps) in [10, 10, 9].enumerated() {
            try store.log(SetRecord(exerciseID: exercise.id, load: 100, reps: reps,
                                    performedAt: now.addingTimeInterval(-86_400 + Double(index) * 60)))
        }
        return (store, exercise, try store.recommendation(for: exercise, now: now))
    }

    func testActivationPreservesExactProposalWithoutApprovalCompletionOrEffort() throws {
        let (store, exercise, displayed) = try fixture()
        let workout = UUID()
        let activated = try XCTUnwrap(store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now.addingTimeInterval(10)))
        let intent = try XCTUnwrap(store.exerciseSession(workoutID: workout, exerciseID: exercise.id))
        XCTAssertEqual(activated.sets.map(\.reps), [10, 10, 9])
        XCTAssertEqual(intent.recommendationTrace?.displayedRecommendation, displayed)
        XCTAssertEqual(intent.recommendationTrace?.decision, .automaticallyActivated)
        XCTAssertEqual(intent.recommendationTrace?.automaticallyActivatedAt, now.addingTimeInterval(10))
        XCTAssertEqual(intent.completion, .unknown)
        XCTAssertNil(intent.completedAt)
        XCTAssertTrue(try store.exerciseExposures(for: exercise.id).first?.workingSets.isEmpty == true)
        let report = try store.recommendationFeedbackReport(now: now.addingTimeInterval(20))
        XCTAssertEqual(report.automaticActivations, 1)
        XCTAssertEqual(report.reviewedPlans, 0)
        XCTAssertEqual(report.acceptedAsSuggested, 0)
        XCTAssertEqual(report.editedBeforeUse, 0)
        XCTAssertEqual(report.finishedAcceptedPlans, 0)
        XCTAssertNil(report.effortCoverage)
    }

    func testRetryAndRefreshPreserveActiveTargetsAndOriginalTrace() throws {
        let (store, exercise, displayed) = try fixture()
        let workout = UUID()
        let active = try XCTUnwrap(store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now))
        let first = try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: 100, reps: 10, rpe: .eight,
                      performedAt: now.addingTimeInterval(60)),
            workoutID: workout, startedAt: now, effortReported: false).record
        XCTAssertEqual(first.acceptedPlanID, active.id)
        XCTAssertNil(first.rpe)
        XCTAssertEqual(first.effortWasReported, false)
        let changed = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: active.id, generatedAt: now.addingTimeInterval(120),
            action: .hold, sets: [PlannedWorkingSet(load: 90, reps: 8)],
            reason: .missingEffort, evidence: .limited, supportingExposureIDs: [], ruleVersion: "changed")
        XCTAssertEqual(try store.activateExerciseRecommendation(
            changed, workoutID: workout, startedAt: now, now: now.addingTimeInterval(120)), active)
        let intent = try XCTUnwrap(store.exerciseSession(workoutID: workout, exerciseID: exercise.id))
        XCTAssertEqual(intent.recommendationTrace?.displayedRecommendation, displayed)
        XCTAssertEqual(intent.completion, .unknown)
        let restored = try TrainingStore.inMemory()
        _ = try restored.restore(from: store.archive(exportedAt: now.addingTimeInterval(120)))
        XCTAssertEqual(try restored.exerciseSession(workoutID: workout, exerciseID: exercise.id), intent)
        XCTAssertEqual(try restored.allSets().first { $0.id == first.id }?.acceptedPlanID, active.id)
    }

    func testExplicitEditKeepsAutomaticOriginAndDoesNotGetOverwrittenByRetry() throws {
        let (store, exercise, displayed) = try fixture()
        let workout = UUID()
        let active = try XCTUnwrap(store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now))
        var edited = active
        edited.sets[0].reps = 9
        let explicit = try store.acceptExercisePlan(
            edited, workoutID: workout, startedAt: now, now: now.addingTimeInterval(10))
        XCTAssertNotEqual(explicit.id, active.id)
        XCTAssertEqual(try store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now.addingTimeInterval(20)), explicit)
        let trace = try XCTUnwrap(store.exerciseSession(workoutID: workout, exerciseID: exercise.id)?.recommendationTrace)
        XCTAssertEqual(trace.decision, .edited)
        XCTAssertEqual(trace.automaticallyActivatedAt, now)
        XCTAssertEqual(trace.displayedRecommendation, displayed)
        let report = try store.recommendationFeedbackReport(now: now.addingTimeInterval(30))
        XCTAssertEqual(report.automaticActivations, 1)
        XCTAssertEqual(report.reviewedPlans, 1)
        XCTAssertEqual(report.editedBeforeUse, 1)
        XCTAssertEqual(report.acceptedAsSuggested, 0)
    }

    func testActivationRejectsStaleProposalAndRetroactiveWorkingSets() throws {
        let (store, exercise, displayed) = try fixture()
        let workout = UUID()
        var staleSets = displayed.sets
        staleSets[0].reps = 8
        let stale = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: displayed.basedOnPlanID, generatedAt: now,
            action: displayed.action, sets: staleSets, reason: displayed.reason,
            evidence: displayed.evidence, supportingExposureIDs: displayed.supportingExposureIDs,
            ruleVersion: displayed.ruleVersion)
        XCTAssertThrowsError(try store.activateExerciseRecommendation(
            stale, workoutID: workout, startedAt: now, now: now))
        XCTAssertNil(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id))
        _ = try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: 100, reps: 10, performedAt: now),
            workoutID: workout, startedAt: now, effortReported: false)
        XCTAssertThrowsError(try store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now))
        XCTAssertNil(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id)?.plan)
    }

    func testColdStartAndPainDoNotActivateAPrescription() throws {
        let (store, exercise, _) = try fixture()
        for action in [ExerciseRecommendation.Action.establish, .stop] {
            let displayed = ExerciseRecommendation(
                exerciseID: exercise.id, basedOnPlanID: nil, generatedAt: now,
                action: action, sets: [], reason: action == .stop ? .pain : .firstPlanNeeded,
                evidence: .insufficient, supportingExposureIDs: [], ruleVersion: "test")
            let workout = UUID()
            XCTAssertNil(try store.activateExerciseRecommendation(
                displayed, workoutID: workout, startedAt: now, now: now))
            XCTAssertNil(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id))
        }
    }

    func testTwoAutomaticallyActivatedEasyWorkoutsEarnProgressionWithoutAcceptance() throws {
        let (store, exercise, _) = try fixture()
        var revisions: [UUID] = []
        for day in 0..<2 {
            let start = now.addingTimeInterval(Double(day) * 2 * 86_400)
            let workout = UUID()
            let proposal = try store.recommendation(for: exercise, excluding: workout, now: start)
            let active = try XCTUnwrap(store.activateExerciseRecommendation(
                proposal, workoutID: workout, startedAt: start, now: start))
            revisions.append(active.id)
            for (index, target) in active.sets.enumerated() {
                _ = try store.logWorkoutSet(
                    SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .seven,
                              performedAt: start.addingTimeInterval(Double(index + 1) * 120)),
                    workoutID: workout, startedAt: start, effortReported: true)
            }
            try store.finishExerciseSessions(workoutID: workout, at: start.addingTimeInterval(600))
        }
        XCTAssertEqual(revisions[0], revisions[1])
        let proposal = try store.recommendation(for: exercise, now: now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(proposal.action, .addReps)
        XCTAssertEqual(proposal.sets.map(\.reps), [10, 10, 10])
        let report = try store.recommendationFeedbackReport(now: now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(report.automaticActivations, 2)
        XCTAssertEqual(report.reviewedPlans, 0)
        XCTAssertEqual(report.acceptedAsSuggested, 0)
        XCTAssertEqual(report.finishedAcceptedPlans, 0)
        XCTAssertTrue(report.entries.allSatisfy { $0.completedAsPlanned })
        XCTAssertTrue(report.entries.allSatisfy { $0.workingSets == 3 })
        XCTAssertTrue(report.entries.allSatisfy { $0.reportedEffortSets == 3 })
    }

    func testLegacyTraceDecodesWithoutInventingAutomaticOrigin() throws {
        let (_, _, displayed) = try fixture()
        let trace = RecommendationTrace(recommendation: displayed)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any])
        json.removeValue(forKey: "displayedRecommendation")
        json.removeValue(forKey: "automaticallyActivatedAt")
        let decoded = try JSONDecoder().decode(RecommendationTrace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.decision, .accepted)
        XCTAssertNil(decoded.displayedRecommendation)
        XCTAssertNil(decoded.automaticallyActivatedAt)
        XCTAssertEqual(decoded.proposedSets, displayed.sets)
    }

    func testAutomaticOutcomeFollowsMissingAddedAndWithdrawnRPEAndSeparatesOverride() throws {
        let (store, exercise, displayed) = try fixture()
        let workout = UUID()
        let active = try XCTUnwrap(store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: now, now: now))
        var logged: [SetRecord] = []
        for (index, target) in active.sets.enumerated() {
            logged.append(try store.logWorkoutSet(
                SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps,
                          performedAt: now.addingTimeInterval(Double(index + 1) * 60)),
                workoutID: workout, startedAt: now, effortReported: false).record)
        }
        try store.finishExerciseSessions(workoutID: workout, at: now.addingTimeInterval(600))
        let reportAt = now.addingTimeInterval(2 * 86_400)
        func outcome() throws -> RecommendationFeedbackEntry {
            try XCTUnwrap(store.recommendationFeedbackReport(now: reportAt).entries.first {
                $0.id == "\(workout.uuidString)/\(exercise.id.uuidString)"
            })
        }
        let missing = try outcome()
        XCTAssertTrue(missing.finished)
        XCTAssertTrue(missing.completedAsPlanned)
        XCTAssertEqual(missing.decision, .automaticallyActivated)
        XCTAssertEqual(missing.workingSets, 3)
        XCTAssertEqual(missing.effortCoverage, 0)
        XCTAssertEqual(missing.aboveTargetEffortSets, 0)

        var corrected = logged[2]
        corrected.rpe = .ten
        XCTAssertTrue(try store.updateSet(corrected))
        let reported = try outcome()
        XCTAssertEqual(reported.reportedEffortSets, 1)
        XCTAssertEqual(reported.effortCoverage, 1.0 / 3)
        XCTAssertEqual(reported.aboveTargetEffortSets, 1)
        XCTAssertTrue(reported.completedAsPlanned)

        corrected.rpe = nil
        XCTAssertTrue(try store.updateSet(corrected))
        XCTAssertEqual(try outcome(), missing)
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id)?.plan, active)
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id)?
            .recommendationTrace?.displayedRecommendation, displayed)

        let overrideWorkout = UUID(), overrideStart = now.addingTimeInterval(86_400)
        let next = try store.recommendation(for: exercise, excluding: overrideWorkout, now: overrideStart)
        var override = try XCTUnwrap(store.activateExerciseRecommendation(
            next, workoutID: overrideWorkout, startedAt: overrideStart, now: overrideStart))
        override.sets[0].reps -= 1
        override = try store.acceptExercisePlan(override, workoutID: overrideWorkout,
                                                startedAt: overrideStart, now: overrideStart)
        for (index, target) in override.sets.enumerated() {
            _ = try store.logWorkoutSet(
                SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .seven,
                          performedAt: overrideStart.addingTimeInterval(Double(index + 1) * 60)),
                workoutID: overrideWorkout, startedAt: overrideStart, effortReported: true)
        }
        try store.finishExerciseSessions(workoutID: overrideWorkout, at: overrideStart.addingTimeInterval(600))
        let report = try store.recommendationFeedbackReport(now: reportAt)
        XCTAssertEqual(report.automaticActivations, 2)
        XCTAssertEqual(report.reviewedPlans, 1)
        XCTAssertEqual(report.editedBeforeUse, 1)
        XCTAssertEqual(report.acceptedAsSuggested, 0)
        let edited = try XCTUnwrap(report.entries.first { $0.decision == .edited })
        XCTAssertTrue(edited.finished)
        XCTAssertFalse(edited.completedAsPlanned)
        XCTAssertEqual(edited.workingSets, 0, "an override is not evidence that the suggested targets were followed")
        XCTAssertNil(edited.effortCoverage)
        XCTAssertEqual(try outcome(), missing)
    }

    func testCorrectionAndDiskRelaunchFreezeActiveProposalButRefreshUnstartedProposal() throws {
        let directory = URL.temporaryDirectory.appending(path: "automatic-correction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "training.store")
        let exercises = ["Active press", "Unstarted press"].map {
            Exercise(name: $0, muscles: [.primary(.chest)], equipment: .dumbbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        let currentWorkout = UUID()
        var frozen: ExerciseRecommendation!
        var frozenPlan: ExercisePlan!
        var refreshed: ExerciseRecommendation!
        do {
            let store = try TrainingStore(url: url)
            var latestSets: [SetRecord] = []
            for exercise in exercises {
                try store.upsert(exercise)
                for index in 0..<3 {
                    try store.log(SetRecord(exerciseID: exercise.id, load: 100, reps: 10,
                        performedAt: now.addingTimeInterval(-6 * 86_400 + Double(index) * 60)))
                }
                for daysAgo in [4, 2] {
                    let start = now.addingTimeInterval(-Double(daysAgo) * 86_400), workout = UUID()
                    let proposal = try store.recommendation(for: exercise, excluding: workout, now: start)
                    let plan = try XCTUnwrap(store.activateExerciseRecommendation(
                        proposal, workoutID: workout, startedAt: start, now: start))
                    for (index, target) in plan.sets.enumerated() {
                        let record = try store.logWorkoutSet(
                            SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .seven,
                                      performedAt: start.addingTimeInterval(Double(index + 1) * 60)),
                            workoutID: workout, startedAt: start, effortReported: true).record
                        if daysAgo == 2 && index == plan.sets.count - 1 { latestSets.append(record) }
                    }
                    try store.finishExerciseSessions(workoutID: workout, at: start.addingTimeInterval(600))
                }
            }
            let before = try store.workoutRecommendations(for: exercises, workoutID: currentWorkout, now: now)
            XCTAssertTrue(before.values.allSatisfy { $0.action == .addReps })
            frozen = try XCTUnwrap(before[exercises[0].id])
            frozenPlan = try XCTUnwrap(store.activateExerciseRecommendation(
                frozen, workoutID: currentWorkout, startedAt: now, now: now))
            for var record in latestSets {
                record.rpe = .ten
                XCTAssertTrue(try store.updateSet(record))
            }
            let after = try store.workoutRecommendations(for: exercises, workoutID: currentWorkout, now: now)
            XCTAssertEqual(after[exercises[0].id], frozen)
            refreshed = try XCTUnwrap(after[exercises[1].id])
            XCTAssertEqual(refreshed.action, .hold)
            XCTAssertNotEqual(refreshed, before[exercises[1].id])
            XCTAssertNil(try store.exerciseSession(workoutID: currentWorkout, exerciseID: exercises[1].id))
        }
        let reopened = try TrainingStore(url: url)
        let afterRelaunch = try reopened.workoutRecommendations(for: exercises, workoutID: currentWorkout, now: now)
        XCTAssertEqual(afterRelaunch[exercises[0].id], frozen)
        XCTAssertEqual(afterRelaunch[exercises[1].id], refreshed)
        XCTAssertEqual(try reopened.exerciseSession(workoutID: currentWorkout, exerciseID: exercises[0].id)?.plan, frozenPlan)
        XCTAssertEqual(try reopened.activateExerciseRecommendation(
            frozen, workoutID: currentWorkout, startedAt: now, now: now), frozenPlan)
    }
}
