import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Deleting one set corrects progress exactly as deleting it through select
/// mode does (#303), and taking back a set from a session that hasn't been
/// finished yet corrects nothing, because that session hasn't moved progress.
@MainActor
final class SingleDeleteProgressTests: XCTestCase {

    private var chestFly: Exercise {
        ExerciseLibrary.all.first { $0.name == "Chest Fly" }!
    }

    /// Midday anchors: the store groups sets by calendar day (#79).
    private func midday(_ dayOffset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 10 + dayOffset; components.hour = 12
        return Calendar.current.date(from: components)!
    }

    private func freshStore() throws -> TrainingStore {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        return store
    }

    /// Chest Fly's day as `SessionViewModel` would rebuild it from disk:
    /// today's logged sets plus the stored target. Built for the lift alone,
    /// because which side of a rotating push slot is due depends on history.
    private func chestFlyDay(_ day: Int, in store: TrainingStore) throws -> Session {
        Session(kind: .push,
                exercises: [try store.sessionExercise(for: chestFly, slot: nil, startedAt: midday(day))],
                startedAt: midday(day))
    }

    /// Chest Fly days of one 50x15 set each, finished through the live path
    /// the way `SessionViewModel.finish()` does, until the top-of-range hits
    /// earn the load jump. Returns the set that earned it.
    private func earnAJump(in store: TrainingStore) throws -> SetRecord {
        for day in 0..<6 {
            let set = SetRecord(exerciseID: chestFly.id, load: Load(50), reps: 15,
                                performedAt: midday(day).addingTimeInterval(120))
            try store.log(set)
            let session = try chestFlyDay(day, in: store)
            try store.applyProgression(for: session, now: session.startedAt)
            if let target = try store.progressState(forExercise: chestFly.id)?.targetLoad,
               target > Load(50) {
                return set
            }
        }
        XCTFail("fixture: six top-of-range days never earned a jump")
        throw CancellationError()
    }

    func testDeletingTheLatestWorkingSetSinglyUndoesTheJumpLikeTheBatch() throws {
        let single = try freshStore()
        let singleEarner = try earnAJump(in: single)
        let jumped = try XCTUnwrap(single.progressState(forExercise: chestFly.id))

        let batch = try freshStore()
        let batchEarner = try earnAJump(in: batch)

        XCTAssertTrue(try single.deleteSet(id: singleEarner.id))
        XCTAssertEqual(try batch.deleteSets(ids: [batchEarner.id]), [batchEarner.id])

        let afterSingle = try XCTUnwrap(single.progressState(forExercise: chestFly.id))
        let afterBatch = try XCTUnwrap(batch.progressState(forExercise: chestFly.id))
        XCTAssertNotEqual(afterSingle, jumped)
        XCTAssertEqual(afterSingle.targetLoad, Load(50), "the jump the deleted set earned is undone")
        XCTAssertEqual(afterSingle, afterBatch, "one path, one answer")
    }

    /// Undo (#8) and the Live Activity's undo button both delete through
    /// `deleteSet`, mid-session. Progress only moves when the session is
    /// finished, so the stored state still describes the last *finished*
    /// session and there is no step to undo. Repeating last session's numbers
    /// is exactly the case where the replay matched the stored state anyway:
    /// correcting it then stamped today on the state, and `applyProgression`'s
    /// same-day guard silently skipped the real finish.
    func testUndoingASetFromAnUnfinishedSessionLeavesProgressForTheFinish() throws {
        try assertDeletingFromAnUnfinishedSessionLeavesProgressForTheFinish {
            XCTAssertTrue(try $0.deleteSet(id: $1))
        }
    }

    /// The same hole, already on `main` before #303: History's select mode
    /// can delete today's sets while the session is still open.
    func testBatchDeletingFromAnUnfinishedSessionLeavesProgressForTheFinish() throws {
        try assertDeletingFromAnUnfinishedSessionLeavesProgressForTheFinish {
            XCTAssertEqual(try $0.deleteSets(ids: [$1]), [$1])
        }
    }

    private func assertDeletingFromAnUnfinishedSessionLeavesProgressForTheFinish(
        _ delete: (TrainingStore, UUID) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let store = try freshStore()
        try store.log(SetRecord(exerciseID: chestFly.id, load: Load(50), reps: 12,
                                performedAt: midday(0).addingTimeInterval(120)))
        let lastTime = try chestFlyDay(0, in: store)
        try store.applyProgression(for: lastTime, now: lastTime.startedAt)
        let finished = try XCTUnwrap(store.progressState(forExercise: chestFly.id))

        // Today, not finished yet: the same 50x12, twice, then undo the second.
        try store.log(SetRecord(exerciseID: chestFly.id, load: Load(50), reps: 12,
                                performedAt: midday(1).addingTimeInterval(120)))
        let undone = SetRecord(exerciseID: chestFly.id, load: Load(50), reps: 12,
                               performedAt: midday(1).addingTimeInterval(240))
        try store.log(undone)
        try delete(store, undone.id)

        XCTAssertEqual(try store.progressState(forExercise: chestFly.id), finished,
                       "an unfinished session has no step to undo", file: file, line: line)
        let today = try chestFlyDay(1, in: store)
        let applied = try store.applyProgression(for: today, now: today.startedAt)
        XCTAssertTrue(applied.contains { $0.exercise.id == self.chestFly.id },
                      "finishing today still advances the lift", file: file, line: line)
    }

    func testDeletingAnUnknownIDStillReportsFalse() throws {
        let store = try freshStore()
        XCTAssertFalse(try store.deleteSet(id: UUID()))
    }
}
