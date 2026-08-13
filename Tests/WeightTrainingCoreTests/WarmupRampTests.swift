import XCTest
@testable import WeightTrainingCore

final class WarmupRampTests: XCTestCase {

    private var bench: Exercise {
        ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
    }

    private var lateralRaise: Exercise {
        ExerciseLibrary.all.first { $0.name == "Lateral Raise" }!
    }

    private var inclinePress: Exercise {
        ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
    }

    /// #15's done-when, first half: ramps appear for flagged lifts only.
    func testOnlyFlaggedLiftsGetARamp() {
        XCTAssertFalse(WarmupRamp.generate(for: bench, workingLoad: Load(225)).isEmpty)
        XCTAssertTrue(
            WarmupRamp.generate(for: lateralRaise, workingLoad: Load(30)).isEmpty,
            "a cable lateral doesn't need a warmup block"
        )
        XCTAssertTrue(
            WarmupRamp.generate(for: inclinePress, workingLoad: Load(70)).isEmpty,
            "not flagged, so no ramp regardless of load"
        )
    }

    func testEveryFlaggedLibraryLiftProducesARamp() {
        for exercise in ExerciseLibrary.all where exercise.needsWarmupRamp {
            let ramp = WarmupRamp.generate(for: exercise, workingLoad: Load(225))
            XCTAssertFalse(ramp.isEmpty, "\(exercise.name) is flagged but produced nothing")
        }
    }

    func testColdStartHasNoRamp() {
        XCTAssertTrue(WarmupRamp.generate(for: bench, workingLoad: nil).isEmpty,
                      "nothing to ramp toward yet")
        XCTAssertTrue(WarmupRamp.generate(for: bench, workingLoad: Load(0)).isEmpty)
    }

    // MARK: - Shape of the ramp

    func testRampStartsAtTheBarAndClimbs() throws {
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(225))
        XCTAssertEqual(ramp.first?.load, Load(45), "everybody starts with the empty bar")

        let loads = ramp.map(\.load)
        XCTAssertEqual(loads, loads.sorted(), "rungs climb")
        for rung in ramp {
            XCTAssertLessThan(rung.load, Load(225), "a warmup is never the working weight")
        }
    }

    /// Reps fall as the weight rises — doing eight at 80% spends the working
    /// sets before they start.
    func testRepsFallAsWeightRises() {
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(225))
        let reps = ramp.map(\.reps)
        XCTAssertEqual(reps, reps.sorted(by: >), "reps decrease as load increases")
    }

    func testRungsAreBuildableWithRealPlates() throws {
        for rung in WarmupRamp.generate(for: bench, workingLoad: Load(225)) {
            XCTAssertNotNil(PlateMath.breakdown(for: rung.load),
                            "\(rung.load) can't be loaded")
        }
    }

    /// 225 → bar, 90, 135, 180.
    func testWorkedExample() {
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(225))
        XCTAssertEqual(ramp.map(\.load), [Load(45), Load(90), Load(135), Load(180)])
    }

    func testNoDuplicateRungs() {
        for working in stride(from: 45.0, through: 405.0, by: 5.0) {
            let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(working))
            XCTAssertEqual(Set(ramp.map(\.load)).count, ramp.count,
                           "duplicate rung at working load \(working)")
        }
    }

    /// A working weight barely above the bar collapses every rung onto the bar
    /// itself, and the ramp should be short rather than repetitive.
    func testLightWorkingLoadProducesAShortRamp() {
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(50))
        XCTAssertEqual(ramp.map(\.load), [Load(45)])
    }

    func testWorkingLoadAtTheBarHasNoRamp() {
        XCTAssertTrue(WarmupRamp.generate(for: bench, workingLoad: Load(45)).isEmpty,
                      "there is nothing to ramp up to")
    }

    // MARK: - Ramps stay out of statistics

    /// #15's done-when, second half. The ramp is a plan; only what's logged as
    /// a warmup set exists, and warmups are excluded everywhere.
    func testWarmupsNeverAppearInAnyStatistic() throws {
        let lift = bench
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        var performed: [SetRecord] = WarmupRamp
            .generate(for: lift, workingLoad: Load(225))
            .enumerated()
            .map { index, rung in
                SetRecord(exerciseID: lift.id, load: rung.load, reps: rung.reps,
                          isWarmup: true,
                          performedAt: now.addingTimeInterval(Double(index) * 120))
            }
        performed.append(SetRecord(exerciseID: lift.id, load: Load(225), reps: 5,
                                   rpe: RPE(8), performedAt: now.addingTimeInterval(600)))

        // Volume
        XCTAssertEqual(performed.filter(\.isHardSet).count, 1)

        // e1RM — a 180 lb warmup must not become the estimate
        let best = try XCTUnwrap(performed.bestE1RM)
        XCTAssertEqual(best.pounds, 225 * (1 + 7.0 / 30), accuracy: 0.01)

        // Progression: the reference load is the working set, not the ramp
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(225)),
            performed: performed
        )
        XCTAssertEqual(result.state.targetLoad, Load(225))

        // Last performance
        let last = try XCTUnwrap(LastPerformance.mostRecent(in: performed))
        XCTAssertEqual(last.sets.count, 1)
        XCTAssertEqual(last.displayLine, "225 lb × 5")

        // Session grouping
        XCTAssertEqual(performed.groupedIntoSessions().first?.count, 1)
    }
}
