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

    func testNineLoggedChestSetsPlusAFullFourSetProposalCannotExceedTwelve() {
        let base = recommendation()
        let chest = MuscleVolume(
            muscle: .chest, sets: 9, target: 6...12, totalWorkingSets: 9
        )

        XCTAssertEqual(
            VolumeAllocationEngine.applyingWeeklyVolume(
                to: base, exercise: exercise, report: report(overrides: [.chest: chest])
            ),
            base,
            "the ceiling applies to all four proposed sets, not only the added set"
        )
    }

    func testCoordinationReservesAnUnopenedOverlappingSiblingProposal() {
        let first = exercise
        let second = Exercise(
            name: "Machine chest press", muscles: [.primary(.chest)], equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        let logged = MuscleVolume(muscle: .chest, sets: 6, target: 10...12, totalWorkingSets: 6)
        let snapshot = report(overrides: [.chest: logged])
        let firstRecommendation = recommendation(for: first)

        XCTAssertEqual(
            VolumeAllocationEngine.applyingWeeklyVolume(
                to: firstRecommendation, exercise: first, report: snapshot
            ).action,
            .addSet,
            "the first proposal is eligible when considered by itself"
        )

        let coordinated = VolumeAllocationEngine.coordinating([
            .init(exercise: first, recommendation: firstRecommendation, routineOrder: 0),
            .init(exercise: second, recommendation: recommendation(for: second), routineOrder: 1),
        ], report: snapshot)

        XCTAssertEqual(coordinated[first.id]?.action, .hold)
        XCTAssertEqual(coordinated[second.id]?.action, .hold)
    }

    func testCoordinationSelectsOnlyOneWinnerByPriorityThenRoutineOrderThenStableID() throws {
        let lowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let chest = candidateExercise(id: highID, name: "Chest", muscle: .chest)
        let lats = candidateExercise(id: lowID, name: "Lats", muscle: .lats)
        let quads = candidateExercise(name: "Quads", muscle: .quads)

        func winner(_ candidates: [VolumeAllocationEngine.Candidate]) -> UUID? {
            let result = VolumeAllocationEngine.coordinating(candidates, report: report())
            let winners = result.filter { $0.value.action == .addSet }.map(\.key)
            XCTAssertEqual(winners.count, 1)
            return winners.first
        }

        XCTAssertEqual(winner([
            .init(exercise: chest, recommendation: recommendation(for: chest), routineOrder: 0),
            .init(exercise: lats, recommendation: recommendation(for: lats), routineOrder: 2, priority: 1),
            .init(exercise: quads, recommendation: recommendation(for: quads), routineOrder: 1),
        ]), lats.id, "explicit priority ranks first")

        XCTAssertEqual(winner([
            .init(exercise: chest, recommendation: recommendation(for: chest), routineOrder: 2),
            .init(exercise: lats, recommendation: recommendation(for: lats), routineOrder: 0),
            .init(exercise: quads, recommendation: recommendation(for: quads), routineOrder: 1),
        ]), lats.id, "routine order breaks equal priority")

        XCTAssertEqual(winner([
            .init(exercise: chest, recommendation: recommendation(for: chest), routineOrder: 0),
            .init(exercise: lats, recommendation: recommendation(for: lats), routineOrder: 0),
        ]), lats.id, "the stable exercise ID is the final tie breaker")
    }

    private func candidateExercise(
        id: UUID = UUID(), name: String, muscle: Muscle
    ) -> Exercise {
        Exercise(
            id: id, name: name, muscles: [.primary(muscle)], equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
    }

    private func recommendation(for candidate: Exercise) -> ExerciseRecommendation {
        let target = PlannedWorkingSet(load: 50, reps: 12, rpe: .eight)
        return ExerciseRecommendation(
            exerciseID: candidate.id, basedOnPlanID: UUID(), generatedAt: now,
            action: .hold, sets: Array(repeating: target, count: 3),
            reason: .loadStepTooLarge, evidence: .consistent,
            supportingExposureIDs: [UUID(), UUID()], ruleVersion: "test"
        )
    }

}
