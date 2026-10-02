import XCTest
@testable import WeightTrainingCore

/// #9's done-when: given a set history, the engine returns the correct next
/// target for each rep range in the seeded library.
final class DoubleProgressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(
        range: RepRange = RepRange(8, 12),
        required: Int = 2,
        equipment: Equipment = .dumbbell
    ) -> Exercise {
        Exercise(
            name: "Incline DB Press",
            muscles: [.primary(.chest)],
            equipment: equipment,
            progressionRule: .doubleProgression(range: range, consecutiveTopHitsRequired: required)
        )
    }

    private func sets(
        _ exercise: Exercise,
        load: Double,
        reps: [Int],
        rpe: RPE? = RPE(8)
    ) -> [SetRecord] {
        reps.enumerated().map { index, count in
            SetRecord(
                exerciseID: exercise.id, load: Load(load), reps: count, rpe: rpe,
                performedAt: now.addingTimeInterval(Double(index) * 180)
            )
        }
    }

    private func state(_ exercise: Exercise, load: Double?, reps: Int?, hits: Int = 0) -> ProgressState {
        ProgressState(
            exerciseID: exercise.id,
            targetLoad: load.map { Load($0) },
            targetReps: reps,
            consecutiveTopHits: hits
        )
    }

    // MARK: - Adding reps

    func testShortOfTheTopAddsOneRep() {
        let press = lift()
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 9),
            performed: sets(press, load: 70, reps: [9, 9, 9])
        )
        XCTAssertEqual(result.change, .addedReps(to: 10))
        XCTAssertEqual(result.state.targetLoad, Load(70))
        XCTAssertEqual(result.state.targetReps, 10)
    }

    /// The weakest set decides. Double progression promises the whole run of
    /// straight sets clears the range — advancing on the strength of set one
    /// buries every set after it.
    func testTheWeakestSetDecidesNotTheBest() {
        let press = lift()
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 10),
            performed: sets(press, load: 70, reps: [12, 10, 8])
        )
        XCTAssertEqual(result.change, .addedReps(to: 9), "8 was the weakest, so 9 is next")
    }

    func testRepGoalNeverExceedsTheTopOfTheRange() {
        let press = lift(range: RepRange(8, 12))
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 12),
            performed: sets(press, load: 70, reps: [11, 11, 11])
        )
        XCTAssertEqual(result.change, .addedReps(to: 12))
    }

    // MARK: - Earning the load jump

    func testFirstCleanTopIsBankedNotSpent() {
        let press = lift(required: 2)
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 12, hits: 0),
            performed: sets(press, load: 70, reps: [12, 12, 12])
        )
        XCTAssertEqual(result.change, .earnedTowardLoad(hits: 1, required: 2))
        XCTAssertEqual(result.state.targetLoad, Load(70), "weight holds")
        XCTAssertEqual(result.state.targetReps, 12)
        XCTAssertEqual(result.state.consecutiveTopHits, 1)
    }

    /// The done-when for the guard against a fluke session.
    func testSecondCleanTopRaisesLoadAndResetsToTheBottom() {
        let press = lift(required: 2)
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 12, hits: 1),
            performed: sets(press, load: 70, reps: [12, 12, 12])
        )
        XCTAssertEqual(result.change, .addedLoad(from: Load(70), to: Load(75)))
        XCTAssertEqual(result.state.targetLoad, Load(75), "the next dumbbell up")
        XCTAssertEqual(result.state.targetReps, 8, "back to the bottom of the range")
        XCTAssertEqual(result.state.consecutiveTopHits, 0, "banked hits are spent")
    }

    func testLoadRisesByTheExercisesRealIncrement() {
        let barbell = lift(required: 1, equipment: .barbell)
        let result = ProgressionEngine.advance(
            exercise: barbell,
            state: state(barbell, load: 135, reps: 12),
            performed: sets(barbell, load: 135, reps: [12, 12])
        )
        XCTAssertEqual(result.change, .addedLoad(from: Load(135), to: Load(140)), "5 lb, not 10")
    }

    /// Hitting the top at RPE 9.5 is not the same as earning it. The hit isn't
    /// banked, and the weight repeats.
    func testTopHitAboveTargetRPEIsNotBanked() {
        let press = lift()
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 12, hits: 1),
            performed: sets(press, load: 70, reps: [12, 12, 12], rpe: RPE(9.5))
        )
        XCTAssertEqual(result.change, .heldForEffort(rpe: RPE(9.5)!))
        XCTAssertEqual(result.state.targetLoad, Load(70))
        XCTAssertEqual(result.state.consecutiveTopHits, 0, "the banked hit is lost")
    }

    /// One overreaching set is enough to disqualify the session — the promise
    /// is that every set cleared the range at the target effort.
    func testASingleOverreachingSetDisqualifiesTheHit() {
        let press = lift()
        let performed = [
            SetRecord(exerciseID: press.id, load: Load(70), reps: 12, rpe: RPE(8), performedAt: now),
            SetRecord(exerciseID: press.id, load: Load(70), reps: 12, rpe: RPE(9.5),
                      performedAt: now.addingTimeInterval(180)),
        ]
        let result = ProgressionEngine.advance(
            exercise: press, state: state(press, load: 70, reps: 12), performed: performed
        )
        XCTAssertEqual(result.change, .heldForEffort(rpe: RPE(9.5)!))
    }

    func testSetsWithoutRPEStillCountAsCleanHits() {
        let press = lift(required: 1)
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 70, reps: 12),
            performed: sets(press, load: 70, reps: [12, 12], rpe: nil)
        )
        XCTAssertEqual(result.change, .addedLoad(from: Load(70), to: Load(75)),
                       "absent RPE is not evidence of overreach")
    }

    // MARK: - Missing the range

    func testFallingBelowTheRangeHoldsAndCountsAStall() {
        let press = lift()
        let result = ProgressionEngine.advance(
            exercise: press,
            state: state(press, load: 80, reps: 8),
            performed: sets(press, load: 80, reps: [7, 6, 5])
        )
        XCTAssertEqual(result.change, .heldAfterMiss(reps: 5))
        XCTAssertEqual(result.state.targetLoad, Load(80), "weight holds")
        XCTAssertEqual(result.state.targetReps, 8, "rebuild from the bottom")
        XCTAssertEqual(result.state.stallCount, 1)
    }

    func testStallsAccumulate() {
        let press = lift()
        var current = state(press, load: 80, reps: 8)
        for _ in 0..<3 {
            current = ProgressionEngine.advance(
                exercise: press, state: current, performed: sets(press, load: 80, reps: [6])
            ).state
        }
        XCTAssertEqual(current.stallCount, 3, "#13 reads this to propose a deload")
    }

    func testASuccessfulSessionClearsTheStallCount() {
        let press = lift()
        let stalled = ProgressState(exerciseID: press.id, targetLoad: Load(80),
                                    targetReps: 8, stallCount: 2)
        let result = ProgressionEngine.advance(
            exercise: press, state: stalled, performed: sets(press, load: 80, reps: [9, 9])
        )
        XCTAssertEqual(result.state.stallCount, 0)
    }

    // MARK: - Cold start and edges

    func testColdStartTakesItsBaselineFromWhatWasPerformed() {
        let press = lift()
        let cold = ProgressState(exerciseID: press.id)
        XCTAssertTrue(cold.isColdStart)

        let result = ProgressionEngine.advance(
            exercise: press, state: cold, performed: sets(press, load: 65, reps: [10, 10])
        )
        XCTAssertEqual(result.state.targetLoad, Load(65))
        XCTAssertEqual(result.state.targetReps, 11)
        XCTAssertFalse(result.state.isColdStart, "the second session has a target")
    }

    func testWarmupsAreIgnored() {
        let press = lift()
        let performed = [
            SetRecord(exerciseID: press.id, load: Load(45), reps: 5, isWarmup: true, performedAt: now),
            SetRecord(exerciseID: press.id, load: Load(70), reps: 10, rpe: RPE(8),
                      performedAt: now.addingTimeInterval(120)),
        ]
        let result = ProgressionEngine.advance(
            exercise: press, state: state(press, load: 70, reps: 10), performed: performed
        )
        XCTAssertEqual(result.change, .addedReps(to: 11),
                       "the 45 lb warmup must not become the reference load")
        XCTAssertEqual(result.state.targetLoad, Load(70))
    }

    func testNothingLoggedChangesNothing() {
        let press = lift()
        let before = state(press, load: 70, reps: 10, hits: 1)
        let result = ProgressionEngine.advance(exercise: press, state: before, performed: [])
        XCTAssertEqual(result.change, .noWorkingSets)
        XCTAssertEqual(result.state, before, "state is untouched")
    }

    func testADroppedFinalSetCannotLowerTheTarget() {
        let press = lift()
        let performed = [
            SetRecord(exerciseID: press.id, load: Load(70), reps: 10, rpe: RPE(8), performedAt: now),
            SetRecord(exerciseID: press.id, load: Load(50), reps: 12, rpe: RPE(8),
                      performedAt: now.addingTimeInterval(180)),
        ]
        let result = ProgressionEngine.advance(
            exercise: press, state: state(press, load: 70, reps: 10), performed: performed
        )
        XCTAssertEqual(result.state.targetLoad, Load(70), "heaviest set is the reference")
    }

    // MARK: - A rack that cannot make the increment (#241)

    /// A barbell in a gym, the way the app places one: the gym's plates on the
    /// loading, the increment re-marked only while it is still the default.
    private func barbell(in gym: GymConfig, required: Int = 1) -> Exercise {
        var bar = lift(required: required, equipment: .barbell)
        if let loading = bar.loading { bar.loading = gym.applied(to: loading) }
        bar.increment = gym.applied(to: bar.increment, for: .barbell)
        return bar
    }

    private func earn(_ exercise: Exercise, at load: Load) -> ProgressionResult {
        let performed = (0..<3).map { index in
            SetRecord(exerciseID: exercise.id, load: load, reps: 12, rpe: RPE(8),
                      performedAt: now.addingTimeInterval(Double(index) * 180))
        }
        let before = ProgressState(exerciseID: exercise.id, targetLoad: load, targetReps: 12)
        return ProgressionEngine.advance(exercise: exercise, state: before, performed: performed)
    }

    /// Without 2.5 lb plates, 135 + 5 = 140 is a load no plates make. The
    /// engine stored it and said "Earned it: 135 → 140"; the screen snapped it
    /// back to 135, and the lift looped on the rep ladder forever. The raise
    /// has to be the next load the rack can actually build, and the sentence
    /// has to name the number the screen will show.
    func testARackWithoutTwoAndAHalvesRaisesToTheNextBuildableLoad() {
        let row = barbell(in: GymConfig(unit: .pounds, availablePlates: [45, 35, 25, 10, 5]))
        let result = earn(row, at: Load(135))

        XCTAssertEqual(result.change, .addedLoad(from: Load(135), to: Load(145)))
        XCTAssertTrue(row.canBuild(result.state.targetLoad!), "the rack can build the raise")
        XCTAssertEqual(Prescription(exercise: row, state: result.state).load, Load(145),
                       "the screen shows the load the sentence names")
        XCTAssertEqual(result.summary(in: .pounds), "Earned it: 135 lb → 145 lb")
    }

    /// The same loop in kilograms: without 1.25 kg plates the bar moves 5 kg.
    func testAKilogramRackWithoutItsSmallestPlateRaisesByWhatItCanBuild() {
        let row = barbell(in: GymConfig(unit: .kilograms,
                                        availablePlates: [25, 20, 15, 10, 5, 2.5]))
        let result = earn(row, at: Load(60, .kilograms))

        XCTAssertEqual(result.change, .addedLoad(from: Load(60, .kilograms), to: Load(65, .kilograms)))
        XCTAssertEqual(Prescription(exercise: row, state: result.state).load, Load(65, .kilograms))
        XCTAssertEqual(result.summary(in: .kilograms), "Earned it: 60 kg → 65 kg")
    }

    /// A rack that can make the increment still takes it: the fix is a floor
    /// under the step, not a bigger step.
    func testAFullRackStillStepsByTheIncrement() {
        let row = barbell(in: GymConfig(unit: .pounds))
        XCTAssertEqual(earn(row, at: Load(135)).change,
                       .addedLoad(from: Load(135), to: Load(140)))

        let kgRow = barbell(in: GymConfig(unit: .kilograms))
        XCTAssertEqual(earn(kgRow, at: Load(60, .kilograms)).change,
                       .addedLoad(from: Load(60, .kilograms), to: Load(62.5, .kilograms)))
    }

    /// The reason the echo is gentle: a rack having 52s is likelier than the
    /// set being imaginary. An odd dumbbell weight is held and raised as
    /// logged, not rounded onto the increment's grid.
    func testAnOddDumbbellIsStillEchoedAndRaisedAsLogged() {
        let press = lift(required: 1)
        let held = ProgressionEngine.advance(
            exercise: press, state: state(press, load: 52, reps: 10),
            performed: sets(press, load: 52, reps: [10, 10, 10])
        )
        XCTAssertEqual(held.state.targetLoad, Load(52), "held as logged")

        let raised = earn(press, at: Load(52))
        XCTAssertEqual(raised.change, .addedLoad(from: Load(52), to: Load(57)),
                       "one increment above what was lifted, not snapped to 55")
    }

    // MARK: - Across the library's rep ranges

    /// The done-when, checked against the real seeded ranges rather than
    /// invented ones: 8-12, 10-15, 12-20, 10-20.
    func testEachLibraryRepRangeAdvancesCorrectly() {
        for exercise in ExerciseLibrary.all {
            guard case .doubleProgression(let range, let required) = exercise.progressionRule else { continue }

            // At the top, cleanly, with the jump already earned.
            let atTop = ProgressState(exerciseID: exercise.id, targetLoad: Load(100),
                                      targetReps: range.top, consecutiveTopHits: required - 1)
            let performed = [SetRecord(exerciseID: exercise.id, load: Load(100),
                                       reps: range.top, rpe: RPE(8), performedAt: now)]
            let raised = ProgressionEngine.advance(exercise: exercise, state: atTop, performed: performed)

            XCTAssertEqual(
                raised.state.targetLoad,
                Load(100 + exercise.increment.pounds),
                "\(exercise.name) should add one increment"
            )
            XCTAssertEqual(raised.state.targetReps, range.bottom,
                           "\(exercise.name) resets to the bottom of \(range.bottom)-\(range.top)")

            // One short of the top.
            let below = ProgressState(exerciseID: exercise.id, targetLoad: Load(100),
                                      targetReps: range.top - 1)
            let shortSets = [SetRecord(exerciseID: exercise.id, load: Load(100),
                                       reps: range.top - 1, rpe: RPE(8), performedAt: now)]
            let stepped = ProgressionEngine.advance(exercise: exercise, state: below, performed: shortSets)
            XCTAssertEqual(stepped.state.targetReps, range.top, "\(exercise.name) steps to the top")
            XCTAssertEqual(stepped.state.targetLoad, Load(100), "\(exercise.name) holds weight")
        }
    }
}

/// #10's done-when: bench at 185×5 @ RPE 6.5 against a target of 8 proposes 195.
final class RPETargetedLoadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func bench(reps: Int = 5, target: RPE = .eight) -> Exercise {
        Exercise(
            name: "Flat Bench",
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: reps, targetRPE: target)
        )
    }

    private func set(_ exercise: Exercise, _ load: Double, _ reps: Int, _ rpe: RPE?) -> SetRecord {
        SetRecord(exerciseID: exercise.id, load: Load(load), reps: reps, rpe: rpe, performedAt: now)
    }

    /// The issue's worked example, verbatim.
    func testEasyBenchProposesMoreWeight() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(185)),
            performed: [set(lift, 185, 5, RPE(6.5))]
        )
        XCTAssertEqual(result.state.targetLoad, Load(195))
        XCTAssertEqual(result.change, .adjustedLoad(from: Load(185), to: Load(195), rpeDelta: 1.5))
    }

    func testHardSetProposesLessWeight() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(225)),
            performed: [set(lift, 225, 5, RPE(9.5))]
        )
        // 225 × (1 - 0.045) = 214.9, nearest 5 lb step is 215.
        XCTAssertEqual(result.state.targetLoad, Load(215))
    }

    func testOnTargetHoldsTheLoad() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(200)),
            performed: [set(lift, 200, 5, RPE(8))]
        )
        XCTAssertEqual(result.change, .onTarget(Load(200)))
        XCTAssertEqual(result.state.targetLoad, Load(200))
    }

    /// A half-point harder at a light weight rounds back to the same bar, and
    /// the engine says so rather than claiming a change it didn't make — or
    /// claiming the set was on target when it wasn't (#240).
    func testAdjustmentTooSmallToLoadHoldsWithoutClaimingOnTarget() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(95)),
            performed: [set(lift, 95, 5, RPE(8.5))]
        )
        // 95 × 0.985 = 93.6, which snaps back to 95.
        XCTAssertEqual(result.change, .heldOffTarget(Load(95), rpeDelta: -0.5))
        XCTAssertEqual(result.state.targetLoad, Load(95))
    }

    /// Nothing to steer by means hold, not guess.
    func testNoRPEHoldsTheLoad() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(185)),
            performed: [set(lift, 185, 5, nil)]
        )
        XCTAssertEqual(result.change, .noEffortReported)
        XCTAssertEqual(result.state.targetLoad, Load(185))
    }

    func testProposalIsAlwaysAnAchievableLoad() {
        let lift = bench()
        for rpe in RPE.sessionChips {
            let result = ProgressionEngine.advance(
                exercise: lift,
                state: ProgressState(exerciseID: lift.id, targetLoad: Load(187.5)),
                performed: [set(lift, 187.5, 5, rpe)]
            )
            let pounds = result.state.targetLoad?.pounds ?? 0
            XCTAssertEqual(pounds.truncatingRemainder(dividingBy: 5), 0,
                           "\(rpe) proposed \(pounds), which no bar can make")
        }
    }

    func testRepTargetComesFromTheRule() {
        let lift = bench(reps: 6)
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(185)),
            performed: [set(lift, 185, 6, RPE(8))]
        )
        XCTAssertEqual(result.state.targetReps, 6)
        XCTAssertEqual(result.state.targetRPE, .eight)
    }

    func testSteersByTheHeaviestScoredSet() {
        let lift = bench()
        let performed = [
            set(lift, 185, 5, RPE(6.5)),
            SetRecord(exerciseID: lift.id, load: Load(135), reps: 8, rpe: RPE(9),
                      performedAt: now.addingTimeInterval(300)),
        ]
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(185)),
            performed: performed
        )
        XCTAssertEqual(result.state.targetLoad, Load(195),
                       "the back-off set must not steer the top set")
    }
}

/// #240: an RPE-targeted lift that reports easier than target has to get
/// heavier, whatever the smallest step the rack can make.
///
/// 3% per RPE point is ~2.3 lb on a 75 lb bench and ~2.4 kg on an 80 kg one.
/// Once that is under half the smallest buildable step, `nearestAchievable`
/// snaps it straight back to the weight just lifted — and the chip said
/// "On target — stay at 80 kg" to a lifter who had just reported RPE 7 against
/// a target of 8. Every session, forever. A kg gym without 1.25s stalls an
/// 80 kg bench permanently, and nothing in the evals could see it.
final class CoarseStepRPETests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// A library lift placed in a gym the way the app places one.
    private func lift(_ name: String, in gym: GymConfig) -> Exercise {
        var lift = ExerciseLibrary.all.first { $0.name == name }!
        if let loading = lift.loading { lift.loading = gym.applied(to: loading) }
        lift.increment = gym.applied(to: lift.increment, for: lift.equipment)
        return lift
    }

    private func advance(_ lift: Exercise, at load: Load, rpe: Double) -> ProgressionResult {
        let reps = lift.progressionRule.displayRepTarget
        let performed = (0..<3).map { index in
            SetRecord(exerciseID: lift.id, load: load, reps: reps, rpe: RPE(rpe),
                      performedAt: now.addingTimeInterval(Double(index) * 180))
        }
        return ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: load, targetReps: reps),
            performed: performed
        )
    }

    private let lbStandard = GymConfig(unit: .pounds)
    private let kgStandard = GymConfig(unit: .kilograms)
    private let lbNoTwoAndAHalves = GymConfig(unit: .pounds, availablePlates: [45, 35, 25, 10, 5])
    private let kgNoFractionals = GymConfig(unit: .kilograms,
                                            availablePlates: [25, 20, 15, 10, 5, 2.5])

    /// The issue's table, one row each: a point easier than target moves the
    /// bar by the smallest step the rack can build, and says so.
    func testAnEasySetBelowTheRoundingThresholdStillMovesUpOneBuildableStep() {
        let rows: [(String, GymConfig, Load, Load)] = [
            ("Flat Bench", lbStandard, Load(75), Load(80)),
            ("Flat Bench", kgStandard, Load(40, .kilograms), Load(42.5, .kilograms)),
            ("Flat Bench", lbNoTwoAndAHalves, Load(155), Load(165)),
            ("Flat Bench", kgNoFractionals, Load(80, .kilograms), Load(85, .kilograms)),
            ("RDL", kgNoFractionals, Load(70, .kilograms), Load(75, .kilograms)),
        ]
        for (name, gym, from, to) in rows {
            let bar = lift(name, in: gym)
            let result = advance(bar, at: from, rpe: 7)
            let context = "\(name) at \(from.formatted(in: gym.unit))"

            XCTAssertEqual(result.change, .adjustedLoad(from: from, to: to, rpeDelta: 1), context)
            XCTAssertEqual(result.state.targetLoad, to, context)
            XCTAssertTrue(bar.canBuild(to), "\(context): the rack can build the raise")
            XCTAssertEqual(Prescription(exercise: bar, state: result.state).load, to,
                           "\(context): the screen shows the load the sentence names")
        }
    }

    /// Half a point easier is still easier: at a light weight it takes one step
    /// rather than claiming to be on target.
    func testHalfAPointEasierAtALightLoadIsNotOnTarget() {
        let bar = lift("Flat Bench", in: lbStandard)
        let result = advance(bar, at: Load(95), rpe: 7.5)
        XCTAssertEqual(result.change, .adjustedLoad(from: Load(95), to: Load(100), rpeDelta: 0.5))
    }

    /// An unmeasured sled has no plates to read, so its step is the increment —
    /// and still a real step, rather than a stall.
    func testAnUnmeasuredSledStepsByItsIncrement() {
        let sled = lift("Hack Squat", in: lbStandard)
        let result = advance(sled, at: Load(50), rpe: 7)
        XCTAssertEqual(result.change, .adjustedLoad(from: Load(50), to: Load(55), rpeDelta: 1))
        XCTAssertTrue(sled.canBuild(Load(55)))
    }

    /// Where 3% already clears a step, the rule is unchanged — the floor under
    /// the step is not a bigger step.
    func testAHeavyLiftStillMovesByThreePercent() {
        let bar = lift("Flat Bench", in: lbStandard)
        XCTAssertEqual(advance(bar, at: Load(185), rpe: 6.5).change,
                       .adjustedLoad(from: Load(185), to: Load(195), rpeDelta: 1.5))
        XCTAssertEqual(advance(bar, at: Load(185), rpe: 7).change,
                       .adjustedLoad(from: Load(185), to: Load(190), rpeDelta: 1))
    }

    /// "On target" is a claim about effort. A set half a point harder than
    /// target that rounds back to the same bar holds — harder-than-target
    /// symmetry is out of scope — but it must not say it was on target.
    func testAHoldOffTargetDoesNotClaimToBeOnTarget() {
        let bar = lift("Flat Bench", in: lbStandard)
        let result = advance(bar, at: Load(95), rpe: 8.5)

        XCTAssertEqual(result.state.targetLoad, Load(95), "the load holds, as before")
        XCTAssertEqual(result.change, .heldOffTarget(Load(95), rpeDelta: -0.5))
        XCTAssertFalse(result.summary.hasPrefix("On target"), result.summary)
        XCTAssertEqual(result.summary, "0.5 RPE harder than target — under one step, stay at 95 lb")
    }

    /// Reported exactly on target still says so.
    func testOnTargetStillSaysOnTarget() {
        let bar = lift("Flat Bench", in: kgNoFractionals)
        let result = advance(bar, at: Load(80, .kilograms), rpe: 8)
        XCTAssertEqual(result.change, .onTarget(Load(80, .kilograms)))
        XCTAssertEqual(result.summary(in: .kilograms), "On target — stay at 80 kg")
    }
}
