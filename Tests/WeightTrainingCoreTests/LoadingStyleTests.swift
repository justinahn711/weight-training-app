import XCTest
@testable import WeightTrainingCore

final class LoadingStyleTests: XCTestCase {

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    // MARK: - Sleeves

    /// A barbell loads two sleeves, so plates count twice.
    func testBarbellPlatesCountTwice() throws {
        let style = LoadingStyle.olympicBarbell
        let breakdown = try XCTUnwrap(style.breakdown(for: Load(225)))
        XCTAssertEqual(breakdown.displayLine, "45 · 45")
        XCTAssertEqual(breakdown.total, Load(225))
        XCTAssertEqual(breakdown.sleeves, 2)
    }

    /// A T-bar loads one sleeve, so the same plates make a much lighter lift.
    /// This is the arithmetic that was wrong before #39.
    func testSingleSleeveMachinePlatesCountOnce() throws {
        let style = LoadingStyle(baseWeight: Load(35), sleeves: 1)
        let breakdown = try XCTUnwrap(style.breakdown(for: Load(125)))
        XCTAssertEqual(breakdown.displayLine, "45 · 45")
        XCTAssertEqual(breakdown.total, Load(125), "35 lever + 90 of plates")
        XCTAssertEqual(breakdown.sleeves, 1)

        // The same weight on a barbell would need half as much iron per side.
        XCTAssertNotEqual(LoadingStyle.olympicBarbell.breakdown(for: Load(125))?.displayLine,
                          breakdown.displayLine)
    }

    func testEmptyApparatusReadsDifferentlyBySleeveCount() throws {
        let bar = try XCTUnwrap(LoadingStyle.olympicBarbell.breakdown(for: Load(45)))
        XCTAssertEqual(bar.displayLine, "Bar only")

        let lever = LoadingStyle(baseWeight: Load(35), sleeves: 1)
        XCTAssertEqual(try XCTUnwrap(lever.breakdown(for: Load(35))).displayLine, "Empty")
    }

    // MARK: - Unmeasured machines

    /// Unknown base weight means the app declines to show a breakdown rather
    /// than inventing one. A plate list that's wrong is worse than none,
    /// because it gets followed.
    func testUnmeasuredMachineOffersNoBreakdown() {
        let style = LoadingStyle.unmeasuredMachine(sleeves: 1)
        XCTAssertFalse(style.isMeasured)
        XCTAssertNil(style.breakdown(for: Load(125)))
        XCTAssertEqual(style.minimumLoad, .zero)
    }

    /// The two seeded machines, as configured today.
    func testSeededMachinesKnowHowTheyLoad() throws {
        let tbar = lift("Chest-Supported T-Bar Row")
        XCTAssertEqual(tbar.loading?.sleeves, 1, "one sleeve")
        XCTAssertFalse(try XCTUnwrap(tbar.loading).isMeasured)
        XCTAssertNil(tbar.plateBreakdown(for: Load(90)))

        let hack = lift("Hack Squat")
        XCTAssertEqual(hack.loading?.sleeves, 2, "sled loads both sides")
        XCTAssertFalse(try XCTUnwrap(hack.loading).isMeasured)

        let bench = lift("Flat Bench")
        XCTAssertTrue(try XCTUnwrap(bench.loading).isMeasured)
        XCTAssertEqual(bench.plateBreakdown(for: Load(135))?.displayLine, "45")
    }

    func testStacksAndDumbbellsHaveNoLoadingStyle() {
        XCTAssertNil(lift("Lat Pulldown").loading)
        XCTAssertNil(lift("Incline DB Press").loading)
        XCTAssertNil(lift("Face Pull").loading)
    }

    // MARK: - Measuring a machine

    /// The point of the config: measuring the sled turns on plate math, a
    /// floor, and a warmup ramp that starts from the real empty weight —
    /// without anyone editing code.
    func testMeasuringAMachineTurnsOnPlateMath() throws {
        var hack = lift("Hack Squat")
        XCTAssertNil(hack.plateBreakdown(for: Load(180)))
        XCTAssertEqual(hack.minimumLoad, .zero)

        hack.loading = LoadingStyle(baseWeight: Load(100), sleeves: 2)

        let breakdown = try XCTUnwrap(hack.plateBreakdown(for: Load(280)))
        XCTAssertEqual(breakdown.displayLine, "45 · 45", "90 a side on a 100 lb sled")
        XCTAssertEqual(breakdown.total, Load(280))
        XCTAssertEqual(hack.minimumLoad, Load(100))
        XCTAssertFalse(hack.canBuild(Load(50)), "lighter than the empty sled")
    }

    func testAMeasuredMachineRampsFromItsRealEmptyWeight() {
        var tbar = lift("Chest-Supported T-Bar Row")
        XCTAssertFalse(WarmupRamp.generate(for: tbar, workingLoad: Load(180)).contains {
            $0.load == Load(45)
        }, "no fabricated 45 lb bar while unmeasured")

        tbar.loading = LoadingStyle(baseWeight: Load(35), sleeves: 1)
        let ramp = WarmupRamp.generate(for: tbar, workingLoad: Load(180))
        XCTAssertEqual(ramp.first?.load, Load(35), "starts with the empty lever")
        for rung in ramp {
            XCTAssertNotNil(tbar.plateBreakdown(for: rung.load), "\(rung.load) unloadable")
        }
    }

    /// Correcting the plate set is part of the same configuration.
    func testAGymWithoutSmallPlatesCannotMakeSmallJumps() {
        let coarse = LoadingStyle(baseWeight: Load(45), sleeves: 2,
                                  availablePlates: [45, 25, 10])
        XCTAssertTrue(coarse.canBuild(Load(65)), "45 + 10 a side")
        XCTAssertFalse(coarse.canBuild(Load(50)), "no 2.5s in this gym")
    }

    // MARK: - Achievability

    func testCanBuildFollowsTheApparatus() {
        let bench = lift("Flat Bench")
        XCTAssertTrue(bench.canBuild(Load(185)))
        XCTAssertFalse(bench.canBuild(Load(187.5)))
        XCTAssertFalse(bench.canBuild(Load(30)), "lighter than the bar")

        let press = lift("Incline DB Press")
        XCTAssertTrue(press.canBuild(Load(75)))
        XCTAssertFalse(press.canBuild(Load(72.5)), "no such dumbbell")
    }

    /// An unmeasured machine trusts the increment, since there's nothing else
    /// to go on — logging must keep working before anyone owns a scale.
    func testUnmeasuredMachineStillAcceptsLoads() {
        let tbar = lift("Chest-Supported T-Bar Row")
        XCTAssertTrue(tbar.canBuild(Load(90)))
        XCTAssertTrue(tbar.canBuild(Load(135)))
    }
}
