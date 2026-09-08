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

    func testRemovingDisplayedPlateTakesOneFromEverySleeve() throws {
        let style = LoadingStyle.olympicBarbell

        XCTAssertEqual(style.removingPlate(10, from: Load(155)), Load(135))
        XCTAssertEqual(style.breakdown(for: try XCTUnwrap(style.removingPlate(10, from: Load(155))))?.displayLine,
                       "45")
    }

    func testRemovingDisplayedPlateUsesRackUnitAndSleeveCount() throws {
        let style = LoadingStyle(
            baseWeight: Load(20, .kilograms),
            sleeves: 1,
            availablePlates: [25, 20, 10, 5, 2.5, 1.25],
            unit: .kilograms
        )
        let loaded = Load(65, .kilograms)

        let remaining = try XCTUnwrap(style.removingPlate(20, from: loaded))
        XCTAssertEqual(remaining.value(in: .kilograms), 45, accuracy: 0.000_001)
        XCTAssertEqual(style.breakdown(for: remaining)?.displayLine, "25")
    }

    func testCannotRemovePlateThatIsNotDisplayed() {
        let style = LoadingStyle.olympicBarbell

        XCTAssertNil(style.removingPlate(25, from: Load(135)))
        XCTAssertNil(style.removingPlate(45, from: Load(137)))
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

    // MARK: - Custom plate sets (#39)

    /// A gym without 5s or 2.5s still builds what it can build.
    ///
    /// The greedy breakdown this replaced took the heaviest plate first and
    /// stranded the remainder: 25 against a 30 lb sleeve leaves 5, which this
    /// set cannot make, so it declared a weight unbuildable that three 10s
    /// build exactly. Greedy is only correct for plate sets that happen to be
    /// self-refining, which is exactly what a configurable set stops being.
    func testExactBreakdownWhereGreedyWouldStrandARemainder() throws {
        let style = LoadingStyle(baseWeight: Load(50), sleeves: 1, availablePlates: [25, 10])

        let breakdown = try XCTUnwrap(style.breakdown(for: Load(80)))
        XCTAssertEqual(breakdown.total, Load(80))
        XCTAssertEqual(breakdown.perSide, [PlateCount(plate: 10, count: 3)])
    }

    /// A weight no combination reaches is still refused.
    func testUnreachableWeightHasNoBreakdown() {
        let style = LoadingStyle(baseWeight: Load(50), sleeves: 1, availablePlates: [25, 10])
        XCTAssertNil(style.breakdown(for: Load(55)), "5 cannot be made from 25s and 10s")
        XCTAssertFalse(style.canBuild(Load(55)))
    }

    // MARK: - One source of truth (#39)

    /// The bug #39 names: the increment proposed a weight the plates refused.
    ///
    /// A 2.5 lb increment on a barbell offers 187.5, which needs 71.25 per
    /// sleeve and cannot be built from any standard plate. Proposal and
    /// breakdown now read the same plate set, so the answer is loadable.
    func testProposalsAreAlwaysBuildable() throws {
        var barbell = self.lift("Flat Bench")
        barbell.increment = LoadIncrement(pounds: 2.5)
        barbell.loading = .olympicBarbell

        let proposed = barbell.nearestAchievable(Load(187.5))
        XCTAssertTrue(
            barbell.loading!.canBuild(proposed),
            "nearestAchievable produced \(proposed.pounds), which cannot be loaded"
        )
    }

    /// Swept rather than spot-checked: no proposal anywhere in a working range
    /// may be unbuildable.
    func testNoProposalInRangeIsUnbuildable() {
        var barbell = self.lift("Flat Bench")
        barbell.increment = LoadIncrement(pounds: 2.5)
        barbell.loading = .olympicBarbell

        var offenders: [Double] = []
        for tenths in stride(from: 450, through: 4000, by: 1) {
            let proposed = barbell.nearestAchievable(Load(Double(tenths) / 10))
            if !barbell.loading!.canBuild(proposed) { offenders.append(proposed.pounds) }
        }
        XCTAssertEqual(offenders.first, nil, "unbuildable proposals: \(offenders.prefix(5))")
    }

    /// Between two equally distant loadable weights, the lighter one wins —
    /// it's the one you can definitely finish.
    func testTiesRoundDown() {
        let style = LoadingStyle.olympicBarbell
        // 46.25 sits exactly between 45 (empty bar) and 47.5.
        XCTAssertEqual(style.nearestBuildable(Load(46.25)), Load(45))
    }

    func testAdjacentBuildableLoadsFollowCustomPlateCombinations() {
        let style = LoadingStyle(baseWeight: Load(50), sleeves: 1, availablePlates: [25, 10])

        XCTAssertEqual(style.nextBuildable(after: Load(50)), Load(60))
        XCTAssertEqual(style.nextBuildable(after: Load(60)), Load(70))
        XCTAssertEqual(style.previousBuildable(before: Load(80)), Load(75))
        XCTAssertEqual(style.previousBuildable(before: Load(60)), Load(50))
        XCTAssertNil(style.previousBuildable(before: Load(50)))
    }

    /// A bar cannot go below itself.
    func testNeverProposesLessThanTheApparatus() {
        let style = LoadingStyle.olympicBarbell
        XCTAssertEqual(style.nearestBuildable(Load(10)), Load(45))
    }

    /// An unmeasured machine has no plate set to consult, so the increment
    /// still decides — losing sync with the plates is not a reason to start
    /// inventing a base weight.
    func testUnmeasuredMachineStillSnapsToItsIncrement() {
        var machine = self.lift("Flat Bench")
        machine.increment = LoadIncrement(pounds: 10)
        machine.loading = .unmeasuredMachine(sleeves: 2)

        XCTAssertEqual(machine.nearestAchievable(Load(93)), Load(90))
    }
}
