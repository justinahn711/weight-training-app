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
        XCTAssertEqual(result.change, .addedLoad(from: Load(70), to: Load(80)))
        XCTAssertEqual(result.state.targetLoad, Load(80), "one dumbbell increment")
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
        XCTAssertEqual(result.change, .addedLoad(from: Load(70), to: Load(80)),
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

    /// A half-point off at a light weight rounds back to the same bar, and the
    /// engine says so rather than claiming a change it didn't make.
    func testAdjustmentTooSmallToLoadReportsOnTarget() {
        let lift = bench()
        let result = ProgressionEngine.advance(
            exercise: lift,
            state: ProgressState(exerciseID: lift.id, targetLoad: Load(95)),
            performed: [set(lift, 95, 5, RPE(8.5))]
        )
        // 95 × 0.985 = 93.6, which snaps back to 95.
        XCTAssertEqual(result.change, .onTarget(Load(95)))
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
