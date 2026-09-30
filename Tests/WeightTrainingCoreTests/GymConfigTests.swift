import XCTest
@testable import WeightTrainingCore

/// The gym as one object: unit, rack, bar (#73, #67).
///
/// The claim under test is that describing the room once is enough — a rack
/// change reaches every lift that never disagreed, and never touches one that
/// did.
final class GymConfigTests: XCTestCase {

    // MARK: - What a gym is

    func testTheDefaultGymIsTheOneTheAppAlreadyHad() {
        let gym = GymConfig.standard
        XCTAssertEqual(gym.unit, .pounds)
        XCTAssertEqual(gym.availablePlates, [45, 35, 25, 10, 5, 2.5])
        XCTAssertEqual(gym.barWeight, Load(45))
        XCTAssertEqual(gym.weeklySessionTarget, 3)
    }

    /// The kg gym is chosen, not converted: a 20 kg bar, not 20.41.
    func testAKilogramGymHasKilogramEquipment() {
        let gym = GymConfig.standard(in: .kilograms)
        XCTAssertEqual(gym.availablePlates, [25, 20, 15, 10, 5, 2.5, 1.25])
        XCTAssertEqual(gym.barWeight.value(in: .kilograms), 20, accuracy: 0.0001)
    }

    /// Some racks have a 15 kg bar. The bar is per-gym, not per-unit.
    func testAGymCanHaveItsOwnBar() {
        let gym = GymConfig(unit: .kilograms, barWeight: Load(15, .kilograms))
        XCTAssertEqual(gym.barWeight.value(in: .kilograms), 15, accuracy: 0.0001)
        XCTAssertEqual(gym.inheritedLoading().minimumLoad.value(in: .kilograms), 15,
                       accuracy: 0.0001)
    }

    func testInheritedLoadingBuildsInTheGymsOwnUnit() throws {
        let gym = GymConfig.standard(in: .kilograms)
        let loading = gym.inheritedLoading()
        // 20 kg bar + 40 kg a side = 100 kg, off a kg rack.
        let breakdown = try XCTUnwrap(loading.breakdown(for: Load(100, .kilograms)))
        XCTAssertEqual(breakdown.perSide.map(\.plate), [25, 15])
    }

    // MARK: - Propagation (#73)

    func testChangingTheRackReachesALiftThatNeverDisagreed() {
        let lift = LoadingStyle.olympicBarbell
        XCTAssertTrue(lift.usesGymRack)

        let gym = GymConfig.standard(in: .kilograms)
        let updated = gym.applied(to: lift)

        XCTAssertEqual(updated.unit, .kilograms)
        XCTAssertEqual(updated.availablePlates, [25, 20, 15, 10, 5, 2.5, 1.25])
        XCTAssertEqual(updated.baseWeight?.value(in: .kilograms) ?? 0, 20, accuracy: 0.0001)
    }

    /// The whole point of keeping the per-exercise override (#39).
    func testChangingTheRackLeavesAConfiguredLiftAlone() {
        // A machine that only takes 25s, described by hand.
        let machine = LoadingStyle(
            baseWeight: Load(60), sleeves: 1,
            availablePlates: [25], usesGymRack: false
        )
        let updated = GymConfig.standard(in: .kilograms).applied(to: machine)
        XCTAssertEqual(updated, machine)
    }

    /// A measured lever weight is a fact about the machine, not about the room.
    /// Switching the gym to kg must not claim the T-bar now weighs 20 kg.
    func testAMeasuredBaseWeightSurvivesAUnitChange() {
        let tbar = LoadingStyle(baseWeight: Load(62), sleeves: 1)
        let updated = GymConfig.standard(in: .kilograms).applied(to: tbar)

        XCTAssertEqual(updated.unit, .kilograms, "the rack still becomes the gym's")
        XCTAssertEqual(updated.baseWeight, Load(62), "but what it weighs is unchanged")
    }

    /// #242. The Settings stepper saves on every tap, so 45 → 35 arrives as
    /// two gym changes. Recognising a follower only by "still reads the
    /// standard bar" let the first tap re-rack it and the second tap mistake
    /// that 40 for a measurement — every barbell stayed on 40, and the plate
    /// line under a 135 read "45 · 2.5 per side", 5 lb out on the real bar.
    func testABarFollowsTheGymAcrossEveryStep() {
        for (unit, steps) in [
            (MassUnit.pounds, [45.0, 40, 35, 40, 45]),
            (.kilograms, [20.0, 17.5, 15, 17.5, 20]),
        ] {
            var gym = GymConfig.standard(in: unit)
            var bar = gym.inheritedLoading()
            for value in steps.dropFirst() {
                let previous = gym
                gym.barWeight = Load(value, unit)
                bar = gym.applied(to: bar, replacing: previous)
                XCTAssertEqual(
                    bar.baseWeight, gym.barWeight,
                    "\(unit): after stepping to \(value) the bar should be the gym's"
                )
            }
        }
    }

    /// The other half of #242: following the gym's bar across steps must not
    /// turn into overwriting a lever somebody weighed.
    func testAMeasuredBaseSurvivesEveryBarStep() {
        var gym = GymConfig.standard
        var tbar = LoadingStyle(baseWeight: Load(62), sleeves: 1)
        for value in [40.0, 35, 40, 45] {
            let previous = gym
            gym.barWeight = Load(value)
            tbar = gym.applied(to: tbar, replacing: previous)
            XCTAssertEqual(tbar.baseWeight, Load(62))
        }
    }

    /// A bar that followed a 40 lb gym bar into a kg switch lands on the new
    /// gym's bar, rather than staying 40 lb in a room marked in kilograms.
    func testABarFollowsAChangedGymBarThroughAUnitSwitch() {
        var gym = GymConfig.standard
        var bar = gym.inheritedLoading()
        var previous = gym
        gym.barWeight = Load(40)
        bar = gym.applied(to: bar, replacing: previous)

        previous = gym
        gym = GymConfig.standard(in: .kilograms)
        bar = gym.applied(to: bar, replacing: previous)
        XCTAssertEqual(bar.baseWeight?.value(in: .kilograms) ?? 0, 20, accuracy: 0.0001)
    }

    func testApplyingTheSameGymTwiceChangesNothing() {
        let gym = GymConfig.standard(in: .kilograms)
        let once = gym.applied(to: LoadingStyle.olympicBarbell)
        XCTAssertEqual(gym.applied(to: once), once)
    }

    // MARK: - A base that follows the gym's bar, recorded (#270)

    /// A second device learns the gym only through sync, so it never knows
    /// the gym being replaced. A bar marked as following must land on the
    /// gym's bar whatever it was sitting on — including an intermediate
    /// stepper value that is neither a standard bar nor a known `previous`.
    func testAFollowingBarLandsOnTheGymsBarWithNoHistory() {
        let bar = LoadingStyle(baseWeight: Load(40), sleeves: 2, followsGymBar: true)
        let gym = GymConfig(unit: .pounds, barWeight: Load(35))
        let applied = gym.applied(to: bar)
        XCTAssertEqual(applied.baseWeight, Load(35))
        XCTAssertEqual(applied.followsGymBar, true)
    }

    /// The unit-switch half: a following 35 lb bar in a gym switched to kg
    /// becomes the kg gym's bar, not a 35 lb "bar" in a kilogram rack.
    func testAFollowingNonStandardBarCrossesAUnitSwitch() {
        let bar = LoadingStyle(baseWeight: Load(35), sleeves: 2, followsGymBar: true)
        let applied = GymConfig.standard(in: .kilograms).applied(to: bar)
        XCTAssertEqual(applied.unit, .kilograms)
        XCTAssertEqual(applied.baseWeight, MassUnit.kilograms.standardBar)
    }

    /// Marked as measured means kept — even when it happens to equal a
    /// standard bar, since the lifter said so.
    func testAMeasuredMarkKeepsTheBaseThroughAnyGym() {
        let lever = LoadingStyle(baseWeight: Load(45), sleeves: 1, followsGymBar: false)
        let applied = GymConfig(unit: .kilograms, barWeight: Load(15, .kilograms)).applied(to: lever)
        XCTAssertEqual(applied.baseWeight, Load(45))
        XCTAssertEqual(applied.followsGymBar, false)
    }

    /// An unmarked base (every row written before #270) is inferred once and
    /// the answer recorded: the gym's current bar, either unit's standard
    /// bar, or the replaced gym's bar mean following; anything else measured.
    func testAnUnmarkedBaseIsInferredAndRecorded() {
        let gym = GymConfig(unit: .pounds, barWeight: Load(35))
        let onGymBar = gym.applied(to: LoadingStyle(baseWeight: Load(35), sleeves: 2))
        XCTAssertEqual(onGymBar.followsGymBar, true)

        let onStandard = gym.applied(to: LoadingStyle(baseWeight: Load(45), sleeves: 2))
        XCTAssertEqual(onStandard.followsGymBar, true)
        XCTAssertEqual(onStandard.baseWeight, Load(35))

        // A pound bar stranded in a kilogram-marked rack by an older build.
        let stranded = LoadingStyle(baseWeight: Load(45), sleeves: 2, unit: .kilograms)
        let healed = GymConfig.standard(in: .kilograms).applied(to: stranded)
        XCTAssertEqual(healed.baseWeight, MassUnit.kilograms.standardBar)

        let lever = gym.applied(to: LoadingStyle(baseWeight: Load(62), sleeves: 1))
        XCTAssertEqual(lever.followsGymBar, false)
        XCTAssertEqual(lever.baseWeight, Load(62))
    }

    /// An unmeasured apparatus has no base to follow or keep; no mark.
    func testAnUnmeasuredMachineGetsNoMark() {
        let sled = GymConfig.standard(in: .kilograms).applied(to: .unmeasuredMachine(sleeves: 2))
        XCTAssertNil(sled.followsGymBar)
        XCTAssertNil(sled.baseWeight)
    }

    /// The mark rides inside the stored loading JSON, so it syncs with the
    /// row it describes. Rows written before it decode as unmarked.
    func testTheMarkSurvivesARoundTripAndOldRowsReadUnmarked() throws {
        let marked = LoadingStyle(baseWeight: Load(40), sleeves: 2, followsGymBar: true)
        let back = try JSONDecoder().decode(LoadingStyle.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(back, marked)

        let json = """
        {"sleeves":2,"availablePlates":[45,35,25,10,5,2.5],"baseWeight":{"pounds":45},"unit":"pounds","usesGymRack":true}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(LoadingStyle.self, from: json).followsGymBar)
    }

    /// What the gym hands a new lift, and the stock barbell, follow its bar.
    func testInheritedBarsAreMarkedAsFollowing() {
        XCTAssertEqual(GymConfig.standard.inheritedLoading().followsGymBar, true)
        XCTAssertEqual(LoadingStyle.olympicBarbell.followsGymBar, true)
        XCTAssertEqual(LoadingStyle.standardBarbell(in: .kilograms).followsGymBar, true)
    }

    // MARK: - Increments

    /// 5 lb is a real increment; 2.27 kg is not. A default follows the gym.
    func testADefaultIncrementIsRemarkedForTheNewGym() {
        let gym = GymConfig.standard(in: .kilograms)
        let updated = gym.applied(to: .barbell, for: .barbell)

        XCTAssertEqual(updated.unit, .kilograms)
        XCTAssertEqual(updated.nativeValue, 2.5, accuracy: 0.0001)
        XCTAssertEqual(updated.formatted, "2.5 kg")
    }

    /// A stack somebody actually measured at 15 lb (#20) is data, not a default.
    func testAMeasuredIncrementIsNotRemarked() {
        let measured = LoadIncrement(pounds: 15)
        let updated = GymConfig.standard(in: .kilograms).applied(to: measured, for: .machineStack)
        XCTAssertEqual(updated, measured)
    }

    func testEachEquipmentGetsItsOwnWorldsStep() {
        XCTAssertEqual(Equipment.barbell.defaultIncrement(in: .kilograms).nativeValue, 2.5,
                       accuracy: 0.0001)
        XCTAssertEqual(Equipment.machineStack.defaultIncrement(in: .kilograms).nativeValue, 5,
                       accuracy: 0.0001)
        // The pound defaults are exactly what they always were.
        XCTAssertEqual(Equipment.barbell.defaultIncrement(in: .pounds), .barbell)
        XCTAssertEqual(Equipment.machineStack.defaultIncrement(in: .pounds), .stackDefault)
    }

    // MARK: - Reading rows written before any of this existed

    /// The migration-free path: a stored style with no `usesGymRack` and the
    /// plain pound rack is indistinguishable from never having been configured.
    func testALegacyStandardRackFollowsTheGym() throws {
        let json = """
        {"sleeves":2,"availablePlates":[45,35,25,10,5,2.5],
         "baseWeight":{"pounds":45}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoadingStyle.self, from: json)

        XCTAssertTrue(decoded.usesGymRack)
        XCTAssertEqual(decoded.unit, .pounds)
    }

    /// And anything unusual is assumed deliberate, because overwriting a
    /// configured rack is the one unrecoverable mistake here.
    func testALegacyCustomRackIsLeftAlone() throws {
        let json = """
        {"sleeves":1,"availablePlates":[25,10],"baseWeight":{"pounds":60}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoadingStyle.self, from: json)

        XCTAssertFalse(decoded.usesGymRack)
        XCTAssertEqual(GymConfig.standard(in: .kilograms).applied(to: decoded), decoded)
    }

    func testAGymConfigSurvivesARoundTrip() throws {
        let gym = GymConfig(unit: .kilograms, availablePlates: [25, 20, 10], barWeight: Load(15, .kilograms))
        let data = try JSONEncoder().encode(gym)
        XCTAssertEqual(try JSONDecoder().decode(GymConfig.self, from: data), gym)
    }

    func testAnEmptyGymRecordReadsAsThePoundGym() throws {
        let decoded = try JSONDecoder().decode(GymConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(decoded, .standard)
    }

    func testWeeklyTargetSurvivesARoundTrip() throws {
        let gym = GymConfig(weeklySessionTarget: 4)
        let data = try JSONEncoder().encode(gym)
        XCTAssertEqual(try JSONDecoder().decode(GymConfig.self, from: data).weeklySessionTarget, 4)
    }

    func testLegacyConfigDefaultsToThreeTrainingDays() throws {
        let json = """
        {"unit":"pounds","availablePlates":[45,25,10,5,2.5],
         "barWeight":{"pounds":45}}
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(GymConfig.self, from: json).weeklySessionTarget, 3)
    }

    func testWeeklyTargetIsKeptInsideARealCalendarWeek() {
        XCTAssertEqual(GymConfig(weeklySessionTarget: 0).weeklySessionTarget, 1)
        XCTAssertEqual(GymConfig(weeklySessionTarget: 9).weeklySessionTarget, 7)
    }

    // MARK: - Training split (#136)

    /// Nil is "nobody has picked yet", not "picked push/pull/legs" — a row
    /// from before #136 has to land here, not be silently defaulted onto a
    /// choice the person never made.
    func testANewGymHasNoSplitUntilOneIsChosen() {
        XCTAssertNil(GymConfig.standard.trainingSplit)
    }

    /// `effectiveTrainingSplit` is what every reader beyond the picker itself
    /// should call — it's what keeps "nobody has picked" behaving exactly as
    /// it always did (push/pull/legs) everywhere except the one screen that
    /// needs to know the difference.
    func testEffectiveSplitFallsBackToPushPullLegsWhenUnset() {
        let split = GymConfig.standard.effectiveTrainingSplit
        XCTAssertEqual(split.kind, .pushPullLegs)
        XCTAssertEqual(split.days.map(\.kind), [.push, .pull, .legs])
    }

    /// An empty custom split — chosen but not yet given any days — is exactly
    /// as unusable as no split at all, and must fall back the same way rather
    /// than handing `CycleEngine` a rotation with nothing in it.
    func testEffectiveSplitFallsBackWhenTheChosenSplitHasNoDays() {
        var gym = GymConfig.standard
        gym.trainingSplit = TrainingSplit(kind: .custom, days: [])
        XCTAssertEqual(gym.effectiveTrainingSplit.kind, .pushPullLegs)
    }

    func testAChosenSplitSurvivesARoundTrip() throws {
        var gym = GymConfig.standard
        gym.trainingSplit = DayTemplateLibrary.split(
            .upperLower, startedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(gym)
        let decoded = try JSONDecoder().decode(GymConfig.self, from: data)
        XCTAssertEqual(decoded.trainingSplit, gym.trainingSplit)
    }
}
