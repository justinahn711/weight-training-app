import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Correcting what the app assumes about a machine (#20, #39).
///
/// Both issues are really one claim: the app must never propose a weight the
/// equipment in front of you cannot be set to. A stack defaulted to 10 lb when
/// it moves in 15s, and a plate-built lift whose proposal was snapped to an
/// increment the plates can't honour, break that claim in the same way.
@MainActor
final class ExerciseConfigurationTests: XCTestCase {
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

    /// #20's done-when: a corrected increment reflows the lift's target.
    ///
    /// The target is derived, not stored as a display string, so correcting the
    /// increment has to change what the next session proposes without waiting
    /// for a relaunch. Rebuilding the session exercise from the store is what
    /// the config sheet does, and this is that path.
    func testCorrectingAnIncrementReflowsTheTarget() throws {
        var pulldown = try XCTUnwrap(
            try store.exercises().first { $0.name == "Lat Pulldown" }
        )

        // A stack that actually moves in 15s, defaulted to 10 (#20). The
        // target is stored state, which is what outlives the correction.
        try store.save(ProgressState(exerciseID: pulldown.id, targetLoad: Load(100),
                                     targetReps: 10, targetRPE: RPE(8),
                                     lastPerformedAt: .now.addingTimeInterval(-86_400)))

        pulldown.increment = LoadIncrement(pounds: 15)
        try store.upsert(pulldown)

        let rebuilt = try store.sessionExercise(for: pulldown, slot: nil, startedAt: .now)
        let target = try XCTUnwrap(rebuilt.prescription.load)

        XCTAssertEqual(
            target, pulldown.nearestAchievable(target),
            "target \(target.pounds) is not a weight a 15 lb stack can be set to"
        )
    }

    /// #39's done-when: nothing proposes a weight the plates can't build.
    ///
    /// The two used to disagree — the increment offered 187.5 and the plate
    /// breakdown refused it — which is exactly what a lifter standing at the
    /// rack cannot act on.
    func testMeasuredMachineNeverProposesAnUnbuildableWeight() throws {
        var tbar = try XCTUnwrap(
            try store.exercises().first { $0.loading != nil && $0.name.contains("T-Bar") }
                ?? store.exercises().first { $0.loading != nil }
        )
        tbar.loading = LoadingStyle(baseWeight: Load(35), sleeves: 1,
                                    availablePlates: [45, 25, 10])
        tbar.increment = LoadIncrement(pounds: 2.5)
        try store.upsert(tbar)

        try store.save(ProgressState(exerciseID: tbar.id, targetLoad: Load(105),
                                     targetReps: 8, targetRPE: RPE(8),
                                     lastPerformedAt: .now.addingTimeInterval(-86_400)))

        let rebuilt = try store.sessionExercise(for: tbar, slot: nil, startedAt: .now)
        let target = try XCTUnwrap(rebuilt.prescription.load)

        XCTAssertNotNil(
            tbar.plateBreakdown(for: target),
            "proposed \(target.pounds) lb, which these plates cannot build"
        )
    }
}
