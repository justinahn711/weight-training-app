import XCTest
@testable import WeightTrainingCore

/// The domain types cross into persistence and CloudKit, so every one of them
/// has to survive a round trip unchanged.
final class CodableTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testExerciseRoundTrips() throws {
        try roundTrip(Exercise(
            name: "Flat Bench Press",
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: RPE(8)!),
            needsWarmupRamp: true
        ))
    }

    func testSetRecordRoundTrips() throws {
        try roundTrip(SetRecord(
            exerciseID: UUID(),
            load: Load(187.5),
            reps: 5,
            rpe: RPE(8.5),
            isWarmup: false,
            performedAt: Date(timeIntervalSince1970: 1_754_000_000)
        ))
    }

    func testProgressStateRoundTrips() throws {
        try roundTrip(ProgressState(
            exerciseID: UUID(),
            targetLoad: Load(185),
            targetReps: 5,
            targetRPE: RPE(8),
            stallCount: 2,
            consecutiveTopHits: 1,
            lastE1RM: Load(237),
            lastPerformedAt: Date(timeIntervalSince1970: 1_754_000_000)
        ))
    }

    func testDayTemplateRoundTrips() throws {
        try roundTrip(DayTemplate(kind: .push, slots: [
            Slot(name: "Heavy press", candidateExerciseIDs: [UUID(), UUID()]),
            Slot(name: "Rotating", candidateExerciseIDs: [UUID(), UUID()], rotates: true),
        ]))
    }

    func testColdStartStateRoundTripsWithNilTargets() throws {
        try roundTrip(ProgressState(exerciseID: UUID()))
    }
}
