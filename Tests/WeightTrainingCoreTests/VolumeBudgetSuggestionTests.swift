import XCTest
@testable import WeightTrainingCore

final class VolumeBudgetSuggestionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
    }

    private func exposure(
        exercise: Exercise,
        weekOffset: Int,
        setCount: Int = 8,
        completion: ExerciseExposure.Completion = .completed,
        source: ExposureSet.EffortSource = .reported,
        rpe: RPE? = .eight
    ) -> ExerciseExposure {
        let currentStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let date = calendar.date(byAdding: .day, value: 2,
            to: calendar.date(byAdding: .weekOfYear, value: weekOffset, to: currentStart)!)!
        let targets = (0..<setCount).map { _ in
            PlannedWorkingSet(load: 100, reps: 10, rpe: .eight)
        }
        let plan = ExercisePlan(exercise: exercise, sets: targets)
        let sets = targets.enumerated().map { index, target in
            ExposureSet(
                record: SetRecord(
                    exerciseID: exercise.id, load: target.load, reps: target.reps,
                    rpe: rpe, performedAt: date.addingTimeInterval(Double(index) * 60)
                ),
                effortSource: source
            )
        }
        return ExerciseExposure(
            id: UUID(), exerciseID: exercise.id, plan: plan, sets: sets,
            completion: completion, completedAt: date.addingTimeInterval(3_600)
        )
    }

    func testTwoConsecutiveToleratedWeeksProduceReviewableBands() throws {
        let press = Exercise(
            name: "Press", muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .dumbbell, progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let result = try XCTUnwrap(VolumeBudgetSuggestionEngine.suggest(
            history: [exposure(exercise: press, weekOffset: -2),
                      exposure(exercise: press, weekOffset: -1)],
            exercises: [press], now: now, calendar: calendar
        ))

        XCTAssertEqual(result.weeksAnalyzed, 2)
        XCTAssertEqual(result.budgets.first { $0.muscle == .chest }?.target, 7...9)
        XCTAssertEqual(result.budgets.first { $0.muscle == .triceps }?.target, 3...5)
        XCTAssertNil(result.budgets.first { $0.muscle == .lats })
    }

    func testCurrentPartialWeekIsExcluded() throws {
        let press = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let result = try XCTUnwrap(VolumeBudgetSuggestionEngine.suggest(
            history: [exposure(exercise: press, weekOffset: -2),
                      exposure(exercise: press, weekOffset: -1),
                      exposure(exercise: press, weekOffset: 0, setCount: 20)],
            exercises: [press], now: now, calendar: calendar
        ))
        XCTAssertEqual(result.budgets.first?.target, 7...9)
    }

    func testFatigueOrMissingReportedEffortPreventsSuggestion() {
        let press = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let older = exposure(exercise: press, weekOffset: -2)
        XCTAssertNil(VolumeBudgetSuggestionEngine.suggest(
            history: [older, exposure(exercise: press, weekOffset: -1,
                completion: .stoppedForFatigue)],
            exercises: [press], now: now, calendar: calendar
        ))
        XCTAssertNil(VolumeBudgetSuggestionEngine.suggest(
            history: [older, exposure(exercise: press, weekOffset: -1, source: .unknown)],
            exercises: [press], now: now, calendar: calendar
        ))
    }

    func testSuggestionIsPureAndDoesNotAlterConfiguredBudgets() {
        let press = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let configured = GymConfig(volumeBudgets: [
            MuscleSetBudget(muscle: .chest, minimum: 12, maximum: 18)
        ])
        _ = VolumeBudgetSuggestionEngine.suggest(
            history: [exposure(exercise: press, weekOffset: -2),
                      exposure(exercise: press, weekOffset: -1)],
            exercises: [press], now: now, calendar: calendar
        )
        XCTAssertEqual(configured.volumeTarget(for: .chest), 12...18)
    }
}
