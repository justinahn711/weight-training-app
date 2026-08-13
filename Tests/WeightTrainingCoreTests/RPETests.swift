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

    func testAllowedValuesAreTheFullStorableGrid() {
        XCTAssertEqual(RPE.allowedValues, [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10])
    }

    /// The chip row drops 6.5: below RPE 7 nothing counts as hard volume, so
    /// the extra precision buys nothing and costs width on a row tapped with
    /// chalky hands.
    func testSessionChipsOmitSixAndAHalf() {
        XCTAssertEqual(RPE.sessionChips.map(\.value), [6, 7, 7.5, 8, 8.5, 9, 9.5, 10])
        XCTAssertFalse(RPE.sessionChips.contains(RPE(6.5)!))
    }

    /// Every chip must still be a storable value, or logging would fail on a
    /// value the UI itself offered.
    func testEveryChipIsStorable() {
        for chip in RPE.sessionChips {
            XCTAssertNotNil(RPE(chip.value))
        }
    }

    /// Snapping still reaches 6.5, since the voice parser (#21) rounds onto the
    /// full grid rather than the chip row.
    func testSnappingCanStillProduceSixAndAHalf() {
        XCTAssertEqual(RPE(snapping: 6.4).value, 6.5)
    }
}
