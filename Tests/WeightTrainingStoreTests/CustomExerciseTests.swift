import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Lifts someone adds themselves (#76).
///
/// The library's own doc comment has always promised "anything missing can be
/// added in-app". Until now nothing could.
@MainActor
final class CustomExerciseTests: XCTestCase {
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

    private func pullUps() -> Exercise {
        Exercise(
            name: "Pull-ups",
            muscles: [.primary(.lats), .secondary(.biceps)],
            equipment: .bodyweight,
            progressionRule: .doubleProgression(range: RepRange(5, 10))
        )
    }

    func testACreatedLiftIsStoredAndListed() throws {
        try store.create(pullUps())
        XCTAssertTrue(try store.exercises().contains { $0.name == "Pull-ups" })
    }

    /// Seeding runs on every launch and inserts missing catalogue lifts. It
    /// must not touch, duplicate or revert a created one.
    func testSeedingLeavesCreatedLiftsAlone() throws {
        try store.create(pullUps())
        try store.seedLibraryIfNeeded()
        try store.seedLibraryIfNeeded()

        let matches = try store.exercises().filter { $0.name == "Pull-ups" }
        XCTAssertEqual(matches.count, 1)
    }

    /// #72, for free: a created lift is invisible to seeding, so deleting it
    /// stays deleted without needing a tombstone.
    func testDeletingACreatedLiftSticksAcrossSeeding() throws {
        let mine = pullUps()
        try store.create(mine)
        XCTAssertTrue(try store.deleteExercise(id: mine.id))

        try store.seedLibraryIfNeeded()
        XCTAssertFalse(try store.exercises().contains { $0.id == mine.id })
    }

    /// The catalogue isn't yours to delete: it's shared, seeding would put it
    /// back, and "I don't do this" is a preference rather than a fact about
    /// the exercise.
    func testCatalogueLiftsCannotBeDeleted() throws {
        let seeded = try XCTUnwrap(try store.exercises().first)
        XCTAssertFalse(try store.deleteExercise(id: seeded.id))
        XCTAssertTrue(try store.exercises().contains { $0.id == seeded.id })
    }

    /// The training happened. Deleting the lift is not a claim that it didn't.
    func testDeletingALiftKeepsItsSets() throws {
        let mine = pullUps()
        try store.create(mine)
        try store.log(SetRecord(exerciseID: mine.id, load: Load(0), reps: 8,
                                rpe: RPE(8), performedAt: Date()))

        try store.deleteExercise(id: mine.id)
        XCTAssertEqual(try store.allSets().count, 1, "sets survive the lift")
    }

    // MARK: - What a lift can't do without

    /// A nameless lift is unusable in the picker.
    func testANamelessLiftIsRefused() {
        let nameless = Exercise(name: "   ", muscles: [.primary(.lats)],
                                equipment: .bodyweight,
                                progressionRule: .doubleProgression(range: RepRange(5, 10)))
        XCTAssertThrowsError(try store.create(nameless))
    }

    /// An untagged lift is invisible to the volume report — the insight that's
    /// meant to work whatever someone trains.
    func testALiftWithNoPrimaryMuscleIsRefused() {
        let untagged = Exercise(name: "Mystery", muscles: [.secondary(.biceps)],
                                equipment: .cable,
                                progressionRule: .doubleProgression(range: RepRange(8, 12)))
        XCTAssertThrowsError(try store.create(untagged))
    }

    /// Names are trimmed, so " Pull-ups " and "Pull-ups" aren't two lifts.
    func testNamesAreTrimmed() throws {
        var spaced = pullUps()
        spaced.name = "  Pull-ups  "
        try store.create(spaced)
        XCTAssertEqual(try store.exercises().first { $0.id == spaced.id }?.name, "Pull-ups")
    }

    /// A created lift counts towards volume like any other, which is the whole
    /// point — the muscle insight is plan-agnostic.
    func testACreatedLiftCountsTowardsVolume() throws {
        let mine = pullUps()
        try store.create(mine)
        for _ in 0..<3 {
            try store.log(SetRecord(exerciseID: mine.id, load: Load(0), reps: 8,
                                    rpe: RPE(8), performedAt: Date()))
        }

        let report = try store.volumeReport()
        let lats = report.muscles.first { $0.muscle == .lats }
        XCTAssertEqual(lats?.sets, 3)
    }
}
