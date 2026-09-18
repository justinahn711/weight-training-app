import XCTest
@testable import WeightTrainingCore

final class RecommendationEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_011_200)

    private func exercise(equipment: Equipment = .barbell) -> Exercise {
        Exercise(name: "Press", muscles: [.primary(.chest), .secondary(.triceps)],
                 equipment: equipment,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    private func plan(_ lift: Exercise, load: Load = 100, reps: [Int] = [10, 10, 9]) -> ExercisePlan {
        ExercisePlan(exercise: lift, sets: reps.map { PlannedWorkingSet(load: load, reps: $0) })
    }

    private func exposure(
        _ plan: ExercisePlan, daysAgo: Double, reps: [Int]? = nil,
        effort: [RPE?]? = nil, source: ExposureSet.EffortSource = .reported,
        completion: ExerciseExposure.Completion = .completed
    ) -> ExerciseExposure {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        let counts = reps ?? plan.sets.map(\.reps)
        let sets = counts.enumerated().map { index, count in
            ExposureSet(record: SetRecord(
                exerciseID: plan.exercise.id, load: plan.sets[min(index, plan.sets.count - 1)].load,
                reps: count, rpe: effort?[index] ?? .seven,
                performedAt: date.addingTimeInterval(Double(index) * 180)
            ), effortSource: source)
        }
        return ExerciseExposure(id: UUID(), exerciseID: plan.exercise.id, plan: plan,
                                sets: sets, completion: completion,
                                completedAt: date.addingTimeInterval(1_800))
    }

    private func recommend(
        _ plan: ExercisePlan, _ history: [ExerciseExposure],
        policy: RecommendationPolicy = RecommendationPolicy(),
        context: RecommendationContext = RecommendationContext()
    ) -> ExerciseRecommendation {
        RecommendationEngine.recommend(exercise: plan.exercise, plan: plan, history: history,
                                       policy: policy, context: context, now: now)
    }

    func testTwoEasyWorkoutsAddOnlyOneRepToLowestTargetSet() {
        let target = plan(exercise())
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        let result = recommend(target, history)
        XCTAssertEqual(result.action, .addReps)
        XCTAssertEqual(result.sets.map(\.reps), [10, 10, 10])
        XCTAssertEqual(result.sets.map(\.load), [100, 100, 100])
        XCTAssertEqual(result.reason, .addedRep(set: 3))
        XCTAssertEqual(result.supportingExposureIDs, history.map(\.id))
        XCTAssertEqual(result.evidence, .consistent)
        XCTAssertEqual(result.suggestedSetCount, 3)
    }

    func testRepTiesPreferEarlierSets() {
        let target = plan(exercise(), reps: [10, 10, 10])
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
            .sets.map(\.reps), [11, 10, 10])
    }

    func testSingleEasyWorkoutCannotIncreaseAnything() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .hold)
        XCTAssertEqual(result.reason, .confirmEasyWorkouts(completed: 1, required: 2))
        XCTAssertEqual(result.sets, target.sets)
    }

    func testHardFinalSetCannotHideBehindEasyAverage() {
        let target = plan(exercise(), reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4),
            exposure(target, daysAgo: 2, effort: [.six, .six, .nine])])
        XCTAssertEqual(result.reason, .effortAboveTarget)
        XCTAssertEqual(result.action, .hold)
    }

    func testTwoCeilingWorkoutsIncreaseRealLoadAndResetReps() {
        let target = plan(exercise(), reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .addLoad)
        XCTAssertEqual(result.sets.map(\.load), [105, 105, 105])
        XCTAssertEqual(result.sets.map(\.reps), [8, 8, 8])
    }

    func testCoarseDumbbellStepHoldsInsteadOfInventingWeight() {
        let target = plan(exercise(equipment: .dumbbell), load: 30, reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.reason, .loadStepTooLarge)
        XCTAssertEqual(result.sets, target.sets)
    }

    func testMeasuredPlatesWinOverScalarIncrement() {
        var lift = exercise()
        lift.increment = LoadIncrement(pounds: 1)
        lift.loading = LoadingStyle(baseWeight: 45, sleeves: 2, availablePlates: [10])
        let target = plan(lift, load: 405, reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .addLoad)
        XCTAssertEqual(result.sets.first?.load, Load(425))
        XCTAssertTrue(result.sets.allSatisfy { lift.canBuild($0.load) })
    }

    func testKilogramRackKeepsNativeIncrement() {
        var lift = exercise()
        lift.increment = LoadIncrement(2.5, .kilograms)
        lift.loading = .standardBarbell(in: .kilograms)
        let target = plan(lift, load: Load(100, .kilograms), reps: [12, 12, 12])
        let result = recommend(target, [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.action, .addLoad)
        XCTAssertEqual(result.sets[0].load.value(in: .kilograms), 102.5, accuracy: 0.000_001)
    }

    func testMissingAndPrefilledEffortNeverEarnProgression() {
        let target = plan(exercise())
        var missing = exposure(target, daysAgo: 2)
        missing.sets[2].record.rpe = nil
        for latest in [missing, exposure(target, daysAgo: 2, source: .unknown)] {
            let result = recommend(target, [exposure(target, daysAgo: 4), latest])
            XCTAssertEqual(result.action, .hold)
            XCTAssertEqual(result.reason, .missingEffort)
        }
    }

    func testPartialOrUnconfirmedWorkoutDoesNotCountAsSuccess() {
        let target = plan(exercise())
        let candidates = [
            exposure(target, daysAgo: 2, reps: [10]),
            exposure(target, daysAgo: 2, completion: .shortenedForTime),
            exposure(target, daysAgo: 2, completion: .unknown),
            exposure(target, daysAgo: 2, completion: .stoppedForFatigue)
        ]
        for latest in candidates {
            XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), latest]).reason, .incompleteExposure)
        }
    }

    func testWarmupsNeverFillMissingWorkingSets() {
        let target = plan(exercise())
        var latest = exposure(target, daysAgo: 2)
        latest.sets[0].record.isWarmup = true
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), latest]).reason, .incompleteExposure)
    }

    func testExtraWorkingSetRequiresNewPlanRatherThanSilentlyIgnoringFatigue() {
        let target = plan(exercise())
        let latest = exposure(target, daysAgo: 2, reps: [10, 10, 9, 9], effort: [.seven, .seven, .seven, .ten])
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), latest]).action, .hold)
    }

    func testInterveningMissingEffortBreaksEasyStreak() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 6),
            exposure(target, daysAgo: 4, source: .unknown), exposure(target, daysAgo: 2)])
        XCTAssertEqual(result.reason, .confirmEasyWorkouts(completed: 1, required: 2))
    }

    func testChangedPrescriptionNeedsFreshWorkouts() {
        let old = plan(exercise())
        var new = ExercisePlan(exercise: old.exercise, sets: old.sets)
        new.sets[2].reps += 1
        let result = recommend(new, [exposure(old, daysAgo: 4), exposure(new, daysAgo: 2)])
        XCTAssertEqual(result.reason, .confirmEasyWorkouts(completed: 1, required: 2))
    }

    func testResetToSameNumbersWithNewPlanIDDoesNotReuseOldSuccess() {
        let old = plan(exercise())
        let new = ExercisePlan(exercise: old.exercise, sets: old.sets)
        XCTAssertEqual(recommend(new, [exposure(old, daysAgo: 4), exposure(old, daysAgo: 2)]).reason, .newPrescription)
    }

    func testTechniqueAndRestChangesBreakComparability() {
        let target = plan(exercise())
        var changed = exposure(target, daysAgo: 2)
        changed.techniqueChanged = true
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), changed]).reason, .techniqueChanged)
        changed = exposure(target, daysAgo: 2)
        changed.plan?.restSeconds = 60
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), changed]).reason, .newPrescription)
    }

    func testChangedEquipmentDoesNotEchoOldTarget() {
        let target = plan(exercise())
        var changed = target.exercise
        changed.increment = LoadIncrement(pounds: 10)
        let result = RecommendationEngine.recommend(exercise: changed, plan: target,
            history: [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)], now: now)
        XCTAssertEqual(result.reason, .equipmentChanged)
        XCTAssertTrue(result.sets.isEmpty)
    }

    func testMixedPerformedLoadsCannotQualifyAsStraightSets() {
        let target = plan(exercise())
        var latest = exposure(target, daysAgo: 2)
        latest.sets[2].record.load = 90
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), latest]).reason, .unexpectedPerformance)
    }

    func testStaleHistoryAndGapBetweenWorkoutsBothPreventIncrease() {
        let target = plan(exercise())
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 40), exposure(target, daysAgo: 30)]).reason, .staleHistory)
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 40), exposure(target, daysAgo: 2)]).reason,
                       .confirmEasyWorkouts(completed: 1, required: 2))
    }

    func testDuplicateExposureCannotManufactureSecondWorkout() {
        let target = plan(exercise())
        let one = exposure(target, daysAgo: 2)
        XCTAssertEqual(recommend(target, [one, one]).reason, .confirmEasyWorkouts(completed: 1, required: 2))
        var conflict = one
        conflict.sets[0].record.reps = 1
        XCTAssertEqual(recommend(target, [one, conflict]).reason, .ambiguousHistory)
    }

    func testCopiedSetsAcrossSessionsCannotManufactureEvidence() {
        let target = plan(exercise())
        let one = exposure(target, daysAgo: 4)
        var two = exposure(target, daysAgo: 2)
        two.sets = one.sets
        XCTAssertEqual(recommend(target, [one, two]).reason, .ambiguousHistory)
    }

    func testCorrectionsAndDeletionsRecomputeRecommendation() {
        let target = plan(exercise())
        let first = exposure(target, daysAgo: 4)
        var latest = exposure(target, daysAgo: 2)
        XCTAssertEqual(recommend(target, [first, latest]).action, .addReps)
        latest.sets[2].record.rpe = .nine
        XCTAssertEqual(recommend(target, [first, latest]).action, .hold)
        XCTAssertEqual(recommend(target, [first]).action, .hold)
    }

    func testRecommendationIsDeterministicAndHistoryOrderIndependent() {
        let target = plan(exercise())
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        XCTAssertEqual(recommend(target, history), recommend(target, history.reversed()))
        XCTAssertEqual(recommend(target, history), recommend(target, history))
    }

    func testTwoWorkoutsOnSameDayStayDistinct() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 1.4), exposure(target, daysAgo: 1.1)])
        XCTAssertEqual(result.action, .addReps)
        XCTAssertEqual(result.supportingExposureIDs.count, 2)
    }

    func testWorkoutCrossingMidnightRemainsOneExposure() {
        let target = plan(exercise())
        var late = exposure(target, daysAgo: 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: late.completedAt)
        for index in late.sets.indices {
            late.sets[index].record.performedAt = midnight.addingTimeInterval(Double(index - 1) * 180)
        }
        late.completedAt = midnight.addingTimeInterval(600)
        XCTAssertEqual(recommend(target, [late]).reason, .confirmEasyWorkouts(completed: 1, required: 2))
    }

    func testRepeatedFullMissesProduceLocalReset() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [8, 7, 6]),
                                      exposure(target, daysAgo: 2, reps: [8, 7, 6])])
        XCTAssertEqual(result.action, .reduce)
        XCTAssertEqual(result.reason, .repeatedMisses)
        XCTAssertEqual(result.sets.map(\.load), [90, 90, 90])
    }

    func testTimeShortenedWorkoutsNeverTriggerRepeatedMissReset() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [6], completion: .shortenedForTime),
            exposure(target, daysAgo: 2, reps: [6], completion: .shortenedForTime)])
        XCTAssertEqual(result.action, .hold)
    }

    func testResetDoesNotGoBelowEmptyBar() {
        let target = plan(exercise(), load: 45)
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [6, 6, 6]),
            exposure(target, daysAgo: 2, reps: [6, 6, 6])])
        XCTAssertEqual(result.reason, .minimumLoad)
        XCTAssertEqual(result.sets.first?.load, Load(45))
    }

    func testReductionRoundingFindsBuildableWeightWithinTenPercent() {
        let target = plan(exercise(), load: 185)
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [6, 6, 6]),
            exposure(target, daysAgo: 2, reps: [6, 6, 6])])
        XCTAssertEqual(result.action, .reduce)
        XCTAssertEqual(result.sets.first?.load, Load(170), "165 would reduce more than ten percent")
    }

    func testCoarseReductionDoesNotClaimEquipmentMinimum() {
        let target = plan(exercise(equipment: .dumbbell), load: 30)
        let result = recommend(target, [exposure(target, daysAgo: 4, reps: [6, 6, 6]),
            exposure(target, daysAgo: 2, reps: [6, 6, 6])])
        XCTAssertEqual(result.action, .hold)
        XCTAssertEqual(result.reason, .reductionUnavailable)
    }

    func testEmptyCustomRackDoesNotRecommendZeroWeight() {
        var lift = exercise()
        lift.loading = LoadingStyle(baseWeight: 0, sleeves: 2, availablePlates: [])
        XCTAssertTrue(recommend(plan(lift, load: 100), []).sets.isEmpty)
    }

    func testPainAndPoorRecoveryBlockOtherwiseEarnedIncrease() {
        let target = plan(exercise())
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        XCTAssertEqual(recommend(target, history, context: .init(painReported: true)).action, .stop)
        XCTAssertEqual(recommend(target, history, context: .init(recovery: .poor)).reason, .poorRecovery)
        var latest = history[1]
        latest.completion = .stoppedForPain
        XCTAssertEqual(recommend(target, [history[0], latest]).action, .stop)
    }

    func testDeloadWorkoutsCannotEarnIncreases() {
        var target = plan(exercise())
        target.isDeload = true
        let history = [exposure(target, daysAgo: 4), exposure(target, daysAgo: 2)]
        XCTAssertEqual(recommend(target, history).action, .deload)
        target.isDeload = false
        XCTAssertEqual(recommend(target, history).reason, .resumeAfterDeload)
    }

    func testColdStartDoesNotInventWeight() {
        let result = RecommendationEngine.recommend(exercise: exercise(), plan: nil, history: [], now: now)
        XCTAssertEqual(result.action, .establish)
        XCTAssertTrue(result.sets.isEmpty)
        XCTAssertNil(result.suggestedSetCount)
    }

    func testLegacyExposureWithoutPlanIsNotAssumedComplete() {
        let target = plan(exercise())
        var legacy = exposure(target, daysAgo: 2)
        legacy.plan = nil
        XCTAssertEqual(recommend(target, [exposure(target, daysAgo: 4), legacy]).reason, .newPrescription)
    }

    func testBodyweightAndUnmeasuredApparatusDeclineGenericLoadProgression() {
        for equipment in [Equipment.bodyweight, .plateLoaded] {
            let target = plan(exercise(equipment: equipment))
            XCTAssertEqual(recommend(target, []).reason, .unsupportedEquipment)
        }
    }

    func testInvalidAndUnbuildablePlansNeverProduceInvalidLoads() {
        let lift = exercise()
        for load in [Load(.nan), Load(.infinity), Load(-5), Load(0), Load(40)] {
            XCTAssertTrue(recommend(plan(lift, load: load), []).sets.isEmpty)
        }
        let offGrid = recommend(plan(lift, load: 102), [])
        XCTAssertEqual(offGrid.reason, .equipmentChanged)
        XCTAssertEqual(offGrid.sets.first?.load, Load(100))
        XCTAssertTrue(recommend(plan(lift, reps: []), []).sets.isEmpty)
    }

    func testBadPolicyDoesNotSilentlyDisableRepeatedWorkoutGate() {
        let target = plan(exercise())
        var policy = RecommendationPolicy()
        policy.easyExposuresRequired = 1
        XCTAssertEqual(recommend(target, [], policy: policy).reason, .invalidInput)
    }

    func testFutureWorkoutsDoNotLeakIntoRecommendation() {
        let target = plan(exercise())
        let result = recommend(target, [exposure(target, daysAgo: 2), exposure(target, daysAgo: -2)])
        XCTAssertEqual(result.reason, .confirmEasyWorkouts(completed: 1, required: 2))
    }

    func testPlansAndExposureProvenanceRoundTrip() throws {
        let original = exposure(plan(exercise()), daysAgo: 2)
        let restored = try JSONDecoder().decode(ExerciseExposure.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, restored)
    }
}
