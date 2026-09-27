import XCTest
@testable import WeightTrainingCore

final class VolumeAllocationEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private var exercise: Exercise {
        ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
    }

    private func recommendation(
        action: ExerciseRecommendation.Action = .hold,
        reason: ExerciseRecommendation.Reason = .loadStepTooLarge,
        evidence: ExerciseRecommendation.Evidence = .consistent
    ) -> ExerciseRecommendation {
        let target = PlannedWorkingSet(load: 50, reps: 12, rpe: .eight)
        return ExerciseRecommendation(
            exerciseID: exercise.id,
            basedOnPlanID: UUID(),
            generatedAt: now,
            action: action,
            sets: Array(repeating: target, count: 3),
            reason: reason,
            evidence: evidence,
            supportingExposureIDs: [UUID(), UUID()],
            ruleVersion: "test"
        )
    }

    private func report(overrides: [Muscle: MuscleVolume] = [:]) -> VolumeReport {
        VolumeReport(
            muscles: Muscle.allCases.map { muscle in
                overrides[muscle] ?? MuscleVolume(
                    muscle: muscle, sets: 0, target: muscle.weeklySetTarget
                )
            },
            from: now.addingTimeInterval(-7 * 86_400),
            to: now
        )
    }

    func testAddsAtMostOneSetWhenPrimaryVolumeIsLowAndLoadCannotProgress() {
        let base = recommendation()
        let result = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report()
        )

        XCTAssertEqual(result.action, .addSet)
        XCTAssertEqual(result.sets.count, base.sets.count + 1)
        XCTAssertEqual(result.sets.last, base.sets.last)
        XCTAssertEqual(result.reason, .weeklyVolumeBelowBudget(muscles: [.chest]))
        XCTAssertEqual(result.supportingExposureIDs, base.supportingExposureIDs)
    }

    func testFullSecondaryBudgetBlocksASetIncrease() {
        let triceps = MuscleVolume(muscle: .triceps, sets: 16, target: 8...16)
        let base = recommendation()
        let result = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(overrides: [.triceps: triceps])
        )
        XCTAssertEqual(result, base)
    }

    func testAcceptedRemainingWorkCountsAgainstTheCeiling() {
        let triceps = MuscleVolume(
            muscle: .triceps, sets: 15.5, target: 8...16, plannedSets: 0.5
        )
        let base = recommendation()
        let result = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(overrides: [.triceps: triceps])
        )
        XCTAssertEqual(result, base)
    }

    func testVolumeDoesNotCompeteWithRepOrLoadProgression() {
        for action in [ExerciseRecommendation.Action.addReps, .addLoad, .reduce] {
            let base = recommendation(action: action)
            XCTAssertEqual(
                VolumeAllocationEngine.applyingWeeklyVolume(
                    to: base, exercise: exercise, report: report()
                ),
                base
            )
        }
    }

    func testNeedsConsistentEvidenceBeforeAddingVolume() {
        let base = recommendation(evidence: .limited)
        XCTAssertEqual(
            VolumeAllocationEngine.applyingWeeklyVolume(
                to: base, exercise: exercise, report: report()
            ),
            base
        )
    }

    func testAFullPrimaryBudgetKeepsThePlanUnchanged() {
        let chest = MuscleVolume(muscle: .chest, sets: 12, target: 6...12)
        let base = recommendation()
        XCTAssertEqual(
            VolumeAllocationEngine.applyingWeeklyVolume(
                to: base, exercise: exercise, report: report(overrides: [.chest: chest])
            ),
            base
        )
    }
    func testFullProposedWorkoutMustFitSecondaryBudget() {
        let base = recommendation()
        let triceps = MuscleVolume(muscle: .triceps, sets: 15, target: 8...16)
        XCTAssertEqual(VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(overrides: [.triceps: triceps])
        ), base, "Four proposed press sets add two triceps credits, not half a credit")
    }

    func testAlreadyReservedWorkoutIsNotCountedTwice() {
        let base = recommendation()
        let triceps = MuscleVolume(muscle: .triceps, sets: 14, target: 8...16, plannedSets: 1.5)
        let result = VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(overrides: [.triceps: triceps]),
            reservedSetsForExercise: 3
        )
        XCTAssertEqual(result.action, .addSet)
        XCTAssertEqual(result.sets.count, 4)
    }

    func testBaselineWorkoutMeetingMinimumDoesNotEarnExtraVolume() {
        let base = recommendation()
        let chest = MuscleVolume(muscle: .chest, sets: 3, target: 6...12)
        XCTAssertEqual(VolumeAllocationEngine.applyingWeeklyVolume(
            to: base, exercise: exercise, report: report(overrides: [.chest: chest])
        ), base)
    }

}
