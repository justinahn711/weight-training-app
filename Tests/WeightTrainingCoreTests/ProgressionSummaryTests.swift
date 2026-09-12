import XCTest
@testable import WeightTrainingCore

final class ProgressionSummaryTests: XCTestCase {
    private let exercise = Exercise(
        name: "Incline Press",
        muscles: [.primary(.chest)],
        equipment: .barbell,
        progressionRule: .doubleProgression(range: RepRange(8, 12))
    )

    func testWarmupsAloneDoNotCreateASummaryRow() {
        let result = makeResult(.noWorkingSets)
        XCTAssertNil(ProgressionSummaryEntry(
            exercise: exercise,
            performed: [set(load: 45, reps: 10, warmup: true)],
            result: result
        ))
    }

    func testEveryEngineDecisionPresentsItsExactReasonAndNextTarget() throws {
        let cases: [(ProgressionChange, String)] = [
            (.addedReps(to: 11), "Go for 11 reps"),
            (.earnedTowardLoad(hits: 1, required: 2),
             "Hit the top 1 of 2 times — repeat it"),
            (.addedLoad(from: 70, to: 75), "Earned it: 70 lb → 75 lb"),
            (.heldForEffort(rpe: RPE(9)!),
             "Top of the range at RPE 9 — repeat before adding weight"),
            (.heldAfterMiss(reps: 6), "Fell short at 6 — hold and rebuild"),
            (.noEffortReported, "No RPE logged — holding steady"),
            (.adjustedLoad(from: 70, to: 75, rpeDelta: 1),
             "1.0 RPE easier than target: 70 lb → 75 lb"),
            (.onTarget(70), "On target — stay at 70 lb"),
        ]

        for (change, reason) in cases {
            let entry = try XCTUnwrap(ProgressionSummaryEntry(
                exercise: exercise,
                performed: [
                    set(load: 70, reps: 12),
                    set(load: 70, reps: 11),
                ],
                result: makeResult(change)
            ))

            XCTAssertEqual(entry.transitionLine(in: .pounds),
                           "70 lb × 12, 11 → next 75 lb × 8 @ RPE 8")
            XCTAssertEqual(entry.result.summary(in: .pounds), reason)
        }
    }

    func testPresentationUsesTheChosenUnitWithoutChangingStoredLoads() throws {
        let entry = try XCTUnwrap(ProgressionSummaryEntry(
            exercise: exercise,
            performed: [set(load: Load(60, .kilograms), reps: 12)],
            result: ProgressionResult(
                state: nextState(load: Load(62.5, .kilograms)),
                change: .addedLoad(
                    from: Load(60, .kilograms),
                    to: Load(62.5, .kilograms)
                )
            )
        ))

        XCTAssertEqual(entry.transitionLine(in: .kilograms),
                       "60 kg × 12 → next 62.5 kg × 8 @ RPE 8")
        XCTAssertEqual(entry.result.summary(in: .kilograms),
                       "Earned it: 60 kg → 62.5 kg")
    }

    func testVoiceOverReadsTheRowAsOneCoherentThought() throws {
        let entry = try XCTUnwrap(ProgressionSummaryEntry(
            exercise: exercise,
            performed: [set(load: 70, reps: 12)],
            result: makeResult(.addedLoad(from: 70, to: 75))
        ))

        XCTAssertEqual(
            entry.accessibilityLabel(in: .pounds),
            "Incline Press. Performed 70 lb × 12. Next target 75 lb × 8 @ RPE 8. "
                + "Earned it: 70 lb → 75 lb."
        )
    }

    private func makeResult(_ change: ProgressionChange) -> ProgressionResult {
        ProgressionResult(state: nextState(load: 75), change: change)
    }

    private func nextState(load: Load) -> ProgressState {
        ProgressState(
            exerciseID: exercise.id,
            targetLoad: load,
            targetReps: 8,
            targetRPE: RPE(8)!
        )
    }

    private func set(load: Load, reps: Int, warmup: Bool = false) -> SetRecord {
        SetRecord(
            exerciseID: exercise.id,
            load: load,
            reps: reps,
            rpe: warmup ? nil : RPE(8),
            isWarmup: warmup,
            performedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
