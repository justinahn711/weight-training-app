import XCTest
@testable import WeightTrainingCore

/// Feed accepted recommendations back into subsequent workouts. These check
/// the new policy independently of the still-active legacy progression engine.
final class RecommendationEvals: XCTestCase {
    private struct Step {
        let plan: ExercisePlan
        let recommendation: ExerciseRecommendation
    }

    private func run(
        sessions: Int,
        perform: (Int, PlannedWorkingSet) -> (Int, RPE?)
    ) -> [Step] {
        let lift = Exercise(name: "Bench", muscles: [.primary(.chest)], equipment: .barbell,
                            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        var plan = ExercisePlan(exercise: lift, sets: [10, 10, 9].map {
            PlannedWorkingSet(load: 100, reps: $0)
        })
        var history: [ExerciseExposure] = []
        var steps: [Step] = []
        let epoch = Date(timeIntervalSince1970: 1_760_011_200)
        for index in 0..<sessions {
            let date = epoch.addingTimeInterval(Double(index) * 2 * 86_400)
            let sets = plan.sets.enumerated().map { setIndex, target in
                let (reps, effort) = perform(index, target)
                return ExposureSet(record: SetRecord(
                    exerciseID: lift.id, load: target.load, reps: reps, rpe: effort,
                    performedAt: date.addingTimeInterval(Double(setIndex) * 180)
                ), effortSource: effort == nil ? .unknown : .reported)
            }
            let finished = date.addingTimeInterval(1_800)
            history.append(ExerciseExposure(id: UUID(), exerciseID: lift.id, plan: plan,
                sets: sets, completion: .completed, completedAt: finished))
            let recommendation = RecommendationEngine.recommend(
                exercise: lift, plan: plan, history: history, now: finished)
            let repeatRead = RecommendationEngine.recommend(
                exercise: lift, plan: plan, history: history, now: finished)
            XCTAssertEqual(recommendation, repeatRead, "Reading a suggestion cannot spend progress")
            XCTAssertEqual(recommendation.sets.count, 3, "This phase must not add unbudgeted sets")
            XCTAssertTrue(recommendation.sets.allSatisfy {
                lift.canBuild($0.load) && $0.load >= lift.lightestUsableLoad && (8...12).contains($0.reps)
            }, "Session \(index): \(recommendation.summary)")
            if recommendation.action == .addReps {
                XCTAssertEqual(recommendation.sets.map(\.load), plan.sets.map(\.load))
                XCTAssertEqual(recommendation.sets.map(\.reps).reduce(0, +), plan.sets.map(\.reps).reduce(0, +) + 1)
            }
            if recommendation.action == .addLoad {
                XCTAssertLessThanOrEqual(recommendation.sets[0].load.pounds / plan.sets[0].load.pounds, 1.050_001)
                XCTAssertTrue(recommendation.sets.allSatisfy { $0.reps == 8 })
            }
            steps.append(Step(plan: plan, recommendation: recommendation))
            if recommendation.sets != plan.sets, !recommendation.sets.isEmpty {
                // Accepting a changed prescription creates a new comparison
                // segment. Repeating a prescription preserves its identity.
                plan = ExercisePlan(exercise: lift, sets: recommendation.sets)
            }
        }
        return steps
    }

    func testRepeatedEasyWorkProgressesWithoutReusingEvidence() {
        let steps = run(sessions: 44) { _, target in (target.reps, .seven) }
        let loadIncreases = steps.filter { $0.recommendation.action == .addLoad }
        XCTAssertEqual(loadIncreases.count, 2, "Scenario must actually exercise load progression")
        XCTAssertEqual(steps.last?.recommendation.sets.first?.load, Load(110))
        for (previous, next) in zip(steps, steps.dropFirst()) {
            if [.addReps, .addLoad].contains(previous.recommendation.action) {
                XCTAssertEqual(next.recommendation.action, .hold, "Every accepted increase needs fresh confirmation")
            }
        }
    }

    func testEffortCeilingPreventsRunawayLoadOverManyWorkouts() {
        let steps = run(sessions: 44) { _, target in
            (target.reps, target.load > Load(100) ? .nine : .seven)
        }
        XCTAssertTrue(steps.contains { $0.recommendation.action == .addLoad })
        XCTAssertEqual(steps.last?.recommendation.sets.first?.load, Load(105))
        XCTAssertEqual(steps.last?.recommendation.reason, .effortAboveTarget)
        XCTAssertTrue(steps.allSatisfy { $0.recommendation.sets[0].load <= Load(105) })
    }

    func testMissingEffortEveryOtherWorkoutNeverProducesFalseSuccess() {
        let steps = run(sessions: 24) { index, target in
            (target.reps, index.isMultiple(of: 2) ? .seven : nil)
        }
        XCTAssertTrue(steps.allSatisfy { $0.recommendation.action == .hold })
        XCTAssertEqual(steps.last?.recommendation.sets.map(\.reps), [10, 10, 9])
    }

    func testRepeatedMissesBackOffAndResumeWithFreshEvidence() {
        let steps = run(sessions: 44) { _, target in
            target.load > Load(100) ? (7, .nine) : (target.reps, .seven)
        }
        let resetIndices = steps.indices.filter { steps[$0].recommendation.action == .reduce }
        XCTAssertFalse(resetIndices.isEmpty, "The simulated lifter must reach a reset")
        for index in resetIndices {
            XCTAssertLessThan(steps[index].recommendation.sets[0].load, steps[index].plan.sets[0].load)
            if index + 1 < steps.count {
                XCTAssertEqual(steps[index + 1].recommendation.action, .hold)
            }
        }
    }
}
