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
