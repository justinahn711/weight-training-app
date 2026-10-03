import XCTest
@testable import WeightTrainingCore

final class BodyweightRecommendationEvals: XCTestCase {
    func testRepeatedBodyweightWorkReachesRepCeilingWithoutInventingLoadChanges() {
        let lift = Exercise(name: "Pull-up", muscles: [.primary(.lats)], equipment: .bodyweight,
                            progressionRule: .doubleProgression(range: RepRange(8, 12)))
        let total = Load(173.4)
        var plan = ExercisePlan(exercise: lift, sets: [10, 10, 9].map {
            PlannedWorkingSet(load: total, reps: $0)
        })
        var history: [ExerciseExposure] = []
        var increases = 0
        var priorIncreased = false
        var final: ExerciseRecommendation?
        for index in 0..<24 {
            let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 2 * 86_400)
            let sets = plan.sets.map {
                ExposureSet(record: SetRecord(exerciseID: lift.id, load: $0.load, reps: $0.reps,
                    rpe: .seven, performedAt: date), effortSource: .reported)
            }
            history.append(ExerciseExposure(id: UUID(), exerciseID: lift.id, plan: plan,
                sets: sets, completion: .completed, completedAt: date))
            let result = RecommendationEngine.recommend(exercise: lift, plan: plan, history: history, now: date)
            XCTAssertEqual(result, RecommendationEngine.recommend(
                exercise: lift, plan: plan, history: history, now: date))
            XCTAssertTrue(result.sets.allSatisfy { $0.load == total && (8...12).contains($0.reps) })
            XCTAssertEqual(result.sets.count, 3)
            if priorIncreased { XCTAssertEqual(result.action, .hold, "Accepted reps require fresh confirmation") }
            priorIncreased = result.action == .addReps
            if priorIncreased {
                increases += 1
                XCTAssertEqual(result.sets.map(\.reps).reduce(0, +), plan.sets.map(\.reps).reduce(0, +) + 1)
                plan = ExercisePlan(exercise: lift, sets: result.sets)
            }
            final = result
        }
        XCTAssertEqual(increases, 7)
        XCTAssertEqual(final?.reason, .bodyweightRepCeiling)
        XCTAssertEqual(final?.sets.map(\.reps), [12, 12, 12])
    }
}
