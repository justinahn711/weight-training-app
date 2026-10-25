import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// The lifter's default rests, kept on the gym row (#341).
///
/// `RestDefaultsTests` in Core proves the rule. These prove the row: that the
/// two numbers survive a relaunch, a sync collision and a backup, that a row or
/// file from before the setting reads as the standard rests rather than failing,
/// and that a new plan takes its rest from the setting instead of from the last
/// plan, which would otherwise keep an old default alive indefinitely.
///
/// Dates are anchored to a fixed midday (#79).
@MainActor
final class RestDefaultsStoreTests: XCTestCase {
    private var store: TrainingStore!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
        storeURL = URL.temporaryDirectory.appending(path: "rest-defaults-\(UUID().uuidString).store")
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(filePath: storeURL.path() + suffix))
        }
        storeURL = nil
        try super.tearDownWithError()
    }

    private let mine = RestDefaults(compound: 150, accessory: 45)

    private func midday(_ dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10 + dayOffset
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - The row

    func testAnUnconfiguredGymRestsOnTheStandardDefaults() throws {
        XCTAssertEqual(try store.gymConfig().restDefaults, .standard)
        XCTAssertEqual(RestDefaults.standard.compound, 180)
        XCTAssertEqual(RestDefaults.standard.accessory, 60)
    }

    func testRestDefaultsSurviveRelaunch() throws {
        do {
            let first = try TrainingStore(url: storeURL)
            try first.saveGymConfig(GymConfig(restDefaults: mine))
        }
        let second = try TrainingStore(url: storeURL)
        XCTAssertEqual(try second.gymConfig().restDefaults, mine)
    }

    /// Changing a rest default is not a change to the rack, so it must not
    /// touch a single lift. `saveGymConfig` re-racks the lifts that follow the
    /// gym, and its count is what the plate section's footer reads aloud.
    func testChangingARestDefaultRerackesNothing() throws {
        try store.seedLibraryIfNeeded()
        var gym = try store.gymConfig()
        gym.restDefaults = mine
        XCTAssertEqual(try store.saveGymConfig(gym), 0)
        XCTAssertEqual(try store.gymConfig().restDefaults, mine)
    }

    /// A row written before this landed has no rest data at all. It is a gym
    /// that never chose, not a corrupt one, and it must not take the rest of
    /// the row down with it.
    func testARowFromBeforeRestDefaultsReadsAsStandard() throws {
        try store.saveGymConfig(GymConfig(unit: .kilograms, restDefaults: mine))
        let row = try XCTUnwrap(try store.storedGymConfig())
        row.restDefaultsData = Data()
        try store.saveChanges()

        let gym = try store.gymConfig()
        XCTAssertEqual(gym.restDefaults, .standard)
        XCTAssertEqual(gym.unit, .kilograms, "the rest of the row is untouched")
    }

    /// A number that decodes but isn't a usable rest (a corrupt sync, a
    /// hand-edited record) falls back for that kind alone.
    func testAnUnusableStoredRestFallsBackForThatKindOnly() throws {
        try store.saveGymConfig(.standard)
        let row = try XCTUnwrap(try store.storedGymConfig())
        row.restDefaultsData = Data(#"{"compound":-5,"accessory":45}"#.utf8)
        try store.saveChanges()

        let rests = try store.gymConfig().restDefaults
        XCTAssertEqual(rests.compound, 180)
        XCTAssertEqual(rests.accessory, 45)
    }

    /// Rest data that can't be read must not hide the gym. `toDomain()` throwing
    /// makes `GymSettings.refresh` fall back to the standard pound gym for the
    /// whole row, so a kilogram lifter would suddenly see pounds over a setting
    /// as minor as how long to rest.
    func testUnreadableRestDataDoesNotHideTheRestOfTheGym() throws {
        let rack = [25.0, 20, 10, 2.5]
        let bar = Load(15, .kilograms)
        for blob in ["not json at all", "[1, 2, 3]", #""three minutes""#, #"{"compound": "long"}"#] {
            try store.saveGymConfig(GymConfig(
                unit: .kilograms, availablePlates: rack, barWeight: bar, restDefaults: mine))
            let row = try XCTUnwrap(try store.storedGymConfig())
            row.restDefaultsData = Data(blob.utf8)
            try store.saveChanges()

            let gym = try store.gymConfig()
            XCTAssertEqual(gym.restDefaults, .standard, "\(blob): unreadable rests read as the standard ones")
            XCTAssertEqual(gym.unit, .kilograms, "\(blob): the unit is intact")
            XCTAssertEqual(gym.availablePlates, rack, "\(blob): the rack is intact")
            XCTAssertEqual(gym.barWeight, bar, "\(blob): the bar is intact")
        }
    }

    /// Two devices that each chose rests while offline collapse to the row
    /// written last, whole, like every other field on the gym.
    func testTwoDevicesDescribingRestsCollapseToTheLaterOne() throws {
        let old = StoredGymConfig(GymConfig(restDefaults: RestDefaults(compound: 120, accessory: 90)),
                                  updatedAt: midday())
        let new = StoredGymConfig(GymConfig(restDefaults: mine), updatedAt: midday(1))
        store.modelContext.insert(old)
        store.modelContext.insert(new)
        try store.saveChanges()

        XCTAssertEqual(try store.deduplicate().gymConfigs, 1)
        XCTAssertEqual(try store.gymConfig().restDefaults, mine)
    }

    // MARK: - Backup

    /// A restore onto a phone with no gym row writes the file's gym as it is.
    func testBackupCarriesRestDefaultsIntoAStoreWithNoGym() throws {
        try store.saveGymConfig(GymConfig(restDefaults: mine), at: midday())
        let backup = try store.archive(exportedAt: midday())
        XCTAssertEqual(backup.gymConfig?.restDefaults, mine)

        let fresh = try TrainingStore.inMemory()
        let report = try fresh.restore(from: backup)

        XCTAssertTrue(report.restoredGym)
        XCTAssertEqual(try fresh.gymConfig().restDefaults, mine)
    }

    /// The merge path, and the one a fresh install actually takes: picking a
    /// split writes a gym row holding the standard rests before restore is
    /// reachable. Those rests are nobody's choice, so the file's win.
    func testRestoreOntoAFreshInstallTakesTheFilesRestDefaults() throws {
        try store.saveGymConfig(GymConfig(restDefaults: mine), at: midday())
        let backup = try store.archive(exportedAt: midday())

        let fresh = try TrainingStore.inMemory()
        let picked = DayTemplateLibrary.split(.fullBody, startedAt: midday(2))
        try fresh.saveGymConfig(GymConfig(trainingSplit: picked), at: midday(2))

        let report = try fresh.restore(from: backup)

        let gym = try fresh.gymConfig()
        XCTAssertEqual(gym.restDefaults, mine)
        XCTAssertEqual(gym.trainingSplit, picked, "the split picked here is kept")
        XCTAssertTrue(report.restoredGym)
    }

    /// Rests chosen on this phone are a choice. A file does not overwrite them.
    func testRestoreKeepsRestDefaultsChosenOnThisPhone() throws {
        try store.saveGymConfig(GymConfig(restDefaults: mine), at: midday())
        let backup = try store.archive(exportedAt: midday())

        let other = try TrainingStore.inMemory()
        let chosen = RestDefaults(compound: 240, accessory: 90)
        try other.saveGymConfig(GymConfig(restDefaults: chosen), at: midday(2))

        _ = try other.restore(from: backup)

        XCTAssertEqual(try other.gymConfig().restDefaults, chosen)
    }

    /// Through the file itself, not just the in-memory value: what the lifter
    /// shares or stores has to carry the setting when read back.
    func testRestDefaultsRoundTripThroughTheBackupFile() throws {
        try store.saveGymConfig(GymConfig(restDefaults: mine), at: midday())
        let file = try store.archive(exportedAt: midday()).jsonData()

        let fresh = try TrainingStore.inMemory()
        _ = try fresh.restore(from: TrainingArchive(json: file))

        XCTAssertEqual(try fresh.gymConfig().restDefaults, mine)
    }

    /// A file exported before #341 has a `gymConfig` with no `restDefaults`
    /// key. This is the literal old shape, read through the real archive path
    /// (#174's lesson: prove an old file against the old file, not against the
    /// initialiser's defaults).
    func testAnArchiveFromBeforeRestDefaultsRestoresTheStandardRests() throws {
        let json = """
        {
          "version": 2,
          "exportedAt": "2026-03-10T12:00:00Z",
          "exercises": [],
          "sets": [],
          "progressStates": [],
          "dayTemplates": [],
          "bodyweights": [],
          "gymConfig": {"unit":"kilograms","availablePlates":[25,20,15,10,5,2.5,1.25],
                        "barWeight":{"pounds":44.0925},"weeklySessionTarget":4}
        }
        """
        let archive = try TrainingArchive(json: Data(json.utf8))
        XCTAssertEqual(archive.gymConfig?.restDefaults, .standard,
                       "no stored key reads as the standard rests, not as zero seconds")

        let fresh = try TrainingStore.inMemory()
        let report = try fresh.restore(from: archive)

        XCTAssertTrue(report.restoredGym)
        let gym = try fresh.gymConfig()
        XCTAssertEqual(gym.restDefaults, .standard)
        XCTAssertEqual(gym.unit, .kilograms, "the rest of the old file's gym still comes back")
    }

    /// And an old file does not reset rests this phone already chose.
    func testAnArchiveFromBeforeRestDefaultsLeavesChosenRestsAlone() throws {
        var backup = try store.archive(exportedAt: midday())
        backup.gymConfig = GymConfig(weeklySessionTarget: 5)   // standard rests, as an old file decodes

        let other = try TrainingStore.inMemory()
        try other.saveGymConfig(GymConfig(restDefaults: mine), at: midday(2))
        _ = try other.restore(from: backup)

        XCTAssertEqual(try other.gymConfig().restDefaults, mine)
        XCTAssertEqual(try other.gymConfig().weeklySessionTarget, 5)
    }

    // MARK: - A new plan takes its rest from the setting

    private let day: TimeInterval = 86_400

    /// Two accessories, because a program-wide fatigue read needs two lifts.
    private func accessories() throws -> [Exercise] {
        let lifts = [Muscle.sideDelts, .biceps].map { muscle in
            Exercise(
                name: "Test \(muscle.displayName)", muscles: [.primary(muscle)],
                equipment: .dumbbell,
                progressionRule: .doubleProgression(range: RepRange(8, 12))
            )
        }
        XCTAssertTrue(lifts.allSatisfy { !$0.isCompound }, "these follow the accessory default")
        for lift in lifts { try store.upsert(lift) }
        return lifts
    }

    private func setAccessoryRest(_ seconds: TimeInterval) throws {
        var gym = try store.gymConfig()
        gym.restDefaults.accessory = seconds
        try store.saveGymConfig(gym)
    }

    /// The way a workout runs it: accept (or activate) the plan, log every set
    /// at `rpe`, finish. Returns the plan the session ran under.
    @discardableResult
    private func runSession(
        _ lift: Exercise, on dayIndex: Int, plan accepted: ExercisePlan? = nil, rpe: RPE
    ) throws -> ExercisePlan {
        let start = midday(dayIndex)
        let workout = UUID()
        let plan: ExercisePlan
        if let accepted {
            plan = try store.acceptExercisePlan(accepted, workoutID: workout, startedAt: start, now: start)
        } else {
            let recommendation = try store.recommendation(for: lift, excluding: workout, now: start)
            XCTAssertFalse(recommendation.sets.isEmpty)
            plan = try XCTUnwrap(try store.activateExerciseRecommendation(
                recommendation, workoutID: workout, startedAt: start, now: start))
        }
        for (index, target) in plan.sets.enumerated() {
            try store.logWorkoutSet(
                SetRecord(exerciseID: lift.id, load: target.load, reps: target.reps, rpe: rpe,
                          performedAt: start.addingTimeInterval(Double(index) * 90)),
                workoutID: workout, startedAt: start, effortReported: true)
        }
        try store.finishExerciseSessions(workoutID: workout, at: start.addingTimeInterval(1_800))
        return plan
    }

    private func firstPlan(_ lift: Exercise, rest: Int) -> ExercisePlan {
        ExercisePlan(
            exercise: lift,
            sets: Array(repeating: PlannedWorkingSet(load: 20, reps: 10, rpe: .eight), count: 3),
            restSeconds: rest)
    }

    /// The reason this fix exists. Plans used to inherit the previous plan's
    /// rest, so after accessories went 90 to 60 every accessory plan kept
    /// saying 90 while the lifter rested 60.
    func testANewPlanTakesTheChangedDefaultInsteadOfTheLastPlansRest() throws {
        let lift = try accessories()[0]
        try setAccessoryRest(90)
        let before = try runSession(lift, on: 0, plan: firstPlan(lift, rest: 90), rpe: .seven)
        XCTAssertEqual(before.restSeconds, 90)

        try setAccessoryRest(60)
        let after = try runSession(lift, on: 3, rpe: .seven)

        XCTAssertEqual(after.restSeconds, 60)
        XCTAssertNotEqual(after.id, before.id,
                          "a different rest is a different demand, so it is a new plan")
    }

    func testAnUnchangedDefaultKeepsTheRestAndThePlanComparable() throws {
        let lift = try accessories()[0]
        try setAccessoryRest(90)
        let before = try runSession(lift, on: 0, plan: firstPlan(lift, rest: 90), rpe: .seven)

        let recommendation = try store.recommendation(for: lift, excluding: nil, now: midday(3))
        XCTAssertEqual(recommendation.sets, before.sets,
                       "the fixture has to repeat the targets, or the plan id says nothing about rest")
        let after = try runSession(lift, on: 3, rpe: .seven)

        XCTAssertEqual(after.restSeconds, 90)
        XCTAssertEqual(after.id, before.id,
                       "an ordinary week repeats the plan, rest included, and stays comparable")
    }

    /// A lift's own rest time wins over both defaults, so changing a default
    /// leaves its plan alone.
    func testALiftWithItsOwnRestKeepsItAcrossADefaultChange() throws {
        var lift = try accessories()[0]
        lift.restOverride = 120
        try store.upsert(lift)
        try setAccessoryRest(90)
        let before = try runSession(lift, on: 0, plan: firstPlan(lift, rest: 120), rpe: .seven)

        try setAccessoryRest(60)
        let after = try runSession(lift, on: 3, rpe: .seven)

        XCTAssertEqual(after.restSeconds, 120)
        XCTAssertEqual(after.id, before.id)
    }

    /// Compounds read their own default, not the accessory one.
    func testACompoundPlanTakesTheCompoundDefault() throws {
        let press = Exercise(
            name: "Test Press", muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        try store.upsert(press)
        XCTAssertTrue(press.isCompound)

        let start = midday()
        let first = try store.acceptExercisePlan(
            ExercisePlan(exercise: press,
                         sets: Array(repeating: PlannedWorkingSet(load: 100, reps: 10, rpe: .eight), count: 3),
                         restSeconds: 180),
            workoutID: UUID(), startedAt: start, now: start)
        XCTAssertEqual(first.restSeconds, 180)

        var gym = try store.gymConfig()
        gym.restDefaults = mine
        try store.saveGymConfig(gym)
        let recommendation = try store.recommendation(for: press, now: midday(3))
        let next = try XCTUnwrap(try store.activateExerciseRecommendation(
            recommendation, workoutID: UUID(), startedAt: midday(3), now: midday(3)))

        XCTAssertEqual(next.restSeconds, 150)
    }

    // MARK: - The seam must not read as fatigue

    /// The Core replay (`TrainingBlockEvals`) feeds the detector plans built by
    /// hand. This runs the same scenario through the store's own activation, the
    /// place a stale rest would have come from: two accessories, hot effort at
    /// every session, accessories going from 90 to 60 between the second and
    /// third.
    ///
    /// Before the fix the third plan inherited 90, was comparable with the
    /// second, and two lifts' hotter effort at what was really a shorter rest
    /// read as program fatigue.
    func testChangingTheAccessoryDefaultMidBlockNeverReadsAsFatigueAtTheSeam() throws {
        let lifts = try accessories()
        func fatigued(on dayIndex: Int) throws -> Bool {
            TrainingBlockEngine.adaptiveDeloadNeeded(
                history: try store.allExerciseExposures(), now: midday(dayIndex))
        }

        try setAccessoryRest(90)
        for lift in lifts { try runSession(lift, on: 0, plan: firstPlan(lift, rest: 90), rpe: .nine) }
        for lift in lifts { try runSession(lift, on: 3, rpe: .nine) }
        XCTAssertTrue(try fatigued(on: 4),
                      "control: this history is fatigue at a steady rest, or the seam below proves nothing")

        try setAccessoryRest(60)
        let seam = try lifts.map { try runSession($0, on: 6, rpe: .nine) }
        XCTAssertEqual(seam.map(\.restSeconds), [60, 60])
        XCTAssertFalse(try fatigued(on: 7),
                       "the first session at a new default rest read as fatigue")

        for lift in lifts { try runSession(lift, on: 9, rpe: .nine) }
        XCTAssertTrue(try fatigued(on: 10),
                      "the guard has to expire once two sessions have run at the new rest")
    }
}
