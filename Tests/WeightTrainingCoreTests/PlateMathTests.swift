import XCTest
@testable import WeightTrainingCore

final class PlateMathTests: XCTestCase {

    func testBarOnly() throws {
        let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(45)))
        XCTAssertTrue(breakdown.isBarOnly)
        XCTAssertEqual(breakdown.displayLine, "Bar only")
        XCTAssertEqual(breakdown.total, Load(45))
    }

    func testOnePlatePerSide() throws {
        let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(135)))
        XCTAssertEqual(breakdown.perSide, [PlateCount(plate: 45, count: 1)])
        XCTAssertEqual(breakdown.displayLine, "45")
        XCTAssertEqual(breakdown.total, Load(135))
    }

    func testGreedyBreakdownUsesTheFewestPlates() throws {
        let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(225)))
        XCTAssertEqual(breakdown.perSide, [PlateCount(plate: 45, count: 2)])
        XCTAssertEqual(breakdown.displayLine, "45 · 45")
    }

    func testMixedPlates() throws {
        // 185 = 45 bar + 70 per side = 45 + 25
        let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(185)))
        XCTAssertEqual(breakdown.perSide, [
            PlateCount(plate: 45, count: 1),
            PlateCount(plate: 25, count: 1),
        ])
        XCTAssertEqual(breakdown.displayLine, "45 · 25")
    }

    /// The 2.5s are what make 5 lb barbell jumps possible at all.
    func testTwoAndAHalvesMakeFivePoundJumps() throws {
        let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(140)))
        XCTAssertEqual(breakdown.perSide, [
            PlateCount(plate: 45, count: 1),
            PlateCount(plate: 2.5, count: 1),
        ])
        XCTAssertEqual(breakdown.displayLine, "45 · 2.5")
        XCTAssertEqual(breakdown.total, Load(140))
    }

    func testTotalAlwaysMatchesTheRequestedLoad() throws {
        for pounds in stride(from: 45.0, through: 495.0, by: 5.0) {
            let breakdown = try XCTUnwrap(PlateMath.breakdown(for: Load(pounds)),
                                          "\(pounds) should be buildable")
            XCTAssertEqual(breakdown.total.pounds, pounds, accuracy: 0.001)
        }
    }

    // MARK: - Unbuildable loads

    /// Returning nil rather than a nearest guess keeps a rounding decision from
    /// hiding inside a display helper.
    func testLighterThanTheBarCannotBeBuilt() {
        XCTAssertNil(PlateMath.breakdown(for: Load(35)))
        XCTAssertNil(PlateMath.breakdown(for: Load(0)))
    }

    func testOffGridLoadsCannotBeBuilt() {
        XCTAssertNil(PlateMath.breakdown(for: Load(46)), "1 lb over the bar")
        XCTAssertNil(PlateMath.breakdown(for: Load(193.3)), "a raw percentage result")
    }

    // MARK: - Achievability by equipment

    func testPlateBuiltLoadsCheckedAgainstRealPlates() {
        XCTAssertTrue(PlateMath.isAchievable(Load(185), equipment: .barbell,
                                             increment: .barbell))
        XCTAssertFalse(PlateMath.isAchievable(Load(187.5), equipment: .barbell,
                                              increment: .barbell))
        XCTAssertFalse(PlateMath.isAchievable(Load(30), equipment: .barbell,
                                              increment: .barbell),
                       "lighter than the bar")
    }

    /// A dumbbell load is one hand's worth, so 75 is a real dumbbell and 72.5
    /// is not.
    func testDumbbellsMoveToTheNextDumbbellOnTheRack() {
        XCTAssertTrue(PlateMath.isAchievable(Load(70), equipment: .dumbbell,
                                             increment: .dumbbell))
        XCTAssertTrue(PlateMath.isAchievable(Load(75), equipment: .dumbbell,
                                             increment: .dumbbell))
        XCTAssertFalse(PlateMath.isAchievable(Load(72.5), equipment: .dumbbell,
                                              increment: .dumbbell),
                       "no such dumbbell")
    }

    func testStacksUseTheirConfiguredIncrement() {
        let measured = LoadIncrement(pounds: 15)
        XCTAssertTrue(PlateMath.isAchievable(Load(150), equipment: .machineStack,
                                             increment: measured))
        XCTAssertFalse(PlateMath.isAchievable(Load(155), equipment: .machineStack,
                                              increment: measured))
    }

    func testBreakdownIsNilForStackAndCableLifts() {
        let pulldown = ExerciseLibrary.all.first { $0.name == "Lat Pulldown" }!
        XCTAssertNil(pulldown.plateBreakdown(for: Load(150)),
                     "a stack has no plates to read off")

        let bench = ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
        XCTAssertNotNil(bench.plateBreakdown(for: Load(185)))
    }
}

/// #14's done-when, checked where it matters: no suggestion the app can
/// produce may propose an unbuildable weight.
final class SuggestionsAreAlwaysBuildableTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func assertBuildable(
        _ load: Load?,
        _ exercise: Exercise,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let load else { return }
        XCTAssertTrue(
            PlateMath.isAchievable(load, equipment: exercise.equipment,
                                   increment: exercise.increment),
            "\(exercise.name): \(context) proposed \(load), which can't be built",
            file: file, line: line
        )
    }

    /// Every library lift, every RPE chip, across a wide span of loads.
    func testEngineProposalsAreAlwaysBuildable() {
        for exercise in ExerciseLibrary.all {
            let start = exercise.equipment.isPlateBuilt ? 45.0 : 10.0
            for pounds in stride(from: start, through: 305.0, by: exercise.increment.pounds) {
                for rpe in RPE.sessionChips {
                    for reps in [5, 8, 12, 20] {
                        let performed = [SetRecord(exerciseID: exercise.id, load: Load(pounds),
                                                   reps: reps, rpe: rpe, performedAt: now)]
                        let result = ProgressionEngine.advance(
                            exercise: exercise,
                            state: ProgressState(exerciseID: exercise.id,
                                                 targetLoad: Load(pounds),
                                                 consecutiveTopHits: 1),
                            performed: performed
                        )
                        assertBuildable(result.state.targetLoad, exercise,
                                        "\(pounds) × \(reps) @ \(rpe)")
                    }
                }
            }
        }
    }

    func testDeloadProposalsAreAlwaysBuildable() {
        for exercise in ExerciseLibrary.all {
            let start = exercise.equipment.isPlateBuilt ? 45.0 : 10.0
            for pounds in stride(from: start, through: 305.0, by: exercise.increment.pounds) {
                let state = ProgressState(exerciseID: exercise.id,
                                          targetLoad: Load(pounds), stallCount: 2)
                let suggestion = DeloadDetector.evaluate(exercise: exercise, state: state,
                                                         history: [])
                assertBuildable(suggestion?.to, exercise, "deload from \(pounds)")
            }
        }
    }

    /// Ramp eligibility is derived from `equipment.isPlateBuilt` (#157), not
    /// the legacy `needsWarmupRamp` flag — checking every plate-built lift
    /// here, rather than only the 4 that used to carry the flag, is what
    /// gives Skull Crushers and Preacher Curls the same buildability coverage
    /// Flat Bench already had.
    func testWarmupRungsAreAlwaysBuildable() {
        for exercise in ExerciseLibrary.all where exercise.equipment.isPlateBuilt {
            for pounds in stride(from: 45.0, through: 405.0, by: exercise.increment.pounds) {
                for rung in WarmupRamp.generate(for: exercise, workingLoad: Load(pounds)) {
                    assertBuildable(rung.load, exercise, "warmup for \(pounds)")
                }
            }
        }
    }
}
