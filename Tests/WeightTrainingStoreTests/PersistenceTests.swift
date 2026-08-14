import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Issue #1's done-when: "models persist locally and a session round-trips
/// through a relaunch."
///
/// A relaunch is simulated the only way that actually proves anything — write
/// through one `TrainingStore`, drop it entirely, then open a *second* store
/// against the same file on disk and read back. An in-memory container would
/// pass these assertions while proving nothing about persistence.
@MainActor
final class PersistenceTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = URL.temporaryDirectory
            .appending(path: "training-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        // SwiftData writes sidecar files next to the store; clearing the whole
        // set keeps one test's leftovers from being read by the next.
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(filePath: storeURL.path() + suffix)
            try? FileManager.default.removeItem(at: url)
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    /// Opens a fresh store against the same file — a relaunch, as far as the
    /// persistence layer can tell.
    private func reopen() throws -> TrainingStore {
        try TrainingStore(url: storeURL)
    }

    // MARK: - Fixtures

    private func inclinePress() -> Exercise {
        Exercise(
            name: "Incline DB Press",
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            needsWarmupRamp: true
        )
    }

    private func flatBench() -> Exercise {
        Exercise(
            name: "Flat Bench",
            muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight),
            needsWarmupRamp: true
        )
    }

    // MARK: - Round trip

    func testExerciseSurvivesRelaunch() throws {
        let exercise = inclinePress()
        do {
            let store = try reopen()
            try store.upsert(exercise)
        }

        let reloaded = try XCTUnwrap(try reopen().exercise(id: exercise.id))
        XCTAssertEqual(reloaded, exercise)
        // Spot-check the fields that go through JSON rather than columns.
        XCTAssertEqual(reloaded.muscles.count, 3)
        XCTAssertEqual(reloaded.primaryMuscles, [.chest])
        XCTAssertEqual(
            reloaded.progressionRule,
            .doubleProgression(range: RepRange(8, 12), consecutiveTopHitsRequired: 2)
        )
        XCTAssertTrue(reloaded.needsWarmupRamp)
    }

    /// The enum-with-associated-values case that motivated storing the rule as
    /// JSON in the first place.
    func testRPETargetedRuleSurvivesRelaunch() throws {
        let exercise = flatBench()
        do {
            let store = try reopen()
            try store.upsert(exercise)
        }

        let reloaded = try XCTUnwrap(try reopen().exercise(id: exercise.id))
        XCTAssertEqual(reloaded.progressionRule, .rpeTargetedLoad(reps: 5, targetRPE: .eight))
        XCTAssertEqual(reloaded.increment.pounds, 5, "barbell default increment")
    }

    /// The headline requirement: a whole session, logged and read back after a
    /// relaunch, in the order it was performed.
    func testFullSessionRoundTripsThroughRelaunch() throws {
        let exercise = inclinePress()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let session: [SetRecord] = [
            SetRecord(exerciseID: exercise.id, load: Load(45), reps: 10,
                      isWarmup: true, performedAt: start),
            SetRecord(exerciseID: exercise.id, load: Load(60), reps: 5,
                      isWarmup: true, performedAt: start.addingTimeInterval(120)),
            SetRecord(exerciseID: exercise.id, load: Load(70), reps: 11,
                      rpe: RPE(8), performedAt: start.addingTimeInterval(300)),
            SetRecord(exerciseID: exercise.id, load: Load(70), reps: 10,
                      rpe: RPE(9), performedAt: start.addingTimeInterval(500)),
            SetRecord(exerciseID: exercise.id, load: Load(70), reps: 8,
                      rpe: RPE(9.5), performedAt: start.addingTimeInterval(700)),
        ]

        do {
            let store = try reopen()
            try store.upsert(exercise)
            for record in session { try store.log(record) }
        }

        let reloaded = try reopen().sets(forExercise: exercise.id)
        XCTAssertEqual(reloaded, session, "sets return in performed order, unchanged")
        XCTAssertEqual(reloaded.filter(\.isHardSet).count, 3, "warmups excluded")
        XCTAssertEqual(reloaded.first?.rpe, nil, "warmups carry no RPE")
        XCTAssertEqual(reloaded.last?.rpe, RPE(9.5), "half-step RPE preserved")
    }

    /// A machine measured once must not go back to "unknown" on relaunch —
    /// that's the whole point of storing the loading config (#39).
    func testMeasuredLoadingConfigSurvivesRelaunch() throws {
        var hack = ExerciseLibrary.all.first { $0.name == "Hack Squat" }!
        hack.loading = LoadingStyle(baseWeight: Load(100), sleeves: 2,
                                    availablePlates: [45, 25, 10, 5])
        do {
            let store = try reopen()
            try store.upsert(hack)
        }

        let reloaded = try XCTUnwrap(try reopen().exercise(id: hack.id))
        XCTAssertEqual(reloaded.loading?.baseWeight, Load(100))
        XCTAssertEqual(reloaded.loading?.sleeves, 2)
        XCTAssertEqual(reloaded.loading?.availablePlates, [45, 25, 10, 5])
        XCTAssertEqual(reloaded.plateBreakdown(for: Load(280))?.displayLine, "45 · 45")
    }

    /// An exercise with no plates keeps having none.
    func testAbsentLoadingConfigSurvivesRelaunch() throws {
        let pulldown = ExerciseLibrary.all.first { $0.name == "Lat Pulldown" }!
        do {
            let store = try reopen()
            try store.upsert(pulldown)
        }
        XCTAssertNil(try reopen().exercise(id: pulldown.id)?.loading)
    }

    func testProgressStateSurvivesRelaunch() throws {
        let exercise = inclinePress()
        let state = ProgressState(
            exerciseID: exercise.id,
            targetLoad: Load(70),
            targetReps: 11,
            targetRPE: .eight,
            stallCount: 1,
            consecutiveTopHits: 2,
            lastE1RM: Load(92.5),
            lastPerformedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        do {
            let store = try reopen()
            try store.save(state)
        }

        let reloaded = try XCTUnwrap(try reopen().progressState(forExercise: exercise.id))
        XCTAssertEqual(reloaded, state)
        XCTAssertFalse(reloaded.isColdStart)
    }

    func testDayTemplateSurvivesRelaunch() throws {
        let fly = UUID()
        let skullCrushers = UUID()
        let template = DayTemplate(kind: .push, slots: [
            Slot(name: "Primary press", candidateExerciseIDs: [UUID()]),
            Slot(name: "Accessory", candidateExerciseIDs: [fly, skullCrushers], rotates: true),
        ])

        do {
            let store = try reopen()
            try store.upsert(template)
        }

        let reloaded = try XCTUnwrap(try reopen().dayTemplate(kind: .push))
        XCTAssertEqual(reloaded, template)
        // Rotation is derived from a completion count, so it has to still work
        // off reconstituted slots.
        let accessory = reloaded.slots[1]
        XCTAssertEqual(accessory.dueCandidate(completionCount: 0), fly)
        XCTAssertEqual(accessory.dueCandidate(completionCount: 1), skullCrushers)
        XCTAssertEqual(accessory.dueCandidate(completionCount: 2), fly)
    }

    // MARK: - Upsert and delete

    func testUpsertOverwritesRatherThanDuplicating() throws {
        var exercise = inclinePress()
        let store = try reopen()
        try store.upsert(exercise)

        exercise.name = "Incline Dumbbell Press"
        exercise.increment = LoadIncrement(pounds: 5)
        try store.upsert(exercise)

        let all = try reopen().exercises()
        XCTAssertEqual(all.count, 1, "same id must not create a second row")
        XCTAssertEqual(all.first?.name, "Incline Dumbbell Press")
        XCTAssertEqual(all.first?.increment.pounds, 5)
    }

    func testProgressStateUpsertKeepsOneRowPerExercise() throws {
        let id = UUID()
        let store = try reopen()
        try store.save(ProgressState(exerciseID: id, targetLoad: Load(70), stallCount: 0))
        try store.save(ProgressState(exerciseID: id, targetLoad: Load(75), stallCount: 3))

        let reloaded = try XCTUnwrap(try reopen().progressState(forExercise: id))
        XCTAssertEqual(reloaded.targetLoad, Load(75))
        XCTAssertEqual(reloaded.stallCount, 3)
    }

    /// Backs the one-gesture undo in #8: the row has to be gone, not flagged.
    func testDeletingAMisloggedSetRemovesItPermanently() throws {
        let exerciseID = UUID()
        let keep = SetRecord(exerciseID: exerciseID, load: Load(70), reps: 10,
                             rpe: RPE(8), performedAt: Date(timeIntervalSince1970: 1_000))
        let mistake = SetRecord(exerciseID: exerciseID, load: Load(700), reps: 10,
                                rpe: RPE(8), performedAt: Date(timeIntervalSince1970: 2_000))

        let store = try reopen()
        try store.log(keep)
        try store.log(mistake)
        XCTAssertTrue(try store.deleteSet(id: mistake.id))

        let reloaded = try reopen().sets(forExercise: exerciseID)
        XCTAssertEqual(reloaded, [keep])
    }

    func testDeletingAnAbsentSetReportsFalse() throws {
        let store = try reopen()
        XCTAssertFalse(try store.deleteSet(id: UUID()))
    }

    // MARK: - Queries

    func testSetsSinceFiltersByDate() throws {
        let exerciseID = UUID()
        let cutoff = Date(timeIntervalSince1970: 5_000)
        let store = try reopen()
        try store.log(SetRecord(exerciseID: exerciseID, load: Load(70), reps: 10,
                                performedAt: cutoff.addingTimeInterval(-60)))
        let onCutoff = SetRecord(exerciseID: exerciseID, load: Load(75), reps: 9,
                                 performedAt: cutoff)
        let after = SetRecord(exerciseID: exerciseID, load: Load(80), reps: 8,
                              performedAt: cutoff.addingTimeInterval(60))
        try store.log(onCutoff)
        try store.log(after)

        XCTAssertEqual(try store.sets(since: cutoff), [onCutoff, after],
                       "boundary is inclusive")
    }

    func testExercisesReturnAlphabetically() throws {
        let store = try reopen()
        try store.upsert([flatBench(), inclinePress()])
        XCTAssertEqual(try store.exercises().map(\.name), ["Flat Bench", "Incline DB Press"])
    }

    func testUnknownExerciseIsNil() throws {
        XCTAssertNil(try reopen().exercise(id: UUID()))
    }

    func testColdStartExerciseHasNoProgressState() throws {
        let store = try reopen()
        try store.upsert(inclinePress())
        XCTAssertNil(try store.progressState(forExercise: inclinePress().id))
    }

    func testInMemoryStoreDoesNotTouchDisk() throws {
        let store = try TrainingStore.inMemory()
        try store.upsert(inclinePress())
        XCTAssertEqual(try store.exercises().count, 1)
        XCTAssertEqual(try reopen().exercises().count, 0, "file store stays empty")
    }
}
