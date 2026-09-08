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
}
