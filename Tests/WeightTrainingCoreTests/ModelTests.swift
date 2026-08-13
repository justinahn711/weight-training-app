import XCTest
@testable import WeightTrainingCore

final class ModelTests: XCTestCase {

    private func makeInclineDBPress() -> Exercise {
        Exercise(
            name: "Incline DB Press",
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(6, 10))
        )
    }

    // MARK: - Exercise

    func testExerciseInheritsIncrementFromEquipment() {
        XCTAssertEqual(makeInclineDBPress().increment, .dumbbell)
    }

    /// Machine stacks vary per gym, so an override has to win over the default.
    func testExplicitIncrementOverridesEquipmentDefault() {
        let pulldown = Exercise(
            name: "Lat Pulldown",
            muscles: [.primary(.lats), .secondary(.biceps)],
            equipment: .machineStack,
            increment: LoadIncrement(pounds: 15),
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        XCTAssertEqual(pulldown.increment.pounds, 15)
    }

    func testPrimaryMusclesExcludeSecondaries() {
        XCTAssertEqual(makeInclineDBPress().primaryMuscles, [.chest])
    }

    /// Secondary involvement counts half, so a day full of pressing doesn't
    /// report triceps volume that overstates the direct work done.
    func testVolumeContributionWeightsRole() {
        let press = makeInclineDBPress()
        XCTAssertEqual(press.volumeContribution(to: .chest), 1.0)
        XCTAssertEqual(press.volumeContribution(to: .triceps), 0.5)
        XCTAssertEqual(press.volumeContribution(to: .quads), 0.0)
    }

    // MARK: - SetRecord

    func testWarmupsAreNeverHardSets() {
        let warmup = SetRecord(
            exerciseID: UUID(), load: Load(135), reps: 5,
            rpe: nil, isWarmup: true, performedAt: Date()
        )
        XCTAssertFalse(warmup.isHardSet)
    }

    func testEasySetsBelowRPE7DoNotCountAsHard() {
        let easy = SetRecord(
            exerciseID: UUID(), load: Load(185), reps: 5,
            rpe: RPE(6.5), performedAt: Date()
        )
        XCTAssertFalse(easy.isHardSet)
    }

    func testWorkingSetsAtOrAboveRPE7CountAsHard() {
        let hard = SetRecord(
            exerciseID: UUID(), load: Load(185), reps: 5,
            rpe: RPE(7), performedAt: Date()
        )
        XCTAssertTrue(hard.isHardSet)
    }

    /// Discarding un-scored work would be worse than counting it.
    func testWorkingSetWithoutRPECountsAsHard() {
        let unscored = SetRecord(
            exerciseID: UUID(), load: Load(185), reps: 5, performedAt: Date()
        )
        XCTAssertTrue(unscored.isHardSet)
    }

    // MARK: - ProgressState

    func testFreshStateIsColdStart() {
        let state = ProgressState(exerciseID: UUID())
        XCTAssertTrue(state.isColdStart)
        XCTAssertNil(state.targetLoad)
        XCTAssertEqual(state.stallCount, 0)
    }

    func testStateWithATargetIsNotColdStart() {
        var state = ProgressState(exerciseID: UUID())
        state.targetLoad = Load(185)
        XCTAssertFalse(state.isColdStart)
    }

    // MARK: - ProgressionRule

    func testDoubleProgressionDisplaysBottomOfRange() {
        let rule = ProgressionRule.doubleProgression(range: RepRange(6, 10))
        XCTAssertEqual(rule.displayRepTarget, 6)
        XCTAssertEqual(rule.displayRPETarget, RPE(8))
    }

    func testRPETargetedLoadDisplaysItsOwnTargets() {
        let rule = ProgressionRule.rpeTargetedLoad(reps: 5, targetRPE: RPE(8)!)
        XCTAssertEqual(rule.displayRepTarget, 5)
        XCTAssertEqual(rule.displayRPETarget, RPE(8))
    }

    func testRepRangeContainsAndSpan() {
        let range = RepRange(8, 12)
        XCTAssertTrue(range.contains(8))
        XCTAssertTrue(range.contains(12))
        XCTAssertFalse(range.contains(13))
        XCTAssertEqual(range.span, 4)
    }
}
