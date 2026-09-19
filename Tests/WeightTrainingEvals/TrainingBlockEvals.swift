import XCTest
@testable import WeightTrainingCore

/// Calendar replays for the optional block layer. These keep the coordinated
/// recovery rule separate from the exercise progression season simulations.
final class TrainingBlockEvals: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func testTwelveWeekReplaySchedulesThreeReviewableRecoveryWeeks() {
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 5, hour: 12
        ))!
        let config = TrainingBlockConfig(startedAt: start, accumulationWeeks: 3)
        let phases = (0..<12).map { offset in
            TrainingBlockEngine.phase(
                for: config,
                now: calendar.date(byAdding: .weekOfYear, value: offset, to: start)!,
                calendar: calendar
            )
        }
        XCTAssertEqual(phases.enumerated().compactMap { index, phase in
            if case .deload = phase { return index + 1 }
            return nil
        }, [4, 8, 12])
    }

    func testRecoveryProposalNeverRaisesLoadRepsOrSetCount() {
        let exercise = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let plan = ExercisePlan(exercise: exercise, sets: [8, 9, 10, 11, 12].map {
            PlannedWorkingSet(load: 80, reps: $0, rpe: .eight)
        })
        let recommendation = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: plan.id, generatedAt: Date(),
            action: .addLoad, sets: plan.sets, reason: .addedLoad,
            evidence: .consistent, supportingExposureIDs: [], ruleVersion: "replay"
        )
        let recovery = TrainingBlockEngine.applyingDeload(
            to: recommendation, plan: plan, phase: .deload(week: 4), adaptiveDeload: false
        )
        XCTAssertLessThan(recovery.sets.count, plan.sets.count)
        XCTAssertTrue(zip(recovery.sets, plan.sets).allSatisfy {
            $0.load <= $1.load && $0.reps <= $1.reps && $0.rpe <= $1.rpe
        })
    }

    func testTimePressureAloneNeverBecomesProgramFatigue() {
        let exercises = [Muscle.chest, .lats, .quads].map { muscle in
            Exercise(name: muscle.displayName, muscles: [.primary(muscle)], equipment: .dumbbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let history = exercises.flatMap { exercise in
            (1...3).map { offset in
                ExerciseExposure(
                    id: UUID(), exerciseID: exercise.id, plan: nil, sets: [],
                    completion: .shortenedForTime,
                    completedAt: now.addingTimeInterval(Double(-offset) * 86_400)
                )
            }
        }
        XCTAssertFalse(TrainingBlockEngine.adaptiveDeloadNeeded(history: history, now: now))
    }
}
