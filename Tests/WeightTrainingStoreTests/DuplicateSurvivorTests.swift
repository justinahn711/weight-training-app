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
}
