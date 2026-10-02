import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// A write whose save throws must leave nothing staged (#304).
///
/// SwiftData doesn't roll a failed save back on its own. Without a rollback,
/// the row a failed `log` inserted stays pending in the shared context, the
/// lifter's retry after "Couldn't save that set" inserts a second one, and the
/// next successful save commits both — doubling the set's volume and e1RM.
@MainActor
final class FailedSaveTests: XCTestCase {
    private struct InjectedSaveFailure: Error {}

    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private var bench: Exercise {
        ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
    }

    /// Anchored to midday: the store groups sets by calendar day (#79).
    private var midday: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func set(_ pounds: Double, _ reps: Int) -> SetRecord {
        SetRecord(exerciseID: bench.id, load: Load(pounds), reps: reps, performedAt: midday)
    }

    func testRetryingAFailedLogSavesExactlyOneSet() throws {
        store.saveFault = InjectedSaveFailure()
        XCTAssertThrowsError(try store.log(set(185, 5)))

        // The UI's retry builds a fresh record, so a new id.
        let retry = set(185, 5)
        try store.log(retry)

        XCTAssertEqual(try store.allSets(), [retry])
    }

    func testAFailedDeleteIsNotCommittedByTheNextWrite() throws {
        let kept = set(185, 5)
        try store.log(kept)

        store.saveFault = InjectedSaveFailure()
        XCTAssertThrowsError(try store.deleteSet(id: kept.id))

        let next = set(185, 4)
        try store.log(next)

        XCTAssertEqual(Set(try store.allSets().map(\.id)), [kept.id, next.id],
                       "the delete the lifter was told failed must not land later")
    }

    func testAFailedCorrectionIsNotCommittedByTheNextWrite() throws {
        let original = set(185, 5)
        try store.log(original)

        var corrected = original
        corrected.reps = 8
        store.saveFault = InjectedSaveFailure()
        XCTAssertThrowsError(try store.updateSet(corrected))

        try store.log(set(185, 4))

        let stored = try XCTUnwrap(try store.allSets().first { $0.id == original.id })
        XCTAssertEqual(stored.reps, 5)
    }
}
