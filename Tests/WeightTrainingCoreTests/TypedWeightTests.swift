import XCTest
@testable import WeightTrainingCore

final class TypedWeightTests: XCTestCase {

    func testParsesTheNumberThatWasTyped() {
        XCTAssertEqual(TypedWeight.parse("75"), 75)
        XCTAssertEqual(TypedWeight.parse("102.5"), 102.5)
        XCTAssertEqual(TypedWeight.parse("0.5"), 0.5)
    }

    /// The empty weight is read off a machine, and machines are heavy in ways
    /// nobody would think to allow for. A ceiling picked in an editor rejects a
    /// real sled at the rack, with no way around it, so there isn't one.
    func testHasNoUpperBound() {
        XCTAssertEqual(TypedWeight.parse("1000"), 1000)
        XCTAssertEqual(TypedWeight.parse("12345.5"), 12345.5)
    }

    /// The state a field is in for as long as the old value is being cleared.
    /// Reading it as a number at all is the bug: it would be zero.
    func testAnEmptyFieldNamesNoWeight() {
        XCTAssertNil(TypedWeight.parse(""))
        XCTAssertNil(TypedWeight.parse("   "))
    }

    func testJunkNamesNoWeight() {
        XCTAssertNil(TypedWeight.parse("abc"))
        XCTAssertNil(TypedWeight.parse("-"))
        XCTAssertNil(TypedWeight.parse("."))
        XCTAssertNil(TypedWeight.parse("7.5kg"))
        XCTAssertNil(TypedWeight.parse("nan"))
        XCTAssertNil(TypedWeight.parse("inf"))
    }

    /// Zero is the value the whole exercise exists to keep out. An apparatus
    /// that hasn't been weighed carries a nil base weight and shows no plate
    /// line at all; a zero one shows a plate line that is wrong by the sled,
    /// and that one gets loaded onto a bar.
    func testZeroAndNegativesNameNoWeight() {
        XCTAssertNil(TypedWeight.parse("0"))
        XCTAssertNil(TypedWeight.parse("0.0"))
        XCTAssertNil(TypedWeight.parse("-45"))
    }

    /// A decimal pad prints whatever the locale's separator is, and in most of
    /// the world that is a comma. Refusing it would make the field untypeable
    /// on the devices most likely to be marked in kilograms.
    func testACommaIsADecimalPoint() {
        XCTAssertEqual(TypedWeight.parse("102,5"), 102.5)
    }

    /// Half-typed numbers arrive on every keystroke and are still weights.
    func testAcceptsAPartiallyTypedDecimal() {
        XCTAssertEqual(TypedWeight.parse("7."), 7)
        XCTAssertEqual(TypedWeight.parse(" 45 "), 45)
    }

    /// The value goes into `Load(_:_:)` in the unit the lift is marked in, and
    /// what is stored is canonical pounds — the typed figure is never a raw
    /// pound value shown to the lifter.
    func testATypedValueIsInTheUnitItWasTypedIn() throws {
        let typed = try XCTUnwrap(TypedWeight.parse("100"))

        XCTAssertEqual(Load(typed, .kilograms).pounds, 220.46, accuracy: 0.01)
        XCTAssertEqual(Load(typed, .kilograms).value(in: .kilograms), 100, accuracy: 0.0001)
        XCTAssertEqual(Load(typed, .pounds).pounds, 100)
    }
}
