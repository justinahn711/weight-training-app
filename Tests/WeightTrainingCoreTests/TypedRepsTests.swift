import XCTest
@testable import WeightTrainingCore

final class TypedRepsTests: XCTestCase {

    func testParsesCountsBelowAndAboveTheQuickChoicesExactly() {
        XCTAssertEqual(TypedReps.parse("5"), 5)
        XCTAssertEqual(TypedReps.parse("25"), 25)
    }

    func testHasNoTargetDerivedUpperBound() {
        XCTAssertEqual(TypedReps.parse("1000"), 1000)
    }

    func testRejectsEmptyZeroAndNegativeInput() {
        XCTAssertNil(TypedReps.parse(""))
        XCTAssertNil(TypedReps.parse("   "))
        XCTAssertNil(TypedReps.parse("0"))
        XCTAssertNil(TypedReps.parse("-5"))
    }

    func testRejectsAnythingOtherThanAWholeNumber() {
        XCTAssertNil(TypedReps.parse("5.5"))
        XCTAssertNil(TypedReps.parse("five"))
        XCTAssertNil(TypedReps.parse("2 5"))
        XCTAssertNil(TypedReps.parse("+25"))
    }

    func testTrimsOnlySurroundingWhitespace() {
        XCTAssertEqual(TypedReps.parse(" 25\n"), 25)
    }
}
