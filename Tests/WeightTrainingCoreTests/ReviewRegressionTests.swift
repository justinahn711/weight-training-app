import XCTest
@testable import WeightTrainingCore

/// Regressions for defects found reviewing the M2 engine. Each one is a bug
/// that shipped through a green suite, so each gets a test that would have
/// caught it.
final class ReviewRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func library(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    // MARK: - A deload must never propose nothing

    /// Backing 10 lb off by 10% snapped to zero, and the app said "back off to
    /// 0 lb and rebuild". The floor has to be one increment, not zero.
    func testDeloadNeverProposesZero() {
        for exercise in ExerciseLibrary.all {
            for pounds in stride(from: exercise.increment.pounds, through: 60.0,
                                 by: exercise.increment.pounds) {
                let state = ProgressState(exerciseID: exercise.id,
                                          targetLoad: Load(pounds), stallCount: 2)
                guard let suggestion = DeloadDetector.evaluate(
                    exercise: exercise, state: state, history: []
                ) else { continue }

                XCTAssertGreaterThan(
                    suggestion.to.pounds, 0,
                    "\(exercise.name) at \(pounds) proposed \(suggestion.to)"
                )
                XCTAssertLessThan(suggestion.to, suggestion.from, exercise.name)
            }
        }
    }

    /// At the lightest usable load there is nothing to back off to, so the
    /// honest answer is silence.
    func testNoDeloadAtTheLightestUsableLoad() {
        let raise = library("Lateral Raise")
        let state = ProgressState(exerciseID: raise.id,
                                  targetLoad: raise.lightestUsableLoad, stallCount: 3)
        XCTAssertNil(DeloadDetector.evaluate(exercise: raise, state: state, history: []))
    }

    // MARK: - Machines are not barbells

    /// A chest-supported T-bar loads one sleeve and a hack squat pushes a sled.
    /// Neither has a 45 lb Olympic bar, so neither may render plate math or
    /// claim the empty bar as its floor.
    func testPlateLoadedMachinesDoNotPretendToHaveABar() {
        for name in ["Chest-Supported T-Bar Row", "Hack Squat"] {
            let machine = library(name)
            XCTAssertTrue(machine.equipment.isPlateBuilt, "\(name) is still plate-built")
            XCTAssertFalse(machine.equipment.usesOlympicBar, name)
            XCTAssertNil(machine.plateBreakdown(for: Load(90)),
                         "\(name) rendered a barbell breakdown")
            XCTAssertEqual(machine.equipment.minimumLoad, Load.zero, name)
        }

        let bench = library("Flat Bench")
        XCTAssertTrue(bench.equipment.usesOlympicBar)
        XCTAssertEqual(bench.plateBreakdown(for: Load(135))?.displayLine, "45")
    }

    /// The ramp inherited the same fiction: a hack squat opened with a
    /// fabricated 45 lb "empty bar" rung.
    func testMachineRampsDoNotStartWithAFabricatedBar() {
        let hack = library("Hack Squat")
        let ramp = WarmupRamp.generate(for: hack, workingLoad: Load(180))
        XCTAssertFalse(ramp.isEmpty)
        XCTAssertNotEqual(ramp.first?.load, Load(45),
                          "a sled has no empty bar to start from")
        XCTAssertEqual(ramp.map(\.load), [Load(70), Load(105), Load(140)])

        let bench = library("Flat Bench")
        XCTAssertEqual(WarmupRamp.generate(for: bench, workingLoad: Load(225)).first?.load,
                       Load(45), "a real barbell still starts with the bar")
    }

    // MARK: - Every proposal, not just the computed ones

    /// Double progression echoed the logged weight straight through, so a load
    /// left over from a stale increment (#20) became a target the equipment
    /// couldn't make — and the plate line under the stepper silently vanished.
    func testDoubleProgressionProposalsAreAlwaysBuildable() {
        let skull = library("Skull Crushers")
        let result = ProgressionEngine.advance(
            exercise: skull,
            state: ProgressState(exerciseID: skull.id, targetLoad: Load(30),
                                 consecutiveTopHits: 1),
            performed: [SetRecord(exerciseID: skull.id, load: Load(30), reps: 12,
                                  rpe: RPE(8), performedAt: now)]
        )
        let target = result.state.targetLoad!
        XCTAssertGreaterThanOrEqual(target, skull.equipment.minimumLoad,
                                    "proposed \(target) on a 45 lb bar")
        XCTAssertTrue(PlateMath.isAchievable(target, equipment: skull.equipment,
                                             increment: skull.increment))
    }

    /// Off-grid logged weights must not propagate into the next target.
    func testOffGridLoggedWeightIsSnappedBeforeBecomingATarget() {
        let bench = library("Flat Bench")
        let result = ProgressionEngine.advance(
            exercise: bench,
            state: ProgressState(exerciseID: bench.id, targetLoad: Load(187)),
            performed: [SetRecord(exerciseID: bench.id, load: Load(187), reps: 5,
                                  rpe: RPE(8), performedAt: now)]
        )
        let target = result.state.targetLoad!
        XCTAssertTrue(PlateMath.isAchievable(target, equipment: bench.equipment,
                                             increment: bench.increment),
                      "proposed \(target)")
    }

    // MARK: - Increments

    /// A zero increment turned snapping into a no-op and made every load look
    /// achievable, quietly disabling the guard that stops unbuildable weights.
    func testNonPositiveIncrementIsRejected() {
        XCTAssertFalse(
            PlateMath.isAchievable(Load(37.3), equipment: .machineStack,
                                   increment: LoadIncrement(pounds: 5)),
            "37.3 is not a multiple of 5"
        )
        XCTAssertTrue(
            PlateMath.isAchievable(Load(150), equipment: .machineStack,
                                   increment: LoadIncrement(pounds: 15))
        )
    }

    // MARK: - Ramp identity

    /// Rungs were identified by a fresh UUID generated on every read, so
    /// SwiftUI saw brand-new rows on each render and two reads in one pass
    /// didn't even agree with each other.
    func testRampIsStableAcrossRegeneration() {
        let bench = library("Flat Bench")
        let first = WarmupRamp.generate(for: bench, workingLoad: Load(225))
        let second = WarmupRamp.generate(for: bench, workingLoad: Load(225))

        XCTAssertEqual(first, second, "two identical ramps must compare equal")
        XCTAssertEqual(first.map(\.id), second.map(\.id), "identities must be stable")
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "ids unique within a ramp")
    }
}
