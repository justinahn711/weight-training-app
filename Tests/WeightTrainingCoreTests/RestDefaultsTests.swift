import XCTest
@testable import WeightTrainingCore

/// The two rests a lift falls back on when nobody has given it its own, now a
/// setting the lifter owns rather than a literal in the code (#341).
///
/// The claim under test is that the lifter's number reaches every lift that
/// has no opinion of its own, and reaches nothing else: not a lift with an
/// override, and not the question of which lifts count as compound.
final class RestDefaultsTests: XCTestCase {

    private func exercise(muscles: [MuscleInvolvement], equipment: Equipment,
                          restOverride: TimeInterval? = nil) -> Exercise {
        Exercise(
            name: "Test",
            muscles: muscles,
            equipment: equipment,
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            restOverride: restOverride
        )
    }

    private var compoundLift: Exercise {
        exercise(muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
                 equipment: .dumbbell)
    }

    private var accessoryLift: Exercise {
        exercise(muscles: [.primary(.sideDelts)], equipment: .dumbbell)
    }

    private func decode(_ json: String) throws -> RestDefaults {
        try JSONDecoder().decode(RestDefaults.self, from: Data(json.utf8))
    }

    // MARK: - Out of the box

    /// The owner's numbers (#341): compounds need two to three minutes,
    /// accessories about one. 90 seconds, the old accessory rest, was longer
    /// than they wanted.
    func testStandardIsThreeMinutesForCompoundsAndOneForAccessories() {
        XCTAssertEqual(RestDefaults.standard.compound, 180)
        XCTAssertEqual(RestDefaults.standard.accessory, 60)
        XCTAssertEqual(RestDefaults(), .standard)
    }

    func testStandardDefaultsDriveTheRestOfALiftWithNoOverride() {
        XCTAssertEqual(compoundLift.restTarget(using: .standard), 180)
        XCTAssertEqual(accessoryLift.restTarget(using: .standard), 60)
    }

    // MARK: - The lifter's own numbers

    /// The point of the issue: change the setting and the next rest changes.
    func testCustomDefaultsReachLiftsWithoutAnOverride() {
        let mine = RestDefaults(compound: 150, accessory: 45)
        XCTAssertEqual(compoundLift.restTarget(using: mine), 150)
        XCTAssertEqual(accessoryLift.restTarget(using: mine), 45)
    }

    /// Each default belongs to its own kind of lift: raising the compound
    /// rest must not drag the accessories with it, which is the mistake a
    /// single "default rest" setting would have made.
    func testTheTwoDefaultsAreIndependent() {
        let longCompoundsOnly = RestDefaults(compound: 300, accessory: RestDefaults.standard.accessory)
        XCTAssertEqual(compoundLift.restTarget(using: longCompoundsOnly), 300)
        XCTAssertEqual(accessoryLift.restTarget(using: longCompoundsOnly), 60)

        let longAccessoriesOnly = RestDefaults(compound: RestDefaults.standard.compound, accessory: 120)
        XCTAssertEqual(compoundLift.restTarget(using: longAccessoriesOnly), 180)
        XCTAssertEqual(accessoryLift.restTarget(using: longAccessoriesOnly), 120)
    }

    /// "A lift with its own rest time keeps it" (#341): whatever the lifter
    /// does to the defaults, an override is still the answer, for both kinds
    /// and in both directions.
    func testAnOverrideBeatsBothDefaults() {
        let shortDefaults = RestDefaults(compound: 30, accessory: 20)
        let longDefaults = RestDefaults(compound: 600, accessory: 500)

        for restOverride in [90.0, 240.0] {
            let press = exercise(
                muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
                equipment: .dumbbell, restOverride: restOverride)
            let raise = exercise(
                muscles: [.primary(.sideDelts)], equipment: .dumbbell, restOverride: restOverride)

            for defaults in [shortDefaults, longDefaults, .standard] {
                XCTAssertEqual(press.restTarget(using: defaults), restOverride)
                XCTAssertEqual(raise.restTarget(using: defaults), restOverride)
            }
        }
    }

    /// The reason `Exercise.restOverride` stays nil on a lift nobody has
    /// touched: the default must be looked up at the moment a rest starts, so
    /// a later change to the setting still applies. Frozen into the lift, it
    /// would only apply to lifts created afterwards.
    func testTheDefaultIsReadWhenARestStartsNotFrozenIntoTheLift() {
        let press = compoundLift
        XCTAssertNil(press.restOverride)
        XCTAssertEqual(press.restTarget(using: RestDefaults(compound: 120, accessory: 60)), 120)
        XCTAssertEqual(press.restTarget(using: RestDefaults(compound: 240, accessory: 60)), 240)
        XCTAssertNil(press.restOverride, "asking for a rest must not write one down")
    }

    // MARK: - What a lift follows

    /// Lift settings show "which default a lift follows and that default's
    /// current value" (#341), and that is true whether or not the lift has an
    /// override of its own: the sheet needs to say what turning the override
    /// off would give back.
    func testDefaultRestIsWhatTheLiftFollowsRegardlessOfItsOverride() {
        let mine = RestDefaults(compound: 150, accessory: 45)
        let overridden = exercise(
            muscles: [.primary(.sideDelts)], equipment: .dumbbell, restOverride: 240)

        XCTAssertEqual(compoundLift.defaultRest(using: mine), 150)
        XCTAssertEqual(accessoryLift.defaultRest(using: mine), 45)
        XCTAssertEqual(overridden.defaultRest(using: mine), 45,
                       "an override doesn't change which default the lift would follow")
        XCTAssertEqual(overridden.restTarget(using: mine), 240)
    }

    func testALiftNamesTheDefaultItFollows() {
        XCTAssertEqual(compoundLift.restDefaultKind, .compound)
        XCTAssertEqual(accessoryLift.restDefaultKind, .accessory)
        XCTAssertEqual(RestDefaults.Kind.allCases.count, 2)
    }

    func testDefaultsAreAskedForByKindOrByLift() {
        let mine = RestDefaults(compound: 150, accessory: 45)
        XCTAssertEqual(mine.seconds(for: .compound), 150)
        XCTAssertEqual(mine.seconds(for: .accessory), 45)
        XCTAssertEqual(mine.seconds(for: compoundLift), 150)
        XCTAssertEqual(mine.seconds(for: accessoryLift), 45)
    }

    // MARK: - Which lifts are compound is not the lifter's setting

    /// #341 changes how long each kind rests, never which kind a lift is.
    /// With two numbers nothing else could produce, every library lift must
    /// land on the number its `isCompound` says, so a future edit that quietly
    /// reclassifies a lift through the rest setting fails here.
    func testRoutingFollowsIsCompoundForEveryLibraryLift() {
        let distinct = RestDefaults(compound: 211, accessory: 37)
        for lift in ExerciseLibrary.all {
            XCTAssertEqual(
                lift.defaultRest(using: distinct), lift.isCompound ? 211 : 37, lift.name)
            XCTAssertEqual(lift.restDefaultKind, lift.isCompound ? .compound : .accessory, lift.name)
        }
    }

    /// Plate-built lifts are compound however few muscles they're tagged
    /// with, and that still decides which rest they get.
    func testAPlateBuiltLiftStillFollowsTheCompoundDefault() {
        let rdl = exercise(muscles: [.primary(.hamstrings)], equipment: .barbell)
        XCTAssertTrue(rdl.isCompound)
        XCTAssertEqual(rdl.restTarget(using: RestDefaults(compound: 200, accessory: 40)), 200)
    }

    // MARK: - Round trip and old data

    func testDefaultsSurviveARoundTrip() throws {
        let mine = RestDefaults(compound: 150, accessory: 45)
        let data = try JSONEncoder().encode(mine)
        XCTAssertEqual(try JSONDecoder().decode(RestDefaults.self, from: data), mine)
    }

    /// Half-written data reads as the half it has plus the standard for the
    /// rest, rather than throwing and taking the whole gym row with it.
    func testAMissingKeyReadsAsTheStandardForThatKind() throws {
        XCTAssertEqual(try decode("{}"), .standard)
        XCTAssertEqual(try decode(#"{"compound":120}"#), RestDefaults(compound: 120, accessory: 60))
        XCTAssertEqual(try decode(#"{"accessory":45}"#), RestDefaults(compound: 180, accessory: 45))
    }

    // MARK: - Garbage from sync or a backup

    /// A usable default is a finite number of seconds from one second to an
    /// hour; anything else is replaced by the standard for that kind.
    ///
    /// Why not clamp: a rest of -30 or NaN says nothing about what the lifter
    /// wanted, so the honest answer is the number they'd have had without the
    /// setting, not the nearest edge of a range. Why this range: zero and
    /// negative are never a rest; under a second truncates to `0` when the app
    /// turns it into a plan's `restSeconds` (which the engine rejects as an
    /// invalid plan); and a number past an hour would be a rest the app
    /// abandons after ten minutes of overrun anyway.
    func testAnUnusableDefaultFallsBackToTheStandardForItsKind() {
        let garbage: [TimeInterval] = [
            0, -30, -.leastNonzeroMagnitude, 0.5, 0.999,
            .nan, .infinity, -.infinity, 3600.001, 1e30, .greatestFiniteMagnitude,
        ]
        for value in garbage {
            let badCompound = RestDefaults(compound: value, accessory: 45)
            XCTAssertEqual(badCompound.compound, 180, "compound \(value)")
            XCTAssertEqual(badCompound.accessory, 45, "a bad compound must not cost the accessory")

            let badAccessory = RestDefaults(compound: 150, accessory: value)
            XCTAssertEqual(badAccessory.accessory, 60, "accessory \(value)")
            XCTAssertEqual(badAccessory.compound, 150, "a bad accessory must not cost the compound")
        }
    }

    func testTheEdgesOfTheUsableRangeAreAccepted() {
        XCTAssertEqual(RestDefaults(compound: 1, accessory: 3600).compound, 1)
        XCTAssertEqual(RestDefaults(compound: 1, accessory: 3600).accessory, 3600)
        XCTAssertEqual(RestDefaults(compound: 90.5, accessory: 30).compound, 90.5)
    }

    /// The Settings screen edits the fields in place, so the rule can't live
    /// only in `init`.
    func testAssigningGarbageLaterFallsBackToo() {
        var defaults = RestDefaults(compound: 150, accessory: 45)
        defaults.compound = .nan
        defaults.accessory = -10
        XCTAssertEqual(defaults, .standard)

        defaults.compound = 200
        XCTAssertEqual(defaults.compound, 200, "a good assignment still lands")
    }

    func testGarbageNeverBecomesAZeroNegativeOrNonFiniteRest() {
        let garbage = RestDefaults(compound: .nan, accessory: -1)
        for lift in [compoundLift, accessoryLift] {
            let rest = lift.restTarget(using: garbage)
            XCTAssertTrue(rest.isFinite)
            XCTAssertGreaterThan(rest, 0)
            XCTAssertGreaterThanOrEqual(Int(rest), 1, "the plan's whole-second rest must not truncate to zero")
        }
        XCTAssertEqual(compoundLift.restTarget(using: garbage), 180)
        XCTAssertEqual(accessoryLift.restTarget(using: garbage), 60)
    }

    /// The same rule has to hold when the values arrive through decoding,
    /// which is how a corrupt row or a hand-edited backup gets here.
    func testGarbageInStoredDataFallsBackWhenDecoded() throws {
        XCTAssertEqual(try decode(#"{"compound":0,"accessory":-60}"#), .standard)
        XCTAssertEqual(try decode(#"{"compound":1e30,"accessory":0.1}"#), .standard)
        XCTAssertEqual(try decode(#"{"compound":240,"accessory":0}"#),
                       RestDefaults(compound: 240, accessory: 60))
    }

    func testNonFiniteNumbersInStoredDataFallBackWhenDecoded() throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let json = #"{"compound":"nan","accessory":"inf"}"#
        XCTAssertEqual(try decoder.decode(RestDefaults.self, from: Data(json.utf8)), .standard)
    }
}
