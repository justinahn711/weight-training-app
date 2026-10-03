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

    /// The recommendation a workout shows is computed as of its start; the
    /// one `persistExercisePlan` checks it against is computed as of the
    /// moment it activates. When the only change between them is sets
    /// logged in this same workout, they must agree, or activation throws
    /// `.recommendationChanged` and the lift can't be logged (#316 review).
    /// Before the fix, this workout's logged sets fell out of the trailing
    /// history as of the start yet were still subtracted from its planned
    /// remaining work, so the start-time view undercounted the muscle.
    func testAWorkoutsOwnLoggedSetsDoNotChangeASiblingsRecommendationOverTime() throws {
        let store = try TrainingStore.inMemory()
        // A fine increment, so the first lift earns a heavier load rather
        // than the week's one extra set, which would otherwise mask this.
        let first = Exercise(
            name: "Plate press", muscles: [.primary(.chest)], equipment: .machineStack,
            increment: LoadIncrement(pounds: 5),
            progressionRule: .doubleProgression(range: RepRange(10, 10))
        )
        let sibling = Exercise(
            name: "Fixed-stack fly", muscles: [.primary(.chest)], equipment: .machineStack,
            increment: LoadIncrement(pounds: 100),
            progressionRule: .doubleProgression(range: RepRange(10, 10))
        )
        try store.upsert(first)
        try store.upsert(sibling)
        // Chest needs 6 hard sets a week; history below supplies 4.
        var config = try store.gymConfig()
        config.volumeBudgets = config.volumeBudgets.map {
            $0.muscle == .chest ? MuscleSetBudget(muscle: .chest, minimum: 6, maximum: 12) : $0
        }
        _ = try store.saveGymConfig(config, at: monday.addingTimeInterval(-5 * 86_400))
        let target = PlannedWorkingSet(load: 100, reps: 10, rpe: .eight)
        for exercise in [first, sibling] {
            for offset in [-3.0, -1.0] {
                let startedAt = monday.addingTimeInterval(offset * 86_400)
                let workout = UUID()
                _ = try store.acceptExercisePlan(ExercisePlan(exercise: exercise, sets: [target]),
                                                 workoutID: workout, startedAt: startedAt, now: startedAt)
                _ = try store.logWorkoutSet(
                    SetRecord(exerciseID: exercise.id, load: target.load, reps: target.reps, rpe: .seven,
                              performedAt: startedAt.addingTimeInterval(60)),
                    workoutID: workout, startedAt: startedAt, effortReported: true)
                try store.finishExerciseSessions(workoutID: workout, at: startedAt.addingTimeInterval(120))
            }
        }

        // Today: the first lift's three-set plan, fully logged.
        let workout = UUID()
        _ = try store.acceptExercisePlan(ExercisePlan(exercise: first, sets: [target, target, target]),
                                         workoutID: workout, startedAt: monday, now: monday)
        for minute in [2.0, 4.0, 6.0] {
            _ = try store.logWorkoutSet(
                SetRecord(exerciseID: first.id, load: target.load, reps: target.reps, rpe: .seven,
                          performedAt: monday.addingTimeInterval(minute * 60)),
                workoutID: workout, startedAt: monday, effortReported: true)
        }

        let asOfStart = try store.workoutRecommendations(for: [sibling], workoutID: workout, now: monday)
        let asOfNow = try store.workoutRecommendations(
            for: [sibling], workoutID: workout, now: monday.addingTimeInterval(10 * 60))
        XCTAssertEqual(asOfStart[sibling.id]?.action, asOfNow[sibling.id]?.action)
        XCTAssertEqual(asOfStart[sibling.id]?.sets, asOfNow[sibling.id]?.sets)
    }

    /// The weekly digest judges volume against the lifter's own set targets,
    /// as the Volume screen and the recommendations do (#316 review). Every
    /// target here is set to zero, so nothing can be under target; with the
    /// built-in defaults instead, nearly every muscle would be.
    func testDigestJudgesVolumeAgainstCustomTargets() throws {
        let (store, _) = try eligibleFixture()
        var config = try store.gymConfig()
        config.volumeBudgets = config.volumeBudgets.map { MuscleSetBudget(muscle: $0.muscle, minimum: 0, maximum: 40) }
        _ = try store.saveGymConfig(config)
        let digest = try store.digest(now: monday)
        XCTAssertFalse(digest.bullets.contains { $0.action == .review(.volume) },
                       "no muscle is under a zero target: \(digest.bullets.map(\.text))")
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
