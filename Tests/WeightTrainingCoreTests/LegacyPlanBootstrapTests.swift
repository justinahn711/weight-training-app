import XCTest
@testable import WeightTrainingCore

final class LegacyPlanBootstrapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentLegacyWorkoutBecomesAConservativeReviewableBaseline() throws {
        let exercise = Exercise(
            name: "T-Bar Row",
            muscles: [.primary(.lats)],
            equipment: .plateLoaded,
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            loading: LoadingStyle(baseWeight: 45, sleeves: 1, availablePlates: [45, 25, 10, 5, 2.5])
        )
        let performedAt = now.addingTimeInterval(-3 * 86_400)
        let history = [
            SetRecord(exerciseID: exercise.id, load: 100, reps: 11, performedAt: performedAt),
            SetRecord(exerciseID: exercise.id, load: 90, reps: 9, performedAt: performedAt.addingTimeInterval(180)),
            SetRecord(exerciseID: exercise.id, load: 90, reps: 7, performedAt: performedAt.addingTimeInterval(360))
        ]

        let recommendation = try XCTUnwrap(LegacyPlanBootstrapEngine.recommend(
            exercise: exercise, history: history, now: now
        ))

        XCTAssertEqual(recommendation.action, .establish)
        XCTAssertEqual(recommendation.reason, .legacyBaseline)
        XCTAssertEqual(recommendation.evidence, .limited)
        XCTAssertEqual(recommendation.sets.map(\.load), [90, 90, 90])
        XCTAssertEqual(recommendation.sets.map(\.reps), [11, 9, 8])
        XCTAssertTrue(recommendation.supportingExposureIDs.isEmpty)
    }

    func testWarmupsAndStaleHistoryDoNotCreateABaseline() {
        let exercise = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let stale = SetRecord(
            exerciseID: exercise.id, load: 50, reps: 10,
            performedAt: now.addingTimeInterval(-22 * 86_400)
        )
        let warmup = SetRecord(
            exerciseID: exercise.id, load: 20, reps: 10, isWarmup: true,
            performedAt: now.addingTimeInterval(-86_400)
        )

        XCTAssertNil(LegacyPlanBootstrapEngine.recommend(
            exercise: exercise, history: [stale, warmup], now: now
        ))
    }
}
