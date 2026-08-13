import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Issue #2's done-when: "library loads on first launch". First launch is the
/// easy half — the assertions that matter are about the second and third.
@MainActor
final class LibrarySeedingTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = URL.temporaryDirectory
            .appending(path: "seeding-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: storeURL.path() + suffix))
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    private func reopen() throws -> TrainingStore {
        try TrainingStore(url: storeURL)
    }

    func testFirstLaunchSeedsTheWholeLibrary() throws {
        let store = try reopen()
        let inserted = try store.seedLibraryIfNeeded()

        XCTAssertEqual(inserted.count, ExerciseLibrary.all.count)
        XCTAssertEqual(try store.exercises().count, ExerciseLibrary.all.count)
        for exercise in ExerciseLibrary.all {
            XCTAssertEqual(try store.exercise(id: exercise.id), exercise, exercise.name)
        }
    }

    func testSecondLaunchSeedsNothing() throws {
        try reopen().seedLibraryIfNeeded()

        let second = try reopen()
        XCTAssertEqual(try second.seedLibraryIfNeeded(), [], "no duplicate inserts")
        XCTAssertEqual(try second.exercises().count, ExerciseLibrary.all.count)
    }

    /// The reason seeding is insert-missing rather than seed-once. A lift added
    /// to the library in a later build has to reach someone whose database is
    /// already populated.
    func testANewLibraryLiftReachesAnExistingDatabase() throws {
        let store = try reopen()
        try store.seedLibraryIfNeeded()

        // Stand in for a future build's addition.
        let newLift = Exercise(
            name: "Cable Pullover",
            muscles: [.primary(.lats)],
            equipment: .cable,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        )
        try store.upsert(newLift)

        let reloaded = try reopen()
        XCTAssertEqual(try reloaded.seedLibraryIfNeeded(), [])
        XCTAssertEqual(try reloaded.exercises().count, ExerciseLibrary.all.count + 1)
        XCTAssertEqual(try reloaded.exercise(id: newLift.id), newLift)
    }

    /// The other half of that trade: a user's correction survives relaunching.
    /// Machine stacks are seeded with a 10 lb placeholder and get fixed once
    /// measured at the gym (#20) — that fix must not be reverted.
    func testSeedingNeverRevertsAUserEdit() throws {
        let store = try reopen()
        try store.seedLibraryIfNeeded()

        var pulldown = try XCTUnwrap(
            try store.exercises().first { $0.name == "Lat Pulldown" }
        )
        XCTAssertEqual(pulldown.increment.pounds, 10, "seeded placeholder")

        pulldown.increment = LoadIncrement(pounds: 15)
        pulldown.name = "Lat Pulldown (wide)"
        try store.upsert(pulldown)

        let reloaded = try reopen()
        XCTAssertEqual(try reloaded.seedLibraryIfNeeded(), [])
        let after = try XCTUnwrap(try reloaded.exercise(id: pulldown.id))
        XCTAssertEqual(after.increment.pounds, 15)
        XCTAssertEqual(after.name, "Lat Pulldown (wide)")
    }

    /// Seeded lifts are definitions only. Nothing has been performed yet, so
    /// every one of them is a cold start and the session screen says "first
    /// time — just log it" rather than inventing a target.
    func testSeededLiftsStartCold() throws {
        let store = try reopen()
        try store.seedLibraryIfNeeded()
        for exercise in try store.exercises() {
            XCTAssertNil(
                try store.progressState(forExercise: exercise.id),
                "\(exercise.name) was seeded with a fabricated target"
            )
        }
    }

    /// The tags have to survive the JSON round-trip, since that's where
    /// volume-by-muscle reads them from.
    func testMuscleTagsSurviveSeedingAndRelaunch() throws {
        try reopen().seedLibraryIfNeeded()

        let reloaded = try reopen().exercises()
        for exercise in reloaded {
            XCTAssertFalse(exercise.primaryMuscles.isEmpty, exercise.name)
        }
        let bench = try XCTUnwrap(reloaded.first { $0.name == "Flat Bench" })
        XCTAssertEqual(bench.primaryMuscles, [.chest])
        XCTAssertEqual(bench.volumeContribution(to: .chest), 1.0)
        XCTAssertEqual(bench.volumeContribution(to: .triceps), 0.5)
        XCTAssertEqual(bench.volumeContribution(to: .quads), 0)
        XCTAssertEqual(bench.progressionRule, .rpeTargetedLoad(reps: 5, targetRPE: .eight))
    }
}
