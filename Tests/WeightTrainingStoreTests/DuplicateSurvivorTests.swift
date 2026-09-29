import XCTest
import SwiftData
import WeightTrainingCore
@testable import WeightTrainingStore

/// Which copy `deduplicate()` keeps when duplicates disagree (#268).
///
/// Two things have to hold, and the old `candidates.first` rule broke both:
///
/// - **The lifter's edit beats a freshly seeded default.** On a new device the
///   stock catalogue is seeded before CloudKit's first import, and fetch order
///   is insertion order, so "first" was the seed every time — and deleting the
///   edited copy is a delete that syncs back out to every device.
/// - **Every device picks the same survivor.** Each device dedupes on its own,
///   and a loser's deletion syncs. If device A keeps its copy and device B
///   keeps its own, each deletes the other's and the row is gone everywhere.
///   So the choice must depend only on what the rows hold, never on the order
///   this device happened to receive them in.
///
/// Rows are inserted straight through the model context, which is how they
/// arrive from a sync.
@MainActor
final class DuplicateSurvivorTests: XCTestCase {

    private var bench: Exercise {
        ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
    }

    /// The lifter's copy as it exists on the other device.
    private var editedBench: Exercise {
        var edited = bench
        edited.name = "Paused Bench"
        edited.restOverride = 240
        edited.increment = LoadIncrement(pounds: 2.5)
        return edited
    }

    private func insertRaw(_ model: some PersistentModel, into store: TrainingStore) throws {
        store.modelContext.insert(model)
        try store.saveChanges()
    }

    private func midday() -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 10; components.hour = 12
        return Calendar.current.date(from: components)!
    }

    // MARK: - The reported sequence

    /// A new phone: seed at launch, then the first import brings the lifter's
    /// edited copy of a catalogue lift with the same id.
    func testASecondDevicesFirstSyncKeepsTheEditedLift() throws {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try insertRaw(StoredExercise(editedBench), into: store)

        let report = try store.deduplicate()

        XCTAssertEqual(report.exercises, 1)
        let kept = try XCTUnwrap(try store.exercise(id: bench.id))
        XCTAssertEqual(kept.name, "Paused Bench")
        XCTAssertEqual(kept.restOverride, 240)
        XCTAssertEqual(kept.increment, LoadIncrement(pounds: 2.5))
    }

    /// The same, the other way round: the edit already on disk, the seed
    /// arriving second. Insertion order must not decide it.
    func testTheEditedLiftSurvivesWhicheverCopyArrivesFirst() throws {
        let store = try TrainingStore.inMemory()
        try insertRaw(StoredExercise(editedBench), into: store)
        try store.seedLibraryIfNeeded()
        try insertRaw(StoredExercise(bench), into: store)

        try store.deduplicate()

        XCTAssertEqual(try store.exercise(id: bench.id)?.name, "Paused Bench")
        XCTAssertEqual(try store.exercises().filter { $0.id == bench.id }.count, 1)
    }

    /// The on-disk store the app actually uses, not only the in-memory one —
    /// the issue reproduced on both.
    func testTheEditedLiftSurvivesOnAFileStore() throws {
        let url = URL.temporaryDirectory.appending(path: "dedupe-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + suffix))
            }
        }
        let store = try TrainingStore(url: url)
        try store.seedLibraryIfNeeded()
        try insertRaw(StoredExercise(editedBench), into: store)

        try store.deduplicate()

        XCTAssertEqual(try store.exercise(id: bench.id)?.name, "Paused Bench")
        XCTAssertEqual(try store.exercise(id: bench.id)?.restOverride, 240)
    }

    /// The window before a dedupe pass: a read must already answer with the
    /// copy the pass will keep, or the first screen after an import shows the
    /// stock lift and an edit made from it would overwrite the wrong copy.
    func testReadsBeforeDeduplicationAlreadyShowTheEdit() throws {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try insertRaw(StoredExercise(editedBench), into: store)

        XCTAssertEqual(try store.exercise(id: bench.id)?.name, "Paused Bench")
        XCTAssertEqual(
            try store.exercises().first { $0.id == bench.id }?.name, "Paused Bench"
        )
    }

    // MARK: - Two devices, one answer

    /// Both devices hold both copies, received in opposite orders. They must
    /// keep the same one, or each deletes the other's and the lift is lost.
    func testTwoDevicesKeepTheSameCopyOfADisputedLift() throws {
        var custom = Exercise(
            name: "Zercher Squat",
            muscles: [MuscleInvolvement(bench.muscles[0].muscle, .primary)],
            equipment: .barbell,
            progressionRule: bench.progressionRule
        )
        let one = custom
        custom.name = "Zercher Box Squat"
        let other = custom

        let deviceA = try TrainingStore.inMemory()
        try insertRaw(StoredExercise(one), into: deviceA)
        try insertRaw(StoredExercise(other), into: deviceA)

        let deviceB = try TrainingStore.inMemory()
        try insertRaw(StoredExercise(other), into: deviceB)
        try insertRaw(StoredExercise(one), into: deviceB)

        try deviceA.deduplicate()
        try deviceB.deduplicate()

        XCTAssertEqual(
            try deviceA.exercise(id: custom.id), try deviceB.exercise(id: custom.id)
        )
    }

    /// Sets have been correctable since #61, so two copies of one set can
    /// genuinely disagree. The same convergence has to hold.
    func testTwoDevicesKeepTheSameCopyOfADisputedSet() throws {
        let original = SetRecord(exerciseID: bench.id, load: Load(185), reps: 80,
                                 rpe: RPE(8), performedAt: midday())
        var corrected = original
        corrected.reps = 8

        let deviceA = try TrainingStore.inMemory()
        try insertRaw(StoredSetLog(original), into: deviceA)
        try insertRaw(StoredSetLog(corrected), into: deviceA)

        let deviceB = try TrainingStore.inMemory()
        try insertRaw(StoredSetLog(corrected), into: deviceB)
        try insertRaw(StoredSetLog(original), into: deviceB)

        try deviceA.deduplicate()
        try deviceB.deduplicate()

        XCTAssertEqual(try deviceA.allSets(), try deviceB.allSets())
        XCTAssertEqual(try deviceA.allSets().count, 1)
    }

    func testTwoDevicesKeepTheSameCopyOfADisputedTemplate() throws {
        var trimmed = DayTemplateLibrary.push
        trimmed.slots.removeLast()

        let deviceA = try TrainingStore.inMemory()
        try insertRaw(StoredDayTemplate(DayTemplateLibrary.push), into: deviceA)
        try insertRaw(StoredDayTemplate(trimmed), into: deviceA)

        let deviceB = try TrainingStore.inMemory()
        try insertRaw(StoredDayTemplate(trimmed), into: deviceB)
        try insertRaw(StoredDayTemplate(DayTemplateLibrary.push), into: deviceB)

        try deviceA.deduplicate()
        try deviceB.deduplicate()

        XCTAssertEqual(try deviceA.dayTemplates(), try deviceB.dayTemplates())
        XCTAssertEqual(try deviceA.dayTemplates().first?.slots, trimmed.slots,
                       "the copy that differs from the stock day is the lifter's")
    }

    // MARK: - Stamps

    /// A row exactly as another device holds it: the values, the stamp and
    /// the copy's own identity, which is what arrives from CloudKit.
    private func synced(_ exercise: Exercise, stamp: Date?, copyID: UUID? = UUID()) -> StoredExercise {
        let row = StoredExercise(exercise, updatedAt: stamp)
        row.copyID = copyID
        return row
    }

    private func survivingCopy(of id: UUID, in store: TrainingStore) throws -> StoredExercise? {
        try store.modelContext.fetch(FetchDescriptor<StoredExercise>())
            .filter { $0.id == id }
            .first
    }

    /// Between two edits, the later one wins, whichever device holds which.
    func testTheLaterEditWinsOnBothDevices() throws {
        var older = bench; older.name = "Paused Bench"
        var newer = bench; newer.name = "Spoto Press"
        let olderRow = { self.synced(older, stamp: Date(timeIntervalSince1970: 1_000_000), copyID: UUID(uuidString: "00000000-0000-0000-0000-00000000000F")) }
        let newerRow = { self.synced(newer, stamp: Date(timeIntervalSince1970: 2_000_000), copyID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")) }

        let deviceA = try TrainingStore.inMemory()
        try insertRaw(olderRow(), into: deviceA)
        try insertRaw(newerRow(), into: deviceA)
        let deviceB = try TrainingStore.inMemory()
        try insertRaw(newerRow(), into: deviceB)
        try insertRaw(olderRow(), into: deviceB)

        try deviceA.deduplicate()
        try deviceB.deduplicate()

        XCTAssertEqual(try deviceA.exercise(id: bench.id)?.name, "Spoto Press")
        XCTAssertEqual(try deviceB.exercise(id: bench.id)?.name, "Spoto Press")
    }

    /// A lifter who puts a lift back to its stock values has still written it,
    /// and that write is newer than the edit it undoes. "Differs from the
    /// catalogue" is only a tiebreak between rows nobody stamped.
    func testPuttingALiftBackToStockIsAWriteLikeAnyOther() throws {
        let store = try TrainingStore.inMemory()
        try insertRaw(synced(editedBench, stamp: nil), into: store)
        try insertRaw(synced(bench, stamp: Date(timeIntervalSince1970: 2_000_000)), into: store)

        try store.deduplicate()

        XCTAssertEqual(try store.exercise(id: bench.id), bench)
    }

    /// Copies with identical values: keeping either loses nothing, but both
    /// devices must keep the same *copy*, or each deletes the other's.
    func testIdenticalCopiesConvergeOnTheSameRecord() throws {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        // Byte-identical, as two copies of one seed are: the JSON blobs are
        // built once and shared, because encoding the same value twice can
        // order its keys differently — and a real record's bytes are the same
        // on every device that holds it.
        let prototype = StoredExercise(bench, updatedAt: EditStamp.stock)
        func copy(_ copyID: UUID) -> StoredExercise {
            let row = StoredExercise(bench, updatedAt: EditStamp.stock)
            row.musclesData = prototype.musclesData
            row.progressionRuleData = prototype.progressionRuleData
            row.loadingData = prototype.loadingData
            row.copyID = copyID
            return row
        }

        let deviceA = try TrainingStore.inMemory()
        try insertRaw(copy(first), into: deviceA)
        try insertRaw(copy(second), into: deviceA)
        let deviceB = try TrainingStore.inMemory()
        try insertRaw(copy(second), into: deviceB)
        try insertRaw(copy(first), into: deviceB)

        try deviceA.deduplicate()
        try deviceB.deduplicate()

        let keptA = try XCTUnwrap(survivingCopy(of: bench.id, in: deviceA)?.copyID)
        let keptB = try XCTUnwrap(survivingCopy(of: bench.id, in: deviceB)?.copyID)
        XCTAssertEqual(keptA, keptB)
        XCTAssertEqual(keptA, second, "decided by the copy, the only thing left")
    }

    /// Seeding marks a row as stock rather than stamping it with the time it
    /// was seeded — otherwise every fresh install's catalogue would be the
    /// newest write in the account.
    func testSeedingStampsRowsAsStock() throws {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try store.seedTemplatesIfNeeded()

        let lifts = try store.modelContext.fetch(FetchDescriptor<StoredExercise>())
        XCTAssertFalse(lifts.isEmpty)
        XCTAssertTrue(lifts.allSatisfy { $0.updatedAt == EditStamp.stock })
        XCTAssertTrue(lifts.allSatisfy { $0.copyID != nil })
        let days = try store.modelContext.fetch(FetchDescriptor<StoredDayTemplate>())
        XCTAssertTrue(days.allSatisfy { $0.updatedAt == EditStamp.stock })
    }

    /// Imports land in batches. When the gym arrives first, this device
    /// re-racks its seeded copy — which then no longer equals the catalogue —
    /// before the lifter's edited copy arrives. The re-rack is derived, not a
    /// write by the lifter, so the seed still loses.
    func testAReRackedSeedStillLosesToTheLiftersEdit() throws {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try store.saveGymConfig(GymConfig(unit: .kilograms))
        XCTAssertNotEqual(try store.exercise(id: bench.id), bench, "re-racked")

        var edited = try XCTUnwrap(try store.exercise(id: bench.id))
        edited.name = "Paused Bench"
        try insertRaw(synced(edited, stamp: nil), into: store)
        try store.deduplicate()

        XCTAssertEqual(try store.exercise(id: bench.id)?.name, "Paused Bench")
    }

    func testAnEditThroughTheStoreIsStamped() throws {
        let store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try store.upsert(editedBench)

        let row = try XCTUnwrap(survivingCopy(of: bench.id, in: store))
        let stamp = try XCTUnwrap(row.updatedAt)
        XCTAssertNotEqual(stamp, EditStamp.stock)
        XCTAssertEqual(stamp.timeIntervalSince1970.rounded(.down), stamp.timeIntervalSince1970,
                       "whole seconds, so CloudKit's rounding can't reorder two stamps")
    }

    /// A corrected set (#61) beats the set as first logged on another device.
    func testACorrectedSetBeatsTheOriginalInEitherOrder() throws {
        let original = SetRecord(exerciseID: bench.id, load: Load(185), reps: 80,
                                 rpe: RPE(8), performedAt: midday())
        var corrected = original
        corrected.reps = 8

        let deviceA = try TrainingStore.inMemory()
        try deviceA.log(original)
        XCTAssertTrue(try deviceA.updateSet(corrected))
        let stamp = try XCTUnwrap(try deviceA.modelContext.fetch(FetchDescriptor<StoredSetLog>()).first?.updatedAt)

        for correctionFirst in [true, false] {
            let deviceB = try TrainingStore.inMemory()
            let fromA = StoredSetLog(corrected, updatedAt: stamp)
            if correctionFirst { try insertRaw(fromA, into: deviceB) }
            try insertRaw(StoredSetLog(original), into: deviceB)
            if !correctionFirst { try insertRaw(fromA, into: deviceB) }

            XCTAssertEqual(try deviceB.allSets().map(\.reps), [8], "read before the pass")
            try deviceB.deduplicate()
            XCTAssertEqual(try deviceB.allSets().map(\.reps), [8])
        }
    }

    /// A restore stamps what it writes with when the file was written. An
    /// edit made on another device after that export is newer, and survives
    /// when it arrives.
    func testAnEditNewerThanARestoredBackupSurvives() throws {
        let exportedAt = midday()
        let archive = TrainingArchive(exportedAt: exportedAt, exercises: [bench])

        let store = try TrainingStore.inMemory()
        try store.restore(from: archive)
        try insertRaw(synced(editedBench, stamp: EditStamp.at(exportedAt.addingTimeInterval(3600))),
                      into: store)
        try store.deduplicate()

        XCTAssertEqual(try store.exercise(id: bench.id)?.name, "Paused Bench")
    }
}
