import XCTest
@testable import WeightTrainingCore

final class LoadTests: XCTestCase {

    func testBarbellIncrementIsFivePoundsWithTwoAndAHalves() {
        XCTAssertEqual(LoadIncrement.barbell.pounds, 5)
    }

    /// The constraint that forces double progression across most of the app:
    /// 5 lb per hand is a 10 lb total jump.
    func testDumbbellIncrementIsTenPoundsTotal() {
        XCTAssertEqual(LoadIncrement.dumbbell.pounds, 10)
    }

    func testSnapRoundsDownToAchievableLoad() {
        XCTAssertEqual(LoadIncrement.barbell.snap(Load(187)), Load(185))
        XCTAssertEqual(LoadIncrement.dumbbell.snap(Load(78)), Load(70))
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
