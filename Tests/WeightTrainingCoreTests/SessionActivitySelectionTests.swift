import XCTest
@testable import WeightTrainingCore

final class SessionActivitySelectionTests: XCTestCase {
    func testExactWorkoutWinsOverLegacyActivity() {
        let candidates = [
            SessionActivityCandidate(id: "legacy", workoutID: nil, dayKind: "Push"),
            SessionActivityCandidate(id: "current", workoutID: "new", dayKind: "Pull"),
        ]
        XCTAssertEqual(
            SessionActivitySelection.keeperID(
                workoutID: "new", dayKind: "Pull", from: candidates
            ),
            "current"
        )
    }

    func testMatchingLegacyActivityIsAdoptedAfterUpgrade() {
        let candidates = [
            SessionActivityCandidate(id: "legacy", workoutID: nil, dayKind: "Legs"),
            SessionActivityCandidate(id: "other", workoutID: nil, dayKind: "Push"),
        ]
        XCTAssertEqual(
            SessionActivitySelection.keeperID(
                workoutID: "new", dayKind: "Legs", from: candidates
            ),
            "legacy"
        )
    }

    func testUnrelatedActivitiesProduceNoKeeper() {
        let candidates = [
            SessionActivityCandidate(id: "old", workoutID: "old", dayKind: "Push"),
            SessionActivityCandidate(id: "legacy", workoutID: nil, dayKind: "Pull"),
        ]
        XCTAssertNil(
            SessionActivitySelection.keeperID(
                workoutID: "new", dayKind: "Push", from: candidates
            )
        )
    }

    func testForegroundAndLiveActivityAdvanceThroughPerSetTargets() {
        let exercise = Exercise(
            name: "Press", muscles: [.primary(.chest)], equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let plan = ExercisePlan(exercise: exercise, sets: [10, 10, 9].map {
            PlannedWorkingSet(load: 50, reps: $0, rpe: .eight)
        })

        XCTAssertEqual(SessionActivitySelection.nextPlannedSet(
            in: plan, completedWorkingSets: 0
        )?.reps, 10)
        XCTAssertEqual(SessionActivitySelection.nextPlannedSet(
            in: plan, completedWorkingSets: 1
        )?.reps, 10)
        XCTAssertEqual(SessionActivitySelection.nextPlannedSet(
            in: plan, completedWorkingSets: 2
        )?.reps, 9)
        XCTAssertNil(SessionActivitySelection.nextPlannedSet(
            in: plan, completedWorkingSets: 3
        ))

        // Undoing set two returns the completed count to one and therefore
        // restores the second row instead of repeating or skipping a target.
        XCTAssertEqual(SessionActivitySelection.nextPlannedSet(
            in: plan, completedWorkingSets: 1
        ), plan.sets[1])
    }
}
