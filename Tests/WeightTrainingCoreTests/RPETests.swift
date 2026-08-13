import XCTest
@testable import WeightTrainingCore

final class RPETests: XCTestCase {

    func testAcceptsLegalHalfSteps() {
        XCTAssertNotNil(RPE(6))
        XCTAssertNotNil(RPE(7.5))
        XCTAssertNotNil(RPE(10))
    }

    /// Rejecting rather than clamping — an out-of-range value means a bug
    /// upstream, and coercing it would quietly corrupt e1RM.
    func testRejectsOutOfRangeAndOffGridValues() {
        XCTAssertNil(RPE(5.5))
        XCTAssertNil(RPE(10.5))
        XCTAssertNil(RPE(8.3))
    }

    func testSnappingInitRoundsToNearestChip() {
        XCTAssertEqual(RPE(snapping: 8.3).value, 8.5)
        XCTAssertEqual(RPE(snapping: 8.2).value, 8.0)
        XCTAssertEqual(RPE(snapping: 3.0).value, 6.0)   // clamps low
        XCTAssertEqual(RPE(snapping: 99.0).value, 10.0) // clamps high
    }

    func testRepsInReserve() {
        XCTAssertEqual(RPE(8)!.repsInReserve, 2)
        XCTAssertEqual(RPE(6.5)!.repsInReserve, 3.5)
        XCTAssertEqual(RPE(10)!.repsInReserve, 0)
    }

    func testOrdering() {
        XCTAssertTrue(RPE(6.5)! < RPE(8)!)
        XCTAssertTrue(RPE(9.5)! > RPE(9)!)
    }

    func testAllowedValuesAreTheChipRow() {
        XCTAssertEqual(RPE.allowedValues, [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10])
    }
}
