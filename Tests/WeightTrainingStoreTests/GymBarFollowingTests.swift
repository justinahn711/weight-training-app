import XCTest
import SwiftData
import WeightTrainingCore
@testable import WeightTrainingStore

/// A device that only ever learns the gym through sync keeps its lifts on the
/// gym's bar (#270).
///
/// `reconcileGym()` runs on launch and after every CloudKit import with no
/// idea what the gym used to be, so "is this base still just the bar?" can't
/// be answered from history on that device. It is answered by a mark on the
/// lift's loading instead, which syncs with the row.
@MainActor
final class GymBarFollowingTests: XCTestCase {
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

    private func midday(_ dayOffset: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 10 + dayOffset; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private var benchID: UUID {
        get throws { try XCTUnwrap(try store.exercises().first { $0.name == "Flat Bench" }).id }
    }

    /// Stands in for a CloudKit import: the gym row changes, this device's
    /// exercise rows don't, then the app reconciles as it does on import.
    private func importGym(_ gym: GymConfig, at date: Date) throws {
        if let row = try store.storedGymConfig() {
            row.update(from: gym, at: date)
        } else {
            store.modelContext.insert(StoredGymConfig(gym, updatedAt: date))
        }
        try store.saveChanges()
        try store.reconcileGym()
    }

    /// Stands in for an install written before #270: the loading JSON carries
    /// no mark, exactly as an older build (or a device still on one) writes it.
    private func stripMark(from id: UUID) throws {
        let row = try XCTUnwrap(try store.storedExercise(id: id))
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: row.loadingData) as? [String: Any]
        )
        object.removeValue(forKey: "followsGymBar")
        row.loadingData = try JSONSerialization.data(withJSONObject: object)
        try store.saveChanges()
        XCTAssertNil(try store.exercise(id: id)?.loading?.followsGymBar)
    }

    // MARK: - The two cases in the issue

    /// Case A: the Settings stepper on phone A goes 45 → 40 → 35, and phone B
    /// imports each step. 40 is neither a standard bar nor a gym B remembers.
    func testSecondDeviceFollowsTheGymThroughTwoSyncedBarChanges() throws {
        try store.reconcileGym()
        let id = try benchID
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight, Load(45))

        try importGym(GymConfig(unit: .pounds, barWeight: Load(40)), at: midday(0))
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight, Load(40))

        try importGym(GymConfig(unit: .pounds, barWeight: Load(35)), at: midday(1))
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight, Load(35),
                       "stranded on the intermediate bar")
        XCTAssertEqual(try store.reconcileGym(), 0, "and a relaunch finds nothing to fix")
    }

    /// Case B: a 35 lb-bar gym switches to kilograms on the other phone.
    func testSecondDeviceFollowsAUnitSwitchFromANonStandardBar() throws {
        try store.saveGymConfig(GymConfig(unit: .pounds, barWeight: Load(35)))
        let id = try benchID
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight, Load(35))

        try importGym(GymConfig(unit: .kilograms), at: midday(1))
        let loading = try XCTUnwrap(try store.exercise(id: id)?.loading)
        XCTAssertEqual(loading.unit, .kilograms)
        XCTAssertEqual(loading.baseWeight, MassUnit.kilograms.standardBar, "got \(loading)")
    }

    /// A lift the lifter weighed keeps its base through synced bar and unit
    /// changes — the non-goal the mark must not break.
    func testAMeasuredBaseSurvivesSyncedChanges() throws {
        var lift = try XCTUnwrap(try store.exercise(id: try benchID))
        lift.loading?.baseWeight = Load(33)
        try store.upsert(lift)
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.followsGymBar, false)

        try importGym(GymConfig(unit: .pounds, barWeight: Load(40)), at: midday(0))
        try importGym(GymConfig(unit: .kilograms), at: midday(1))
        let after = try XCTUnwrap(try store.exercise(id: lift.id)?.loading)
        XCTAssertEqual(after.baseWeight, Load(33))
        XCTAssertEqual(after.unit, .kilograms, "the rack still follows the gym")
    }

    // MARK: - Lifter writes

    /// Saving the lift sheet without touching the empty weight must not turn
    /// a following bar into a measured one. The sheet builds a fresh
    /// `LoadingStyle` on every Save, with no mark.
    func testSavingTheSheetWithTheSameBaseKeepsItFollowing() throws {
        try store.saveGymConfig(GymConfig(unit: .pounds, barWeight: Load(40)))
        var lift = try XCTUnwrap(try store.exercise(id: try benchID))
        let old = try XCTUnwrap(lift.loading)
        lift.loading = LoadingStyle(
            baseWeight: old.baseWeight, sleeves: old.sleeves,
            availablePlates: old.availablePlates, unit: old.unit, usesGymRack: true
        )
        try store.upsert(lift)
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.followsGymBar, true)

        try importGym(GymConfig(unit: .pounds, barWeight: Load(35)), at: midday(1))
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.baseWeight, Load(35))
    }

    /// Typing the gym's own bar is how a lifter hands a lift back to the gym —
    /// and is the way out for a lift stranded before this landed.
    func testTypingTheGymsBarMakesALiftFollowAgain() throws {
        try store.saveGymConfig(GymConfig(unit: .pounds, barWeight: Load(35)))
        var lift = try XCTUnwrap(try store.exercise(id: try benchID))
        lift.loading?.baseWeight = Load(40)
        lift.loading?.followsGymBar = nil
        try store.upsert(lift)
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.followsGymBar, false)

        lift.loading?.baseWeight = Load(35)
        lift.loading?.followsGymBar = nil
        try store.upsert(lift)
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.followsGymBar, true)

        try importGym(GymConfig(unit: .kilograms), at: midday(1))
        XCTAssertEqual(try store.exercise(id: lift.id)?.loading?.baseWeight,
                       MassUnit.kilograms.standardBar)
    }

    /// Re-racking is derived, not the lifter's write: the mark it records on
    /// migration must not stamp the row, or a stale stock copy would beat a
    /// real edit in `deduplicate()` (#268).
    func testRecordingTheMarkDoesNotStampTheRow() throws {
        let id = try benchID
        try stripMark(from: id)
        let before = try XCTUnwrap(try store.storedExercise(id: id)).updatedAt

        XCTAssertGreaterThan(try store.reconcileGym(), 0)
        XCTAssertEqual(try store.exercise(id: id)?.loading?.followsGymBar, true)
        XCTAssertEqual(try XCTUnwrap(try store.storedExercise(id: id)).updatedAt, before)
    }

    // MARK: - Installs written before #270

    /// A pre-#270 install on the gym's current bar is marked following on
    /// first launch, and then follows the next synced change of any kind.
    func testAnUnmarkedLiftOnTheGymsBarIsMarkedAndThenFollows() throws {
        try store.saveGymConfig(GymConfig(unit: .pounds, barWeight: Load(40)))
        let id = try benchID
        try stripMark(from: id)

        try store.reconcileGym()
        XCTAssertEqual(try store.exercise(id: id)?.loading?.followsGymBar, true)

        try importGym(GymConfig(unit: .pounds, barWeight: Load(35)), at: midday(1))
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight, Load(35))
    }

    /// A pre-#270 lift left on the standard pound bar inside a kilogram rack
    /// is recognised as a bar and healed.
    func testAPoundBarStrandedInAKilogramGymIsHealed() throws {
        store.modelContext.insert(StoredGymConfig(.standard(in: .kilograms), updatedAt: midday(0)))
        try store.saveChanges()
        let id = try benchID
        var lift = try XCTUnwrap(try store.exercise(id: id))
        lift.loading = LoadingStyle(baseWeight: Load(45), sleeves: 2, unit: .kilograms)
        try store.upsert(lift, stampedAt: midday(0))
        try stripMark(from: id)

        try store.reconcileGym()
        XCTAssertEqual(try store.exercise(id: id)?.loading?.baseWeight,
                       MassUnit.kilograms.standardBar)
    }

    /// The edge the migration cannot recover, pinned so it is a decision and
    /// not an accident: a pre-#270 lift already stranded on a bar that is
    /// neither the gym's current bar nor a standard bar looks exactly like
    /// one somebody weighed. It is kept (measured is the safe direction) and
    /// healed by typing the gym's bar on the lift's sheet.
    func testALiftStrandedOnAnOldIntermediateBarIsTreatedAsMeasured() throws {
        store.modelContext.insert(
            StoredGymConfig(GymConfig(unit: .pounds, barWeight: Load(35)), updatedAt: midday(0))
        )
        try store.saveChanges()
        let id = try benchID
        var lift = try XCTUnwrap(try store.exercise(id: id))
        lift.loading?.baseWeight = Load(40)
        try store.upsert(lift, stampedAt: midday(0))
        try stripMark(from: id)

        try store.reconcileGym()
        let loading = try XCTUnwrap(try store.exercise(id: id)?.loading)
        XCTAssertEqual(loading.baseWeight, Load(40))
        XCTAssertEqual(loading.followsGymBar, false)
    }
}

private extension TrainingStore {
    func upsert(_ exercise: Exercise, stampedAt stamp: Date) throws {
        try upsert([exercise], stampedAt: stamp)
    }
}
