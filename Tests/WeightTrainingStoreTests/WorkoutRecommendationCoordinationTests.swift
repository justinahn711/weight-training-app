import XCTest
@testable import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class WorkoutRecommendationCoordinationTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_782_086_400)

    func testRepeatedReadsRemainPureUntilPersistedActivationConsumesTheFixedPeriod() throws {
        let (store, exercise) = try eligibleFixture()
        let workout = UUID()
        let first = try store.workoutRecommendations(for: [exercise], workoutID: workout, now: monday)
        let second = try store.workoutRecommendations(for: [exercise], workoutID: workout, now: monday)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first[exercise.id]?.action, .addSet)
        XCTAssertNil(try store.exerciseSession(workoutID: workout, exerciseID: exercise.id))

        let displayed = try XCTUnwrap(first[exercise.id])
        _ = try XCTUnwrap(store.activateExerciseRecommendation(
            displayed, workoutID: workout, startedAt: monday, now: monday.addingTimeInterval(60)
        ))

        let samePeriod = try store.workoutRecommendations(
            for: [exercise], workoutID: UUID(), now: monday.addingTimeInterval(2 * 86_400)
        )
        XCTAssertNotEqual(samePeriod[exercise.id]?.action, .addSet)

        let period = VolumeAllocationEngine.allocationPeriod(containing: monday)
        XCTAssertEqual(period.start, monday)
        XCTAssertEqual(period.end, monday.addingTimeInterval(7 * 86_400))
        XCTAssertTrue(period.contains(monday.addingTimeInterval(60)))
        XCTAssertTrue(period.contains(monday.addingTimeInterval(2 * 86_400)))
    }

    func testFreshStoreUsesDefaultVolumeBudgetsWithoutManualSetup() throws {
        let (store, exercise) = try eligibleFixture()

        XCTAssertEqual(try store.gymConfig().volumeBudgets, MuscleSetBudget.defaults)
        XCTAssertEqual(
            try store.workoutRecommendations(for: [exercise], now: monday)[exercise.id]?.action,
            .addSet
        )
    }

    func testAutomaticDeloadDoesNotActivateButExplicitAcceptanceStillWorks() throws {
        let store = try TrainingStore.inMemory()
        let exercise = exercise()
        try store.upsert(exercise)
        let target = PlannedWorkingSet(load: 100, reps: 10, rpe: .seven)
        let displayed = ExerciseRecommendation(
            exerciseID: exercise.id, basedOnPlanID: nil, generatedAt: monday,
            action: .deload, sets: [target], reason: .scheduledDeload(week: 4),
            evidence: .consistent, supportingExposureIDs: [], ruleVersion: "test"
        )

        let automaticWorkout = UUID()
        XCTAssertNil(try store.activateExerciseRecommendation(
            displayed, workoutID: automaticWorkout, startedAt: monday, now: monday
        ))
        XCTAssertNil(try store.exerciseSession(workoutID: automaticWorkout, exerciseID: exercise.id))

        let explicitWorkout = UUID()
        let accepted = try store.acceptExercisePlan(
            ExercisePlan(exercise: exercise, sets: [target], isDeload: true),
            workoutID: explicitWorkout, startedAt: monday, now: monday
        )
        XCTAssertTrue(accepted.isDeload)
        XCTAssertEqual(
            try store.exerciseSession(workoutID: explicitWorkout, exerciseID: exercise.id)?.plan,
            accepted
        )
    }

    private func eligibleFixture() throws -> (TrainingStore, Exercise) {
        let store = try TrainingStore.inMemory()
        let exercise = exercise()
        try store.upsert(exercise)
        let target = PlannedWorkingSet(load: 100, reps: 10, rpe: .eight)
        let plan = ExercisePlan(exercise: exercise, sets: [target])

        for offset in [-3.0, -1.0] {
            let startedAt = monday.addingTimeInterval(offset * 86_400)
            let workout = UUID()
            _ = try store.acceptExercisePlan(
                plan, workoutID: workout, startedAt: startedAt, now: startedAt
            )
            _ = try store.logWorkoutSet(
                SetRecord(
                    exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .seven,
                    performedAt: startedAt.addingTimeInterval(60)
                ),
                workoutID: workout, startedAt: startedAt, effortReported: true
            )
            try store.finishExerciseSessions(workoutID: workout, at: startedAt.addingTimeInterval(120))
        }
        return (store, exercise)
    }

    private func exercise() -> Exercise {
        Exercise(
            name: "Fixed-stack press", muscles: [.primary(.chest)], equipment: .machineStack,
            increment: LoadIncrement(pounds: 100),
            progressionRule: .doubleProgression(range: RepRange(10, 10))
        )
    }
}
