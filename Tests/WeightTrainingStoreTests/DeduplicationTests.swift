import XCTest
import SwiftData
import WeightTrainingCore
@testable import WeightTrainingStore

/// Uniqueness used to be the database's job. CloudKit mirroring can't enforce
/// it — two devices offline at the same gym can each create the same row, and
/// neither is wrong until they meet — so these tests stand in for the
/// constraints the schema gave up.
///
/// Duplicates are inserted directly through the model context, which is exactly
/// how they'd arrive from a sync: bypassing `upsert` entirely.
@MainActor
final class DeduplicationTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private var incline: Exercise {
        ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
    }

    /// Simulates a row arriving from another device.
    private func insertRaw(_ model: some PersistentModel) throws {
        store.modelContext.insert(model)
        try store.saveChanges()
    }

    // MARK: - Exercises

    func testDuplicateExercisesCollapseToOne() throws {
        try store.upsert(incline)
        try insertRaw(StoredExercise(incline))
        try insertRaw(StoredExercise(incline))

        let report = try store.deduplicate()
        XCTAssertEqual(report.exercises, 2)
        XCTAssertEqual(try store.exercises().count, 1)
    }

    /// A duplicate must never reach the UI, including in the window before a
    /// dedupe pass has run.
    func testReadsAreCorrectBeforeDeduplicationRuns() throws {
        try store.upsert(incline)
        try insertRaw(StoredExercise(incline))

        XCTAssertEqual(try store.exercises().count, 1, "uniqued on the way out")
        XCTAssertEqual(try store.exercise(id: incline.id)?.name, "Incline DB Press")
    }

    // MARK: - Sets

    /// A duplicated set is not cosmetic: it inflates volume, e1RM, and every
    /// progression decision that reads the session.
    func testDuplicateSetsAreNotCountedTwice() throws {
        let record = SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                               rpe: RPE(8), performedAt: Date())
        try store.log(record)
        try insertRaw(StoredSetLog(record))

        XCTAssertEqual(try store.allSets().count, 1)
        XCTAssertEqual(try store.sets(forExercise: incline.id).count, 1)
        XCTAssertEqual(try store.sets(since: .distantPast).count, 1)

        let report = try store.deduplicate()
        XCTAssertEqual(report.sets, 1)
        XCTAssertEqual(try store.allSets().count, 1)
    }

    /// Two genuinely different sets that happen to look alike are not
    /// duplicates — identity is the id, not the values.
    func testTwoIdenticalLookingSetsAreKept() throws {
        let now = Date()
        try store.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                                rpe: RPE(8), performedAt: now))
        try store.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                                rpe: RPE(8), performedAt: now))

        XCTAssertEqual(try store.deduplicate().sets, 0)
        XCTAssertEqual(try store.allSets().count, 2, "straight sets repeat by design")
    }

    // MARK: - Progress state

    /// The only genuinely conflicting entity: two devices can each advance a
    /// lift's target while offline. The one that saw the later session wins.
    func testConflictingProgressStatesResolveToTheMostRecentlyPerformed() throws {
        let older = ProgressState(
            exerciseID: incline.id, targetLoad: Load(70), targetReps: 10,
            lastPerformedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = ProgressState(
            exerciseID: incline.id, targetLoad: Load(80), targetReps: 8,
            lastPerformedAt: Date(timeIntervalSince1970: 9_000)
        )
        try insertRaw(StoredProgressState(older))
        try insertRaw(StoredProgressState(newer))

        // Correct even before the merge.
        XCTAssertEqual(try store.progressState(forExercise: incline.id)?.targetLoad,
                       Load(80))

        let report = try store.deduplicate()
        XCTAssertEqual(report.progressStates, 1)
        let survivor = try XCTUnwrap(try store.progressState(forExercise: incline.id))
        XCTAssertEqual(survivor.targetLoad, Load(80))
        XCTAssertEqual(survivor.targetReps, 8)
    }

    /// A state that never recorded a session loses to one that did.
    func testAStateThatNeverTrainedLosesToOneThatDid() throws {
        try insertRaw(StoredProgressState(ProgressState(exerciseID: incline.id)))
        try insertRaw(StoredProgressState(ProgressState(
            exerciseID: incline.id, targetLoad: Load(75),
            lastPerformedAt: Date(timeIntervalSince1970: 5_000)
        )))

        try store.deduplicate()
        XCTAssertEqual(try store.progressState(forExercise: incline.id)?.targetLoad,
                       Load(75))
    }

    // MARK: - Templates

    func testDuplicateTemplatesCollapse() throws {
        try store.seedTemplatesIfNeeded()
        try insertRaw(StoredDayTemplate(DayTemplateLibrary.push))

        XCTAssertEqual(try store.deduplicate().dayTemplates, 1)
        XCTAssertEqual(try store.dayTemplates().count, DayTemplateLibrary.all.count)
    }

    /// The same guarantee the exercise reads make: a duplicate never reaches a
    /// caller, including before a dedupe pass has run.
    ///
    /// This is the fresh-install window, observed for real: `deduplicate()` and
    /// the seeds run at launch, before CloudKit's first import arrives, so the
    /// library is seeded into an apparently empty store and the import then
    /// delivers a second copy of every row.
    func testTemplateReadsAreCorrectBeforeDeduplicationRuns() throws {
        try store.seedTemplatesIfNeeded()
        for template in DayTemplateLibrary.all {
            try insertRaw(StoredDayTemplate(template))
        }

        XCTAssertEqual(
            try store.dayTemplates().count, DayTemplateLibrary.all.count,
            "uniqued on the way out"
        )
        XCTAssertEqual(try store.dayTemplate(kind: .push)?.kind, .push)
    }

    // MARK: - Cost and safety

    /// Safe to run on every launch: no duplicates means no writes.
    func testACleanStoreIsUntouched() throws {
        try store.seedLibraryIfNeeded()
        try store.seedTemplatesIfNeeded()
        try store.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                                rpe: RPE(8), performedAt: Date()))

        let report = try store.deduplicate()
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(try store.exercises().count, ExerciseLibrary.all.count)
    }

    func testDeduplicationIsIdempotent() throws {
        try store.upsert(incline)
        try insertRaw(StoredExercise(incline))

        XCTAssertEqual(try store.deduplicate().exercises, 1)
        XCTAssertTrue(try store.deduplicate().isEmpty, "nothing left to do")
    }

    /// Seeding stays correct without the unique constraint behind it.
    func testSeedingStillNeverDuplicates() throws {
        try store.seedLibraryIfNeeded()
        try store.seedLibraryIfNeeded()
        try store.seedTemplatesIfNeeded()
        try store.seedTemplatesIfNeeded()

        XCTAssertEqual(try store.exercises().count, ExerciseLibrary.all.count)
        XCTAssertEqual(try store.dayTemplates().count, DayTemplateLibrary.all.count)
        XCTAssertTrue(try store.deduplicate().isEmpty)
    }
}

/// Sync must never be something a test depends on. A suite that talks to a
/// network account isn't a suite.
@MainActor
final class CloudKitConfigurationTests: XCTestCase {

    func testTestStoresNeverSync() throws {
        let memory = try TrainingStore.inMemory()
        XCTAssertFalse(memory.isCloudKitEnabled)

        let url = URL.temporaryDirectory.appending(path: "sync-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
            }
        }
        let file = try TrainingStore(url: url)
        XCTAssertFalse(file.isCloudKitEnabled, "sync is opt-in, never the default")
    }

    /// Asking for sync without an entitlement must still open a working store.
    ///
    /// Note what this proves and doesn't: SwiftData builds the container
    /// happily with no entitlement and fails later at sync time, so this test
    /// documents that the app keeps working rather than that sync is off.
    /// Whether data actually reaches iCloud can only be answered on a device
    /// signed into an account.
    func testAskingForSyncWithoutAnEntitlementStillOpens() throws {
        let url = URL.temporaryDirectory.appending(path: "sync-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
            }
        }

        // The test bundle carries no iCloud entitlement, so this exercises the
        // fallback path exactly as an unconfigured app would.
        let store = try TrainingStore(url: url, syncsWithCloudKit: true)

        // The store opens and works regardless of whether sync is real.
        try store.seedLibraryIfNeeded()
        XCTAssertEqual(try store.exercises().count, ExerciseLibrary.all.count)
    }
}
