import SwiftData
import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class WorkoutDraftTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = URL.temporaryDirectory
            .appending(path: "workout-draft-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: URL(filePath: storeURL.path() + suffix)
            )
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    private func openStore() throws -> TrainingStore {
        let store = try TrainingStore(url: storeURL)
        try store.seedLibraryIfNeeded()
        try store.seedTemplatesIfNeeded()
        return store
    }

    private var todayAtNoon: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
    }

    func testDraftAndExactPositionSurviveRelaunch() throws {
        let original: WorkoutDraft
        let logged: SetRecord

        do {
            let store = try openStore()
            var session = try store.startSession(kind: .push, startedAt: todayAtNoon)
            let second = try XCTUnwrap(session.exercises.dropFirst().first)
            session.select(exerciseID: second.id)
            logged = SetRecord(
                exerciseID: second.id,
                load: Load(100),
                reps: 8,
                rpe: .eight,
                performedAt: todayAtNoon.addingTimeInterval(60)
            )
            try store.log(logged)
            session.log(logged)
            original = WorkoutDraft(session: session)
            try store.saveWorkoutDraft(original)
        }

        let relaunched = try openStore()
        let saved = try XCTUnwrap(try relaunched.workoutDraft())
        XCTAssertEqual(saved, original)

        let resumed = try relaunched.resumeSession(saved)
        XCTAssertEqual(resumed.exercises.map(\.id), original.exerciseIDs)
        XCTAssertEqual(resumed.current?.id, original.currentExerciseID)
        XCTAssertEqual(resumed.current?.loggedSets, [logged])
    }

    func testEditedRosterOrderAndSlotsSurviveRelaunch() throws {
        let store = try openStore()
        var session = try store.startSession(kind: .push, startedAt: todayAtNoon)
        let original = session.exercises
        session.movePlannedExercises(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        session.removePlannedExercises(atOffsets: IndexSet(integer: 1))
        let extra = try XCTUnwrap(try store.exercises().first {
            candidate in !session.exercises.contains(where: { $0.id == candidate.id })
        })
        session.appendPlannedExercise(try store.sessionExercise(
            for: extra, slot: nil, startedAt: todayAtNoon
        ))
        let draft = WorkoutDraft(session: session)
        try store.saveWorkoutDraft(draft)

        let saved = try XCTUnwrap(try store.workoutDraft())
        let resumed = try store.resumeSession(saved)

        XCTAssertEqual(resumed.exercises.map(\.id), session.exercises.map(\.id))
        XCTAssertEqual(resumed.exercises.map(\.slot), session.exercises.map(\.slot))
        XCTAssertNotEqual(resumed.exercises.map(\.id), original.map(\.id))
        XCTAssertNil(resumed.exercises.last?.slot)
    }

    func testClearingDraftDoesNotDeleteLoggedSets() throws {
        let store = try openStore()
        var session = try store.startSession(kind: .pull, startedAt: todayAtNoon)
        let current = try XCTUnwrap(session.current)
        let logged = SetRecord(
            exerciseID: current.id,
            load: Load(90),
            reps: 10,
            rpe: .eight,
            performedAt: todayAtNoon
        )
        try store.log(logged)
        session.log(logged)
        let draft = WorkoutDraft(session: session)
        try store.saveWorkoutDraft(draft)

        try store.clearWorkoutDraft(id: draft.id)

        XCTAssertNil(try store.workoutDraft())
        XCTAssertEqual(try store.allSets(), [logged])
    }

    func testResumeIncludesASetLoggedAfterMidnight() throws {
        let store = try openStore()
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-5 * 60)
        let session = try store.startSession(kind: .legs, startedAt: start)
        let current = try XCTUnwrap(session.current)
        let afterMidnight = SetRecord(
            exerciseID: current.id,
            load: Load(180),
            reps: 8,
            rpe: .eight,
            performedAt: start.addingTimeInterval(10 * 60)
        )
        try store.log(afterMidnight)
        let draft = WorkoutDraft(session: session)
        try store.saveWorkoutDraft(draft)

        let resumed = try store.resumeSession(draft)

        XCTAssertEqual(resumed.current?.loggedSets, [afterMidnight])
    }

    func testLatestSyncedDraftWinsDeduplication() throws {
        let store = try openStore()
        let older = WorkoutDraft(
            kind: .push,
            startedAt: todayAtNoon,
            exerciseIDs: [UUID()],
            currentExerciseID: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = WorkoutDraft(
            kind: .legs,
            startedAt: todayAtNoon,
            exerciseIDs: [UUID()],
            currentExerciseID: nil,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        store.modelContext.insert(StoredWorkoutDraft(older))
        store.modelContext.insert(StoredWorkoutDraft(newer))
        try store.saveChanges()

        let report = try store.deduplicate()

        XCTAssertEqual(report.workoutDrafts, 1)
        XCTAssertEqual(try store.workoutDraft()?.kind, .legs)
    }
}
