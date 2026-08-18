import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Correcting a set logged on any past day (#61).
///
/// Until this existed, undo reached exactly one set — the newest — so a voice
/// mishear from Tuesday was permanent, and it kept inflating volume, e1RM and
/// every target derived from it.
@MainActor
final class SetCorrectionTests: XCTestCase {
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

    private func logged(_ pounds: Double, _ reps: Int, daysAgo: Double) throws -> SetRecord {
        let record = SetRecord(
            exerciseID: bench.id, load: Load(pounds), reps: reps, rpe: RPE(8),
            performedAt: Date().addingTimeInterval(-daysAgo * 86_400)
        )
        try store.log(record)
        return record
    }

    /// The case the issue is named for: "eighty" heard as "eight", noticed days
    /// later.
    func testAnOldSetCanBeCorrected() throws {
        let original = try logged(185, 5, daysAgo: 4)

        var corrected = original
        corrected.reps = 8
        XCTAssertTrue(try store.updateSet(corrected))

        let stored = try XCTUnwrap(store.allSets().first { $0.id == original.id })
        XCTAssertEqual(stored.reps, 8)
        XCTAssertEqual(stored.load, Load(185), "only what was corrected changes")
    }

    /// Correcting a set corrects everything read from it. Nothing is cached, so
    /// fixing history is the whole fix.
    func testDerivedFiguresFollowTheCorrection() throws {
        let original = try logged(500, 5, daysAgo: 1)   // a fat-fingered load

        let before = try XCTUnwrap(store.allSets().first { $0.id == original.id })
        XCTAssertEqual(before.load, Load(500))

        var corrected = original
        corrected.load = Load(200)
        try store.updateSet(corrected)

        let sets = try store.sets(forExercise: bench.id)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.load, Load(200))
    }

    /// A working set mislogged as a warmup is invisible to every statistic, so
    /// the flag has to be correctable too.
    func testAWarmupFlagCanBeCorrected() throws {
        var record = SetRecord(exerciseID: bench.id, load: Load(185), reps: 5,
                               rpe: RPE(8), isWarmup: true, performedAt: Date())
        try store.log(record)

        record.isWarmup = false
        try store.updateSet(record)

        let stored = try XCTUnwrap(store.allSets().first { $0.id == record.id })
        XCTAssertFalse(stored.isWarmup)
    }

    /// Identity and timing survive a correction: fixing a set must not move it
    /// to another day.
    func testCorrectionKeepsIdentityAndDay() throws {
        let original = try logged(185, 5, daysAgo: 2)

        var corrected = original
        corrected.load = Load(190)
        try store.updateSet(corrected)

        let stored = try XCTUnwrap(store.allSets().first { $0.id == original.id })
        XCTAssertEqual(stored.id, original.id)
        XCTAssertEqual(stored.performedAt.timeIntervalSince1970,
                       original.performedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(stored.exerciseID, bench.id)
    }

    /// An edit racing a delete from another device is a no-op, not a failure —
    /// and must not resurrect the set.
    func testCorrectingAMissingSetDoesNothing() throws {
        let record = SetRecord(exerciseID: bench.id, load: Load(185), reps: 5,
                               rpe: RPE(8), performedAt: Date())
        XCTAssertFalse(try store.updateSet(record))
        XCTAssertTrue(try store.allSets().isEmpty, "must not insert what it couldn't find")
    }
}
