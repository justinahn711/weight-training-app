import XCTest
import SwiftData
import WeightTrainingCore
@testable import WeightTrainingStore

/// Describing the gym once, and having it stick (#73, #67).
@MainActor
final class GymConfigurationTests: XCTestCase {
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

    /// An install that predates the setting is a pound gym, not a broken one.
    func testAnUnconfiguredStoreIsThePoundGym() throws {
        XCTAssertEqual(try store.gymConfig(), .standard)
    }

    func testTheGymSurvivesBeingWritten() throws {
        try store.saveGymConfig(GymConfig(unit: .kilograms, weeklySessionTarget: 4))
        let read = try store.gymConfig()

        XCTAssertEqual(read.unit, .kilograms)
        XCTAssertEqual(read.availablePlates, [25, 20, 15, 10, 5, 2.5, 1.25])
        XCTAssertEqual(read.barWeight.value(in: .kilograms), 20, accuracy: 0.0001)
        XCTAssertEqual(read.weeklySessionTarget, 4)
    }

    /// #73's done-when, from the other end: switching the rack reaches the
    /// lifts rather than leaving twenty of them to be revisited by hand.
    func testSwitchingTheGymRerackesEveryLiftThatFollowsIt() throws {
        let changed = try store.saveGymConfig(.standard(in: .kilograms))
        XCTAssertGreaterThan(changed, 0, "the seeded library should have followed")

        let squat = try XCTUnwrap(try store.exercises().first { $0.name == "Flat Bench" })
        let loading = try XCTUnwrap(squat.loading)

        XCTAssertEqual(loading.unit, .kilograms)
        XCTAssertEqual(loading.availablePlates, [25, 20, 15, 10, 5, 2.5, 1.25])
        XCTAssertEqual(loading.baseWeight?.value(in: .kilograms) ?? 0, 20, accuracy: 0.0001)
        XCTAssertEqual(squat.increment.formatted, "2.5 kg")
    }

    /// The plate line a kg lifter reads has to name plates that exist on the
    /// rack in front of them — this is the failure #67 was opened about.
    func testThePlateLineAfterSwitchingNamesRealPlates() throws {
        try store.saveGymConfig(.standard(in: .kilograms))
        let squat = try XCTUnwrap(try store.exercises().first { $0.name == "Flat Bench" })
        let breakdown = try XCTUnwrap(squat.loading?.breakdown(for: Load(100, .kilograms)))

        XCTAssertEqual(breakdown.perSide.map(\.plate), [25, 15])
    }

    func testAConfiguredLiftKeepsItsOwnRack() throws {
        var machine = try XCTUnwrap(try store.exercises().first { $0.loading != nil })
        machine.loading = LoadingStyle(
            baseWeight: Load(60), sleeves: 1,
            availablePlates: [25, 10], usesGymRack: false
        )
        machine.increment = LoadIncrement(pounds: 15)
        try store.upsert(machine)

        try store.saveGymConfig(.standard(in: .kilograms))

        let after = try XCTUnwrap(try store.exercise(id: machine.id))
        XCTAssertEqual(after.loading, machine.loading)
        XCTAssertEqual(after.increment, machine.increment)
    }

    /// Without this the pin position comes back as 5.51 lb and the app starts
    /// proposing weights the stack cannot be set to.
    func testAnIncrementRemembersWhatUnitItWasMarkedIn() throws {
        var lift = try XCTUnwrap(try store.exercises().first)
        lift.increment = LoadIncrement(2.5, .kilograms)
        try store.upsert(lift)

        let after = try XCTUnwrap(try store.exercise(id: lift.id))
        XCTAssertEqual(after.increment.unit, .kilograms)
        XCTAssertEqual(after.increment.nativeValue, 2.5, accuracy: 0.0001)
        XCTAssertEqual(after.increment.formatted, "2.5 kg")
    }

    /// Safe to run on every launch, which is what a second device needs: the
    /// gym record syncs, the propagation has to be re-derived locally.
    func testReconcilingAnAlreadyAgreeingStoreWritesNothing() throws {
        try store.saveGymConfig(.standard(in: .kilograms))
        XCTAssertEqual(try store.reconcileGym(), 0)
    }

    func testReconcileBringsALiftInLineWithAGymItNeverSaw() throws {
        // Stand in for the record arriving from CloudKit: the gym row is
        // written, but this device's exercises still describe the old rack.
        store.modelContext.insert(StoredGymConfig(.standard(in: .kilograms)))
        try store.saveChanges()

        XCTAssertGreaterThan(try store.reconcileGym(), 0)
        let squat = try XCTUnwrap(try store.exercises().first { $0.name == "Flat Bench" })
        XCTAssertEqual(squat.loading?.unit, .kilograms)
    }

    /// Two devices at the same gym, both offline, both with an opinion.
    func testTwoDevicesDescribingTheRackCollapseToTheLaterOne() throws {
        let old = StoredGymConfig(.standard(in: .pounds),
                                  updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = StoredGymConfig(.standard(in: .kilograms),
                                  updatedAt: Date(timeIntervalSince1970: 2_000))
        store.modelContext.insert(old)
        store.modelContext.insert(new)
        try store.saveChanges()

        let report = try store.deduplicate()
        XCTAssertEqual(report.gymConfigs, 1)
        XCTAssertEqual(try store.gymConfig().unit, .kilograms)
    }

    // MARK: - Lifts that stopped following the gym (#123)

    /// A lift silently stops tracking the gym the moment its plates differ.
    ///
    /// `usesGymRack` is recomputed on save as "does this equal the gym's set",
    /// so describing one apparatus specifically detaches it — correctly, per
    /// #73 — but nothing on screen said it had happened, nor how many lifts it
    /// had happened to. Someone asked whether plates were a gym setting at all,
    /// which is what a silent exception looks like from the outside.
    func testCountsOnlyTheLiftsThatStoppedFollowing() throws {
        let store = try TrainingStore.inMemory()
        var follower = ExerciseLibrary.all.first { $0.equipment == .barbell }!
        var exception = ExerciseLibrary.all.first { $0.name == "Hack Squat" }!

        follower.loading = LoadingStyle(
            baseWeight: Load(45), sleeves: 2,
            availablePlates: MassUnit.pounds.standardPlates,
            unit: .pounds, usesGymRack: true
        )
        exception.loading = LoadingStyle(
            baseWeight: Load(75), sleeves: 2,
            availablePlates: [25, 10],
            unit: .pounds, usesGymRack: false
        )
        try store.upsert([follower, exception])

        XCTAssertEqual(try store.liftsWithOwnRack(), 1, "only the described apparatus")
    }

    /// A store where nothing has been described reports none, rather than
    /// reporting every lift because `loading` happens to be nil.
    func testALiftWithNoRackAtAllIsNotAnException() throws {
        let store = try TrainingStore.inMemory()
        let cable = ExerciseLibrary.all.first { $0.loading == nil }!
        try store.upsert(cable)
        XCTAssertEqual(try store.liftsWithOwnRack(), 0)
    }

}

extension GymConfigurationTests {

    /// A lift created in a metric gym starts metric, rather than showing a
    /// 5 lb step until the next launch's reconcile catches up.
    func testALiftCreatedInAMetricGymStartsMetric() throws {
        try store.saveGymConfig(.standard(in: .kilograms))

        let created = Exercise(
            name: "Pendlay Row",
            muscles: [.primary(.lats)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(5, 8))
        )
        try store.create(created)

        let read = try XCTUnwrap(try store.exercise(id: created.id))
        XCTAssertEqual(read.increment.unit, .kilograms)
        XCTAssertEqual(read.increment.nativeValue, 2.5, accuracy: 0.0001)
        XCTAssertEqual(read.loading?.unit, .kilograms)
        XCTAssertEqual(read.loading?.baseWeight?.value(in: .kilograms) ?? 0, 20, accuracy: 0.0001)
    }
}
