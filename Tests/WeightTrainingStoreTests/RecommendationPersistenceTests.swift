import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class RecommendationPersistenceTests: XCTestCase {
    private var store: TrainingStore!
    private let epoch = Date(timeIntervalSince1970: 1_760_011_200)

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private func lift() throws -> Exercise {
        let exercise = Exercise(
            name: "Test Press", muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        try store.upsert(exercise)
        return exercise
    }

    private func plan(_ exercise: Exercise) -> ExercisePlan {
        ExercisePlan(exercise: exercise, sets: [10, 10, 9].map {
            PlannedWorkingSet(load: 100, reps: $0, rpe: .eight)
        })
    }

    private func ceilingPlan(_ exercise: Exercise) -> ExercisePlan {
        ExercisePlan(exercise: exercise, sets: Array(repeating:
            PlannedWorkingSet(load: 50, reps: 12, rpe: .eight), count: 3))
    }

    private func complete(
        plan: ExercisePlan, workoutID: UUID, start: Date, rpe: RPE = .seven
    ) throws -> [SetRecord] {
        var records: [SetRecord] = []
        for (index, target) in plan.sets.enumerated() {
            let record = SetRecord(
                exerciseID: plan.exercise.id, load: target.load, reps: target.reps,
                rpe: rpe, performedAt: start.addingTimeInterval(Double(index) * 180)
            )
            let saved = try store.logWorkoutSet(
                record, workoutID: workoutID, startedAt: start, effortReported: true
            )
            XCTAssertTrue(saved.inserted)
            records.append(saved.record)
        }
        try store.finishExerciseSessions(workoutID: workoutID, at: start.addingTimeInterval(1_800))
        return records
    }

    func testAcceptedPlanAndReportedEffortRebuildAnExposure() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        let records = try complete(plan: accepted, workoutID: workout, start: epoch)

        let exposure = try XCTUnwrap(store.exerciseExposures(for: exercise.id).first)
        XCTAssertEqual(exposure.id, workout)
        XCTAssertEqual(exposure.plan, accepted)
        XCTAssertEqual(exposure.completion, .completed)
        XCTAssertEqual(exposure.workingSets.map(\.record.id), records.map(\.id))
        XCTAssertTrue(exposure.workingSets.allSatisfy { $0.effortSource == .reported })
    }

    func testTwoAcceptedEasyWorkoutsEarnOneRep() throws {
        let exercise = try lift()
        let firstID = UUID()
        let first = try store.acceptExercisePlan(plan(exercise), workoutID: firstID,
                                                  startedAt: epoch, now: epoch)
        _ = try complete(plan: first, workoutID: firstID, start: epoch)

        let secondStart = epoch.addingTimeInterval(2 * 86_400)
        let secondID = UUID()
        let second = try store.acceptExercisePlan(plan(exercise), workoutID: secondID,
                                                   startedAt: secondStart, now: secondStart)
        XCTAssertEqual(second.id, first.id, "repeating identical targets preserves the comparison segment")
        _ = try complete(plan: second, workoutID: secondID, start: secondStart)

        let recommendation = try store.recommendation(
            for: exercise, now: secondStart.addingTimeInterval(2_000)
        )
        XCTAssertEqual(recommendation.action, .addReps)
        XCTAssertEqual(recommendation.sets.map(\.reps), [10, 10, 10])
    }

    func testWeeklyVolumeAddsOneSetWhenTheLoadStepIsTooLarge() throws {
        let exercise = Exercise(
            name: "Volume Press", muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        try store.upsert(exercise)
        let proposed = ceilingPlan(exercise)

        for day in [0, 2] {
            let start = epoch.addingTimeInterval(Double(day) * 86_400)
            let workout = UUID()
            let accepted = try store.acceptExercisePlan(
                proposed, workoutID: workout, startedAt: start, now: start
            )
            _ = try complete(plan: accepted, workoutID: workout, start: start)
        }

        let recommendation = try store.recommendation(
            for: exercise, now: epoch.addingTimeInterval(2 * 86_400 + 2_000)
        )
        XCTAssertEqual(recommendation.action, .addSet)
        XCTAssertEqual(recommendation.sets.count, 4)
        XCTAssertEqual(recommendation.reason, .weeklyVolumeBelowBudget(muscles: [.chest]))
    }

    func testVolumeReportProjectsOnlyRemainingAcceptedWork() throws {
        let exercise = try lift()
        let workout = UUID()
        _ = try store.acceptExercisePlan(
            plan(exercise), workoutID: workout, startedAt: epoch, now: epoch
        )
        _ = try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: 100, reps: 10,
                      rpe: .seven, performedAt: epoch.addingTimeInterval(60)),
            workoutID: workout, startedAt: epoch, effortReported: true
        )

        let included = try store.volumeReport(now: epoch.addingTimeInterval(120))
        let excluded = try store.volumeReport(
            now: epoch.addingTimeInterval(120), excludingWorkoutID: workout
        )
        XCTAssertEqual(included.muscles.first { $0.muscle == .chest }?.sets, 1)
        XCTAssertEqual(included.muscles.first { $0.muscle == .chest }?.plannedSets, 2)
        XCTAssertEqual(excluded.muscles.first { $0.muscle == .chest }?.sets, 1)
        XCTAssertEqual(excluded.muscles.first { $0.muscle == .chest }?.plannedSets, 0)
    }

    func testEarlyTimeReasonAppliesOnlyToAcceptedPlansWithWorkRemaining() throws {
        let completedExercise = try lift()
        let incompleteExercise = Exercise(
            name: "Test Row", muscles: [.primary(.lats)], equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        try store.upsert(incompleteExercise)
        let workout = UUID()
        let completedPlan = try store.acceptExercisePlan(
            plan(completedExercise), workoutID: workout, startedAt: epoch, now: epoch
        )
        let incompletePlan = try store.acceptExercisePlan(
            plan(incompleteExercise), workoutID: workout, startedAt: epoch, now: epoch
        )

        for (index, target) in completedPlan.sets.enumerated() {
            _ = try store.logWorkoutSet(
                SetRecord(exerciseID: completedExercise.id, load: target.load, reps: target.reps,
                          rpe: .seven, performedAt: epoch.addingTimeInterval(Double(index + 1) * 60)),
                workoutID: workout, startedAt: epoch, effortReported: true
            )
        }
        let firstRowTarget = incompletePlan.sets[0]
        _ = try store.logWorkoutSet(
            SetRecord(exerciseID: incompleteExercise.id, load: firstRowTarget.load,
                      reps: firstRowTarget.reps, rpe: .seven,
                      performedAt: epoch.addingTimeInterval(300)),
            workoutID: workout, startedAt: epoch, effortReported: true
        )

        try store.finishExerciseSessions(
            workoutID: workout,
            at: epoch.addingTimeInterval(600),
            earlyCompletion: .shortenedForTime,
            focusedExerciseID: incompleteExercise.id,
            workoutStartedAt: epoch
        )

        XCTAssertEqual(
            try store.exerciseSession(workoutID: workout, exerciseID: completedExercise.id)?.completion,
            .completed
        )
        XCTAssertEqual(
            try store.exerciseSession(workoutID: workout, exerciseID: incompleteExercise.id)?.completion,
            .shortenedForTime
        )
    }

    func testPainReasonAppliesOnlyToFocusedExercise() throws {
        let otherExercise = try lift()
        let painfulExercise = Exercise(
            name: "Painful Row", muscles: [.primary(.lats)], equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        try store.upsert(painfulExercise)
        let workout = UUID()
        _ = try store.acceptExercisePlan(
            plan(otherExercise), workoutID: workout, startedAt: epoch, now: epoch
        )
        _ = try store.acceptExercisePlan(
            plan(painfulExercise), workoutID: workout, startedAt: epoch, now: epoch
        )

        try store.finishExerciseSessions(
            workoutID: workout,
            at: epoch.addingTimeInterval(600),
            earlyCompletion: .stoppedForPain,
            focusedExerciseID: painfulExercise.id,
            workoutStartedAt: epoch
        )

        XCTAssertEqual(
            try store.exerciseSession(workoutID: workout, exerciseID: painfulExercise.id)?.completion,
            .stoppedForPain
        )
        XCTAssertEqual(
            try store.exerciseSession(workoutID: workout, exerciseID: otherExercise.id)?.completion,
            .unknown
        )
        XCTAssertEqual(
            try store.recommendation(for: painfulExercise, now: epoch.addingTimeInterval(700)).action,
            .stop
        )
    }

    func testCorrectionAndDeletionRecomputeEvidence() throws {
        let exercise = try lift()
        let firstID = UUID(), secondID = UUID()
        let first = try store.acceptExercisePlan(plan(exercise), workoutID: firstID,
                                                  startedAt: epoch, now: epoch)
        _ = try complete(plan: first, workoutID: firstID, start: epoch)
        let secondStart = epoch.addingTimeInterval(2 * 86_400)
        let second = try store.acceptExercisePlan(plan(exercise), workoutID: secondID,
                                                   startedAt: secondStart, now: secondStart)
        let secondRecords = try complete(plan: second, workoutID: secondID, start: secondStart)
        XCTAssertEqual(try store.recommendation(for: exercise, now: secondStart.addingTimeInterval(2_000)).action,
                       .addReps)

        var corrected = secondRecords.last!
        corrected.rpe = .nine
        XCTAssertTrue(try store.updateSet(corrected))
        XCTAssertEqual(try store.recommendation(for: exercise, now: secondStart.addingTimeInterval(2_000)).action,
                       .hold)

        XCTAssertTrue(try store.deleteSet(id: corrected.id))
        XCTAssertEqual(try store.recommendation(for: exercise, now: secondStart.addingTimeInterval(2_000)).reason,
                       .incompleteExposure)
    }

    func testDisplayedTargetRPEIsNotStoredAsReportedEffort() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        let target = accepted.sets[0]
        let saved = try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps,
                      rpe: target.rpe, performedAt: epoch.addingTimeInterval(60)),
            workoutID: workout, startedAt: epoch, effortReported: false
        ).record
        XCTAssertNil(saved.rpe)
        XCTAssertEqual(saved.effortWasReported, false)
        XCTAssertEqual(saved.acceptedPlanID, accepted.id)
    }

    func testSetIdentityMakesWorkoutLoggingIdempotent() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        let record = SetRecord(id: UUID(), exerciseID: exercise.id, load: 100, reps: 10,
                               rpe: .seven, performedAt: epoch.addingTimeInterval(60))
        XCTAssertTrue(try store.logWorkoutSet(record, workoutID: workout, startedAt: epoch,
                                              effortReported: true).inserted)
        XCTAssertFalse(try store.logWorkoutSet(record, workoutID: workout, startedAt: epoch,
                                               effortReported: true).inserted)
        XCTAssertEqual(try store.allSets().count, 1)
        XCTAssertEqual(try store.allSets().first?.acceptedPlanID, accepted.id)
    }

    func testCannotAcceptPlanAfterWorkingSetOrLogAfterFinish() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        let record = SetRecord(exerciseID: exercise.id, load: 100, reps: 10,
                               rpe: .seven, performedAt: epoch.addingTimeInterval(60))
        _ = try store.logWorkoutSet(record, workoutID: workout, startedAt: epoch, effortReported: true)
        XCTAssertThrowsError(try store.acceptExercisePlan(accepted, workoutID: workout,
                                                          startedAt: epoch, now: epoch))
        try store.finishExerciseSessions(workoutID: workout, at: epoch.addingTimeInterval(600))
        XCTAssertThrowsError(try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: 100, reps: 10,
                      performedAt: epoch.addingTimeInterval(700)),
            workoutID: workout, startedAt: epoch, effortReported: false
        ))
    }

    func testArchiveCarriesPlansAndVersionOneArchiveStillDecodes() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        _ = try complete(plan: accepted, workoutID: workout, start: epoch)
        let archive = try store.archive(exportedAt: epoch)
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(archive.exerciseSessions?.first?.plan, accepted)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive.jsonData()) as? [String: Any])
        object["version"] = 1
        object.removeValue(forKey: "exerciseSessions")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try TrainingArchive(json: legacy).exerciseSessions)
    }

    func testRestoringLegacyCopyDoesNotEraseKnownEffortProvenance() throws {
        let exercise = try lift()
        let workout = UUID()
        let accepted = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                     startedAt: epoch, now: epoch)
        let saved = try store.logWorkoutSet(
            SetRecord(exerciseID: exercise.id, load: 100, reps: 10,
                      rpe: .seven, performedAt: epoch.addingTimeInterval(60)),
            workoutID: workout, startedAt: epoch, effortReported: true
        ).record
        let legacyCopy = SetRecord(
            id: saved.id, exerciseID: exercise.id, load: saved.load, reps: saved.reps,
            rpe: saved.rpe, performedAt: saved.performedAt
        )

        _ = try store.restore(from: TrainingArchive(sets: [legacyCopy]))
        let restored = try XCTUnwrap(try store.allSets().first { $0.id == saved.id })
        XCTAssertEqual(restored.workoutID, workout)
        XCTAssertEqual(restored.acceptedPlanID, accepted.id)
        XCTAssertEqual(restored.effortWasReported, true)
    }

    func testEqualTimeArchivePlanConflictBecomesUnknown() throws {
        let exercise = try lift()
        let workout = UUID()
        let first = try store.acceptExercisePlan(plan(exercise), workoutID: workout,
                                                  startedAt: epoch, now: epoch)
        var conflictingSets = first.sets
        conflictingSets[0].reps -= 1
        let conflictingPlan = ExercisePlan(
            exercise: exercise, sets: conflictingSets, restSeconds: first.restSeconds
        )
        let incoming = RecordedExerciseSession(
            workoutID: workout, exerciseID: exercise.id, startedAt: epoch,
            plan: conflictingPlan, updatedAt: epoch
        )

        _ = try store.restore(from: TrainingArchive(exerciseSessions: [incoming]))

        let restored = try XCTUnwrap(store.exerciseSession(workoutID: workout, exerciseID: exercise.id))
        XCTAssertNil(restored.plan)
        XCTAssertEqual(restored.completion, .unknown)
    }
}
