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

    /// A paste is the only way these reach the field, and the field's own doc
    /// comment promises to handle "whatever a paste leaves behind".
    ///
    /// `Double(_:)` is strtod-backed and would otherwise read "1e3" as a
    /// thousand-pound sled. Every plate line off that machine would then be
    /// wrong by the whole apparatus, silently, which is the failure this type
    /// exists to prevent.
    func testRefusesFormsADecimalPadCannotType() {
        XCTAssertNil(TypedWeight.parse("1e3"))
        XCTAssertNil(TypedWeight.parse("0x10"))
        XCTAssertNil(TypedWeight.parse("+45"))
        XCTAssertNil(TypedWeight.parse("4 5"), "an internal space is not a number")
        XCTAssertNil(TypedWeight.parse("45lb"), "the unit is a label, not typed")
    }

    /// "1,234" means 1234 to a grouped paste and 1.234 to a decimal comma, and
    /// the string does not say which.
    ///
    /// Refused rather than guessed. 1.234 kg is not a weight anybody measured,
    /// so the wrong branch of the guess produces a number that gets believed
    /// and loaded — while refusing costs one retype.
    func testRefusesAnAmbiguousGroupedNumber() {
        XCTAssertNil(TypedWeight.parse("1,234"))
        XCTAssertNil(TypedWeight.parse("1.234"))
        XCTAssertNil(TypedWeight.parse("12,500"))
    }

    /// Two separators is not a number in any locale.
    func testRefusesMoreThanOneSeparator() {
        XCTAssertNil(TypedWeight.parse("1,234.5"))
        XCTAssertNil(TypedWeight.parse("1.2.3"))
    }

    /// The forms a decimal pad actually produces still work.
    func testStillAcceptsWhatThePadTypes() {
        XCTAssertEqual(TypedWeight.parse("45"), 45)
        XCTAssertEqual(TypedWeight.parse("45.25"), 45.25)
        XCTAssertEqual(TypedWeight.parse("45,25"), 45.25, "decimal comma")
        XCTAssertEqual(TypedWeight.parse("102.5"), 102.5)
        XCTAssertEqual(TypedWeight.parse("7."), 7, "on the way to 7.5")
    }

    func testExactRackWeightResolvesWithoutChangingIt() {
        let dumbbell = Exercise(name: "Curl", muscles: [], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        XCTAssertEqual(TypedWeight.resolve("70", in: .pounds, for: dumbbell),
                       .exact(Load(70)))
    }

    func testImpossibleRackWeightOffersNearestInsteadOfAcceptingIt() {
        let dumbbell = Exercise(name: "Curl", muscles: [], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        XCTAssertEqual(TypedWeight.resolve("72", in: .pounds, for: dumbbell),
                       .nearest(requested: Load(72), achievable: Load(70)))
        XCTAssertFalse(dumbbell.canBuild(Load(72)))
    }

    func testTypedPlateLoadUsesTheConfiguredRack() {
        let barbell = Exercise(name: "Bench", muscles: [], equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(5, 8)))
        XCTAssertEqual(TypedWeight.resolve("187", in: .pounds, for: barbell),
                       .nearest(requested: Load(187), achievable: Load(185)))
    }

    func testTypedWeightUsesTheFieldUnitBeforeBuildability() {
        let stack = Exercise(name: "Pulldown", muscles: [], equipment: .machineStack,
            increment: LoadIncrement(5, .kilograms),
            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        guard case .exact(let load) = TypedWeight.resolve("75", in: .kilograms, for: stack)
        else { return XCTFail("75 kg should be an exact stack setting") }
        XCTAssertEqual(load.value(in: MassUnit.kilograms), 75, accuracy: 0.0001)
    }

    func testNearestTypedWeightNeverOffersZero() {
        let dumbbell = Exercise(name: "Raise", muscles: [], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(10, 15)))
        XCTAssertEqual(TypedWeight.resolve("1", in: .pounds, for: dumbbell),
                       .nearest(requested: Load(1), achievable: Load(5)))
    }
}
