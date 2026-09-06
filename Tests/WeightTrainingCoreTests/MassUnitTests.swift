import XCTest
@testable import WeightTrainingCore

/// Kilograms, and the things about them that aren't conversions (#67).
final class MassUnitTests: XCTestCase {

    // MARK: - The round trip

    /// Storage is canonically pounds, so every kg value makes a round trip on
    /// the way to disk and back. It has to come home to the same number.
    func testKilogramsSurviveStorageInPounds() {
        for kg in [1.25, 2.5, 20, 60, 100, 102.5, 227.5] {
            let load = Load(kg, .kilograms)
            XCTAssertEqual(load.value(in: .kilograms), kg, accuracy: 1e-9,
                           "\(kg) kg did not survive the trip through pounds")
        }
    }

    /// The float dust a round trip leaves behind must never reach the screen.
    /// 100 kg stored as pounds and read back is 99.99999999999999.
    func testDisplayHidesConversionNoise() {
        XCTAssertEqual(Load(100, .kilograms).formatted(in: .kilograms), "100 kg")
        XCTAssertEqual(Load(102.5, .kilograms).formatted(in: .kilograms), "102.5 kg")
        XCTAssertEqual(Load(45).formatted(in: .pounds), "45 lb")
    }

    /// A pound is exactly 0.45359237 kg, so the familiar pairs line up.
    func testConversionIsTheAgreedOne() {
        XCTAssertEqual(Load(100, .kilograms).pounds, 220.462, accuracy: 0.001)
        XCTAssertEqual(Load(45).value(in: .kilograms), 20.41, accuracy: 0.01)
    }

    // MARK: - Equipment is chosen, not converted

    /// A kg gym has a 20 kg bar. Not 20.41 — that's a converted 45 lb bar, and
    /// nobody racks one.
    func testStandardBarIsNativeNotConverted() {
        XCTAssertEqual(MassUnit.kilograms.standardBar.value(in: .kilograms), 20, accuracy: 1e-9)
        XCTAssertEqual(MassUnit.pounds.standardBar.pounds, 45, accuracy: 1e-9)
    }

    /// Likewise the plates: a kg rack runs 25 down to 1.25.
    func testStandardPlatesAreNative() {
        XCTAssertEqual(MassUnit.kilograms.standardPlates, [25, 20, 15, 10, 5, 2.5, 1.25])
        XCTAssertEqual(MassUnit.pounds.standardPlates, [45, 35, 25, 10, 5, 2.5])
    }

    /// 5 lb is a real increment. 2.27 kg is what you get by converting it, and
    /// it describes a rack that doesn't exist.
    func testIncrementsAreNativeAndRenderThatWay() {
        let metric = LoadIncrement(2.5, .kilograms)
        XCTAssertEqual(metric.nativeValue, 2.5, accuracy: 1e-9)
        XCTAssertEqual(metric.formatted, "2.5 kg")

        let imperial = LoadIncrement(pounds: 5)
        XCTAssertEqual(imperial.formatted, "5 lb")
    }

    // MARK: - Plate math in a kg gym

    /// 100 kg is a 20 kg bar and 40 kg a side: a 25 and a 15.
    func testKilogramBarbellBreaksDownIntoKilogramPlates() throws {
        let rack = LoadingStyle.standardBarbell(in: .kilograms)
        let breakdown = try XCTUnwrap(rack.breakdown(for: Load(100, .kilograms)))

        XCTAssertEqual(breakdown.displayLine, "25 · 15")
        XCTAssertEqual(breakdown.unit, .kilograms)
        XCTAssertEqual(breakdown.total.value(in: .kilograms), 100, accuracy: 1e-9)
    }

    /// The whole reason plate sets are unit-bound rather than converted.
    ///
    /// Run a kg rack through a multiplier and its plates become
    /// `[55.12, 44.09, 33.07, 22.05, 11.02, 5.51, 2.76]` — sizes whose only
    /// common divisor is a rounding artefact. The arithmetic still *succeeds*,
    /// which is the trap: asked for 100 kg it answers `55.1 · 11.0 · 11.0 ·
    /// 11.0`, four plates that don't exist, where the rack in the room loads a
    /// 25 and a 15. Wrong in a way that looks right, and it gets followed.
    func testConvertedPlatesNameWeightsTheGymDoesNotHave() throws {
        let native = LoadingStyle.standardBarbell(in: .kilograms)
        let right = try XCTUnwrap(native.breakdown(for: Load(100, .kilograms)))
        XCTAssertEqual(right.displayLine, "25 · 15")
        XCTAssertEqual(right.perSide.reduce(0) { $0 + $1.count }, 2)

        let converted = LoadingStyle(
            baseWeight: MassUnit.kilograms.standardBar,
            sleeves: 2,
            availablePlates: MassUnit.kilograms.standardPlates.map {
                MassUnit.kilograms.pounds(from: $0)
            },
            unit: .pounds
        )
        let wrong = try XCTUnwrap(converted.breakdown(for: Load(100, .kilograms)))
        XCTAssertNotEqual(wrong.displayLine, right.displayLine)
        XCTAssertGreaterThan(wrong.perSide.reduce(0) { $0 + $1.count },
                             right.perSide.reduce(0) { $0 + $1.count },
                             "converted plates take more iron to say the same thing")
    }

    /// And the conversion is lossy before the search even starts: plate
    /// arithmetic is exact integer work in hundredths, so a 1.25 kg plate
    /// converted to pounds rounds to 2.76 and is no longer 1.25 of anything.
    func testConvertingAPlateSetLosesThePlates() {
        let converted = MassUnit.kilograms.pounds(from: 1.25)
        let rounded = (converted * 100).rounded() / 100
        XCTAssertNotEqual(MassUnit.kilograms.value(fromPounds: rounded), 1.25,
                          "a converted plate set no longer describes real plates")
    }

    /// A heavy kg load still resolves cheaply rather than falling off the cap.
    func testHeavyKilogramLoadStillBuilds() throws {
        let rack = LoadingStyle.standardBarbell(in: .kilograms)
        let breakdown = try XCTUnwrap(rack.breakdown(for: Load(220, .kilograms)))
        XCTAssertEqual(breakdown.total.value(in: .kilograms), 220, accuracy: 1e-9)
    }

    /// An unbuildable kg weight snaps to one the rack can make, rounding down
    /// between equals the way the pound path does.
    func testNearestBuildableWorksInKilograms() {
        let rack = LoadingStyle.standardBarbell(in: .kilograms)
        let nearest = rack.nearestBuildable(Load(101, .kilograms))
        XCTAssertEqual(nearest.value(in: .kilograms), 100, accuracy: 1e-9)
        XCTAssertTrue(rack.canBuild(nearest))
    }

    /// 1.25s are what make the smallest honest kg jump possible, exactly as
    /// 2.5s do in pounds.
    func testSmallestKilogramJumpIsTwoAndAHalf() {
        let rack = LoadingStyle.standardBarbell(in: .kilograms)
        XCTAssertTrue(rack.canBuild(Load(22.5, .kilograms)), "bar plus a pair of 1.25s")
    }

    // MARK: - Nothing on disk has to change

    /// Rows written before #67 carry no unit. They are pounds by definition,
    /// and decoding must say so rather than throwing — this is what lets the
    /// change land without migrating a training history.
    func testLoadingStyleWithoutAUnitDecodesAsPounds() throws {
        let legacy = #"{"sleeves":2,"availablePlates":[45,35,25,10,5,2.5],"baseWeight":{"pounds":45}}"#
        let style = try JSONDecoder().decode(LoadingStyle.self, from: Data(legacy.utf8))

        XCTAssertEqual(style.unit, .pounds)
        XCTAssertEqual(style.baseWeight, Load(45))
        XCTAssertTrue(style.canBuild(Load(225)))
    }

    func testIncrementWithoutAUnitDecodesAsPounds() throws {
        let legacy = #"{"pounds":5}"#
        let increment = try JSONDecoder().decode(LoadIncrement.self, from: Data(legacy.utf8))

        XCTAssertEqual(increment.unit, .pounds)
        XCTAssertEqual(increment.pounds, 5)
    }

    /// And a unit that is written down survives the trip.
    func testUnitRoundTripsThroughCoding() throws {
        let rack = LoadingStyle.standardBarbell(in: .kilograms)
        let data = try JSONEncoder().encode(rack)
        let back = try JSONDecoder().decode(LoadingStyle.self, from: data)

        XCTAssertEqual(back.unit, .kilograms)
        XCTAssertEqual(back.availablePlates, rack.availablePlates)
        XCTAssertTrue(back.canBuild(Load(100, .kilograms)))
    }

    // MARK: - Rendering precision (#116)

    /// The smallest standard kilogram plate used to render as 1.2.
    ///
    /// The rule was one decimal, and its comment called that "finer than any
    /// plate in either world". `standardPlates` for kilograms ends in 1.25, so
    /// it was not — the plate toggles in the config screen offered a "1.2 kg"
    /// plate that does not exist, and every `Load` shown in kilograms was
    /// subject to the same trim.
    func testTheSmallestKilogramPlateRendersInFull() {
        XCTAssertEqual(MassUnit.kilograms.format(1.25), "1.25 kg")
        for plate in MassUnit.kilograms.standardPlates {
            let rendered = MassUnit.kilograms.format(plate, withSymbol: false)
            XCTAssertEqual(
                Double(rendered), plate,
                "\(plate) kg is a real plate and has to render as itself"
            )
        }
    }

    /// The plate sizes the screens actually offer, which are not the same
    /// list as `standardPlates`.
    ///
    /// `plateChoices` in the config and settings screens offers 1.25 and 15 in
    /// pounds too — real toggles, and neither appears in `standardPlates`, so
    /// looping that list alone left the pound-side 1.25 untested while the
    /// whole issue was about a 1.25 rendering wrong.
    func testEveryPlateAScreenOffersRendersAsItself() {
        let offered: [MassUnit: [Double]] = [
            .pounds: [45, 35, 25, 15, 10, 5, 2.5, 1.25],
            .kilograms: [25, 20, 15, 10, 5, 2.5, 1.25],
        ]
        for (unit, plates) in offered {
            for plate in plates {
                let rendered = unit.format(plate, withSymbol: false)
                XCTAssertEqual(
                    Double(rendered), plate,
                    "\(plate) \(unit.symbol) is a plate someone can toggle on"
                )
            }
        }
    }

    /// The plate line read while loading a bar had its own copy of the rule.
    ///
    /// `PlateBreakdown.displayLine` inlined one decimal against native plate
    /// sizes, so a metric breakdown containing the 1.25 pair rendered "1.2" —
    /// the same nonexistent plate, on the one screen consulted with a bar in
    /// hand rather than out of curiosity.
    func testThePlateLineRendersAMetricPairInFull() {
        let style = LoadingStyle(
            baseWeight: Load(20, .kilograms),
            sleeves: 2,
            availablePlates: [25, 20, 15, 10, 5, 2.5, 1.25],
            unit: .kilograms
        )
        let breakdown = style.breakdown(for: Load(22.5, .kilograms))
        XCTAssertEqual(breakdown?.displayLine, "1.25", "a 1.25 kg pair, named properly")
    }

    /// Trailing zeros claim precision the number does not have.
    func testWholeWeightsCarryNoDecimals() {
        XCTAssertEqual(MassUnit.pounds.format(45), "45 lb")
        XCTAssertEqual(MassUnit.pounds.format(2.5), "2.5 lb")
        for plate in MassUnit.pounds.standardPlates {
            let rendered = MassUnit.pounds.format(plate, withSymbol: false)
            XCTAssertEqual(Double(rendered), plate)
        }
    }

    /// The original and correct reason for rounding at all: a kilogram value
    /// stored in canonical pounds and read back is not quite itself, and
    /// showing 99.99999999999999 would be an unforced insult.
    func testConversionNoiseStaysHidden() {
        let hundredKilos = Load(100, .kilograms)
        XCTAssertEqual(hundredKilos.formatted(in: .kilograms), "100 kg")

        let twentyKilos = Load(20, .kilograms)
        XCTAssertEqual(twentyKilos.formatted(in: .kilograms), "20 kg")
    }

    /// A typed empty weight survives being shown and read back — the round
    /// trip that put 45.2 in the field after typing 45.25.
    func testATypedWeightSurvivesRendering() {
        for typed in [45.25, 27.5, 102.5, 1.25, 75] {
            let rendered = MassUnit.pounds.format(typed, withSymbol: false)
            XCTAssertEqual(Double(rendered), typed, "\(typed) changed on the way to the screen")
        }
    }
}

/// Snapping a metric load used to lose a whole increment to float error.
///
/// Canonical loads are pounds, so a kilogram load divided by a kilogram
/// increment can land on 15.999999999999998 where the arithmetic says 16.
/// Flooring that dropped a full step: a 100 kg set on a 20 kg bar with 2.5 kg
/// plates produced a 57.5 kg warmup rung where 60 was intended, and the same
/// path backs off a deload. The number reached the lifter, so this is a
/// wrong-weight bug, not a rounding cosmetic.
final class MetricSnapTests: XCTestCase {
    func testSnapKeepsExactMetricMultiples() {
        let step = LoadIncrement(2.5, .kilograms)
        for kg in stride(from: 20.0, through: 200.0, by: 2.5) {
            let snapped = step.snap(Load(kg, .kilograms))
            XCTAssertEqual(
                snapped.value(in: .kilograms), kg, accuracy: 0.0001,
                "\(kg) kg is an exact multiple of a 2.5 kg step and must snap to itself"
            )
        }
    }

    func testSnapStillRoundsDownAGenuinelyShortLoad() {
        let step = LoadIncrement(2.5, .kilograms)
        let snapped = step.snap(Load(101.2, .kilograms))
        XCTAssertEqual(snapped.value(in: .kilograms), 100.0, accuracy: 0.0001)
    }

    func testSixtyPercentOfAMetricWorkingSetIsBuildable() {
        let step = LoadIncrement(2.5, .kilograms)
        let sixty = step.snap(Load(Load(100, .kilograms).pounds * 0.6))
        XCTAssertEqual(sixty.value(in: .kilograms), 60.0, accuracy: 0.0001)
    }

}
