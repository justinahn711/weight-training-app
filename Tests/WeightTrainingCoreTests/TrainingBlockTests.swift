import XCTest
@testable import WeightTrainingCore

final class TrainingBlockTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private func date(_ day: Int) -> Date { date(2026, 9, day) }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func lift(_ name: String = "Press", muscle: Muscle = .chest) -> Exercise {
        Exercise(name: name, muscles: [.primary(muscle)], equipment: .dumbbell,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    private func exposure(
        _ exercise: Exercise,
        on day: Date,
        completion: ExerciseExposure.Completion = .completed,
        rpe: RPE = .eight
    ) -> ExerciseExposure {
        let targets = Array(repeating: PlannedWorkingSet(load: 100, reps: 10, rpe: .eight), count: 3)
        let plan = ExercisePlan(exercise: exercise, sets: targets)
        let sets = targets.enumerated().map { index, target in
            ExposureSet(record: SetRecord(
                exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: rpe,
                performedAt: day.addingTimeInterval(Double(index) * 60)
            ), effortSource: .reported)
        }
        return ExerciseExposure(id: UUID(), exerciseID: exercise.id, plan: plan, sets: sets,
                                completion: completion, completedAt: day.addingTimeInterval(600))
    }

    func testThreeBuildWeeksLeadToARecoveryWeek() {
        let config = TrainingBlockConfig(startedAt: date(7), accumulationWeeks: 3)
        XCTAssertEqual(TrainingBlockEngine.phase(for: config, now: date(7), calendar: calendar),
                       .accumulation(week: 1))
        XCTAssertEqual(TrainingBlockEngine.phase(for: config, now: date(21), calendar: calendar),
                       .accumulation(week: 3))
        XCTAssertEqual(TrainingBlockEngine.phase(for: config, now: date(28), calendar: calendar),
                       .deload(week: 4))
        XCTAssertEqual(TrainingBlockEngine.phase(for: config, now: date(2026, 10, 5), calendar: calendar),
                       .accumulation(week: 1))
    }

    func testDecodedConfigurationIsNormalizedAtTheDecisionBoundary() throws {
        let json = """
        {"startedAt":0,"accumulationWeeks":99,"monthlyIncrease":0.5,
         "deloadTonnageFraction":0.1}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(TrainingBlockConfig.self, from: json)
        XCTAssertEqual(config.accumulationWeeks, 6)
        XCTAssertEqual(config.monthlyIncrease, 0.10)
        XCTAssertEqual(config.deloadTonnageFraction, 0.70)
    }

    func testComparableToleratedWeeksProduceMedianBaselineAndTargets() throws {
        let press = lift()
        let config = TrainingBlockConfig(startedAt: date(21), monthlyIncrease: 0.05,
                                         deloadTonnageFraction: 0.75)
        let history = [exposure(press, on: date(9)), exposure(press, on: date(16))]
        let build = TrainingBlockEngine.status(
            config: config, history: history, now: date(21), calendar: calendar
        )
        XCTAssertEqual(build.baselineWeeks, 2)
        XCTAssertEqual(try XCTUnwrap(build.baselineTonnage), 3_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(build.targetTonnage), 3_150, accuracy: 0.001)

        let recovery = TrainingBlockEngine.status(
            config: config, history: history, now: date(2026, 10, 12), calendar: calendar
        )
        XCTAssertEqual(recovery.phase, .deload(week: 4))
        XCTAssertEqual(try XCTUnwrap(recovery.targetTonnage), 2_250, accuracy: 0.001)
    }

    func testChangedExerciseMixOrFatigueDoesNotManufactureABaseline() {
        let press = lift()
        let row = lift("Row", muscle: .lats)
        let config = TrainingBlockConfig(startedAt: date(21))
        XCTAssertNil(TrainingBlockEngine.status(
            config: config,
            history: [exposure(press, on: date(9)), exposure(row, on: date(16))],
            now: date(21), calendar: calendar
        ).baselineTonnage)
        XCTAssertNil(TrainingBlockEngine.status(
            config: config,
            history: [exposure(press, on: date(9)),
                      exposure(press, on: date(16), completion: .stoppedForFatigue)],
            now: date(21), calendar: calendar
        ).baselineTonnage)
    }

    func testRecoveryWeekProposesFewerSetsAndLowerEffortWithoutAutoAccepting() {
        let press = lift()
        let plan = ExercisePlan(exercise: press, sets: Array(repeating:
            PlannedWorkingSet(load: 100, reps: 10, rpe: .eight), count: 3))
        let base = ExerciseRecommendation(
            exerciseID: press.id, basedOnPlanID: plan.id, generatedAt: date(28),
            action: .addReps, sets: plan.sets, reason: .addedRep(set: 1),
            evidence: .consistent, supportingExposureIDs: [], ruleVersion: "test"
        )
        let result = TrainingBlockEngine.applyingDeload(
            to: base, plan: plan, phase: .deload(week: 4), adaptiveDeload: false
        )
        XCTAssertEqual(result.action, .deload)
        XCTAssertEqual(result.reason, .scheduledDeload(week: 4))
        XCTAssertEqual(result.sets.count, 2)
        XCTAssertTrue(result.sets.allSatisfy { $0.load == 100 && $0.rpe == .seven })
        XCTAssertFalse(plan.isDeload, "a recommendation must not mutate or accept the stored plan")
    }

    func testFirstBuildWeekOffersToResumeThePreDeloadPlan() {
        let press = lift()
        let full = ExercisePlan(exercise: press, sets: Array(repeating:
            PlannedWorkingSet(load: 100, reps: 10, rpe: .eight), count: 3))
        let recovery = ExercisePlan(exercise: press, sets: Array(repeating:
            PlannedWorkingSet(load: 100, reps: 10, rpe: .seven), count: 2), isDeload: true)
        let accepted = ExerciseRecommendation(
            exerciseID: press.id, basedOnPlanID: recovery.id, generatedAt: date(28),
            action: .deload, sets: recovery.sets, reason: .acceptedDeload,
            evidence: .insufficient, supportingExposureIDs: [], ruleVersion: "test"
        )
        let result = TrainingBlockEngine.applyingDeload(
            to: accepted, plan: recovery, phase: .accumulation(week: 1),
            adaptiveDeload: false, resumePlan: full
        )
        XCTAssertEqual(result.action, .hold)
        XCTAssertEqual(result.reason, .resumeAfterDeload)
        XCTAssertEqual(result.sets, full.sets)
    }

    func testAdaptiveDeloadRequiresRepeatedFatigueAcrossTwoExercises() {
        let press = lift()
        let row = lift("Row", muscle: .lats)
        let now = date(21)
        let pressFatigue = [date(14), date(18)].map {
            exposure(press, on: $0, completion: .stoppedForFatigue)
        }
        XCTAssertFalse(TrainingBlockEngine.adaptiveDeloadNeeded(history: pressFatigue, now: now))

        let rowFatigue = [date(15), date(19)].map {
            exposure(row, on: $0, completion: .stoppedForFatigue)
        }
        XCTAssertTrue(TrainingBlockEngine.adaptiveDeloadNeeded(
            history: pressFatigue + rowFatigue, now: now
        ))

        let timeLimited = [date(15), date(19)].map {
            exposure(row, on: $0, completion: .shortenedForTime)
        }
        XCTAssertFalse(TrainingBlockEngine.adaptiveDeloadNeeded(
            history: pressFatigue + timeLimited, now: now
        ))
    }
}
