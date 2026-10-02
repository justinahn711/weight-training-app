import XCTest
@testable import WeightTrainingCore

final class LoadTests: XCTestCase {

    func testBarbellIncrementIsFivePoundsWithTwoAndAHalves() {
        XCTAssertEqual(LoadIncrement.barbell.pounds, 5)
    }

    /// The constraint that forces double progression across most of the app:
    /// 5 lb per hand is a 10 lb total jump.
    /// The unit is not uniform across equipment, and that's deliberate.
    ///
    /// A barbell number is the whole bar; a dumbbell number is one hand. Making
    /// them uniform would mean logging a pair of 70s as 140, which nobody does
    /// and everybody would misread. This test exists so the convention can't be
    /// "corrected" back by someone who reads it as a bug.
    func testLoadUnitsFollowHowLiftersActuallySpeak() {
        let bench = ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
        let press = ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!

        // 225 on a bar is 45 + two 45s a side, not 225 in each hand.
        XCTAssertEqual(bench.plateBreakdown(for: Load(225))?.displayLine, "45 · 45 per side")

        // 70 on dumbbells means the 70s; the next one up is 75, not 80.
        XCTAssertEqual(press.increment.pounds, 5)
        XCTAssertEqual(press.nearestAchievable(Load(73)), Load(75))
        XCTAssertNil(press.plateBreakdown(for: Load(70)),
                     "a dumbbell has no plates to read off")
    }

    /// A dumbbell load is what's in one hand, so the increment is the step to
    /// the next dumbbell on the rack — not the change in total weight moved.
    func testDumbbellIncrementIsFivePoundsPerHand() {
        XCTAssertEqual(LoadIncrement.dumbbell.pounds, 5)
    }

    func testSnapRoundsDownToAchievableLoad() {
        XCTAssertEqual(LoadIncrement.barbell.snap(Load(187)), Load(185))
        XCTAssertEqual(LoadIncrement.dumbbell.snap(Load(78)), Load(75))
        XCTAssertEqual(LoadIncrement.stackDefault.snap(Load(119)), Load(110))
    }

    func testSnapLeavesExactMultiplesAlone() {
        XCTAssertEqual(LoadIncrement.barbell.snap(Load(185)), Load(185))
        XCTAssertEqual(LoadIncrement.dumbbell.snap(Load(70)), Load(70))
    }

    /// Rounding down rather than to nearest guarantees a suggestion never
    /// proposes more weight than the engine intended.
    func testSnapNeverRoundsUp() {
        for raw in stride(from: 0.0, through: 300.0, by: 0.5) {
            let snapped = LoadIncrement.barbell.snap(Load(raw))
            XCTAssertLessThanOrEqual(snapped.pounds, raw, "snapped \(raw) up to \(snapped.pounds)")
        }
    }

    func testDescriptionDropsTrailingZero() {
        XCTAssertEqual(Load(185).description, "185 lb")
        XCTAssertEqual(Load(72.5).description, "72.5 lb")
    }

    func testArithmeticAndComparison() {
        XCTAssertEqual(Load(185) + Load(5), Load(190))
        XCTAssertEqual(Load(185) - Load(5), Load(180))
        XCTAssertEqual(Load(200) * 0.9, Load(180))
        XCTAssertTrue(Load(180) < Load(185))
    }
}
