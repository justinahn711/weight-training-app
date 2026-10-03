import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class RecommendationHistoryPerformanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Two years, three workouts per week, six movements per workout, with
    /// warmups, missing effort, incomplete sessions and overlapping muscles.
    /// The fixture is synthetic and confined to an in-memory test store.
    private func largeHistory() throws -> (TrainingStore, [Exercise]) {
        let store = try TrainingStore.inMemory()
        let exercises = (0..<12).map { index in
            Exercise(name: "History movement \(index)",
                     muscles: [.primary(index.isMultiple(of: 2) ? .chest : .lats), .secondary(.triceps)],
                     equipment: .barbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        for exercise in exercises { store.modelContext.insert(StoredExercise(exercise)) }
        let plans = exercises.map { exercise in
            ExercisePlan(exercise: exercise, sets: Array(repeating: PlannedWorkingSet(load: 100, reps: 10), count: 3))
        }
        for workoutIndex in 0..<312 {
            let workout = UUID()
            let date = now.addingTimeInterval(-Double(312 - workoutIndex) * (7.0 / 3) * 86_400)
            for offset in 0..<6 {
                let index = (workoutIndex % 2) * 6 + offset
                let exercise = exercises[index], plan = plans[index]
                let partial = workoutIndex.isMultiple(of: 19)
                let setCount = partial ? 3 : 4
                let completedAt = date.addingTimeInterval(Double(offset * 60 + setCount) * 10)
                let session = RecordedExerciseSession(
                    workoutID: workout, exerciseID: exercise.id, startedAt: date, plan: plan,
                    completion: partial ? .shortenedForTime : .completed,
                    completedAt: completedAt, updatedAt: completedAt)
                store.modelContext.insert(StoredExerciseSession(session))
                for setIndex in 0..<setCount {
                    let missingEffort = workoutIndex.isMultiple(of: 7)
                    store.modelContext.insert(StoredSetLog(SetRecord(
                        exerciseID: exercise.id, load: setIndex == 0 ? 50 : 100,
                        reps: setIndex == 0 ? 5 : 10,
                        rpe: missingEffort ? nil : (workoutIndex.isMultiple(of: 11) ? .ten : .seven),
                        isWarmup: setIndex == 0,
                        performedAt: date.addingTimeInterval(Double(offset * 60 + setIndex) * 10),
                        workoutID: workout, acceptedPlanID: plan.id,
                        effortWasReported: !missingEffort && setIndex != 0)))
                }
            }
        }
        try store.saveChanges()
        return (store, exercises)
    }

    /// Warm both paths, then balance execution order to limit cache/order bias.
    /// Timings are descriptive; correctness never depends on a speed threshold.
    private func compareWarmMedians<Value: Equatable>(
        reference: () throws -> Value, indexed: () throws -> Value
    ) throws -> (value: Value, reference: TimeInterval, indexed: TimeInterval) {
        let expected = try reference()
        XCTAssertEqual(try indexed(), expected)
        var referenceTimes: [TimeInterval] = []
        var indexedTimes: [TimeInterval] = []
        func elapsed(_ operation: () throws -> Value) throws -> TimeInterval {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try operation()
            let duration = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(value, expected)
            return duration
        }
        for iteration in 0..<4 {
            if iteration.isMultiple(of: 2) {
                referenceTimes.append(try elapsed(reference))
                indexedTimes.append(try elapsed(indexed))
            } else {
                indexedTimes.append(try elapsed(indexed))
                referenceTimes.append(try elapsed(reference))
            }
        }
        func median(_ values: [TimeInterval]) -> TimeInterval {
            let sorted = values.sorted()
            return (sorted[1] + sorted[2]) / 2
        }
        return (expected, median(referenceTimes), median(indexedTimes))
    }

    func testLargeHistoryBatchMatchesOriginalDecisions() throws {
        let (store, exercises) = try largeHistory()
        let roster = Array(exercises.prefix(6))
        let batch = try compareWarmMedians(
            reference: { try store.referenceWorkoutRecommendations(for: roster, now: now) },
            indexed: { try store.workoutRecommendations(for: roster, now: now) })
        XCTAssertEqual(batch.value.count, roster.count)
        print("Recommendation history timing (4 warm samples, alternating order, median): 312 workouts, 1872 exercise sessions, \(try store.allSets().count) sets; original batch=\(batch.reference)s; indexed batch=\(batch.indexed)s")

        let library = try store.exercises()
        let exposures = try compareWarmMedians(
            reference: { try library.flatMap { try store.exerciseExposures(for: $0.id) } },
            indexed: { try store.allExerciseExposures() })
        XCTAssertTrue(exposures.value.allSatisfy { exposure in
            exposure.sets.allSatisfy { $0.record.performedAt < exposure.completedAt }
        })
        print("Recommendation exposure timing (4 warm samples, alternating order, median): original per-exercise fetches=\(exposures.reference)s; shared snapshot=\(exposures.indexed)s")

        let beforeFetch = Date()
        let snapshot = try RecommendationHistory(sets: store.allSets(), sessions: store.exerciseSessions())
        let snapshotDuration = Date().timeIntervalSince(beforeFetch)
        let config = try store.gymConfig()
        let beforeCalculation = Date()
        let calculated = try store.workoutRecommendations(for: roster, workoutID: nil, now: now,
                                                         history: snapshot, library: library, config: config)
        let calculationDuration = Date().timeIntervalSince(beforeCalculation)
        XCTAssertEqual(calculated, batch.value)
        print("Recommendation cost split: history fetch/decode/index=\(snapshotDuration)s; calculation=\(calculationDuration)s")
    }

    func testSingleRecommendationMatchesOriginalBatchAsRoutineSlotRotates() throws {
        let store = try TrainingStore.inMemory()
        let focus = Exercise(name: "Fixed-stack press", muscles: [.primary(.chest)],
            equipment: .machineStack, increment: LoadIncrement(pounds: 100),
            progressionRule: .doubleProgression(range: RepRange(10, 10)))
        let known = Exercise(name: "Known accessory", muscles: [.primary(.triceps)],
            equipment: .dumbbell, progressionRule: .doubleProgression(range: RepRange(8, 12)))
        let unknown = Exercise(name: "Unstarted accessory", muscles: [.primary(.triceps)],
            equipment: .dumbbell, progressionRule: .doubleProgression(range: RepRange(8, 12)))
        for exercise in [focus, known, unknown] { try store.upsert(exercise) }
        let routine = DayTemplate(kind: .push, slots: [
            Slot(name: "Press", candidateExerciseIDs: [focus.id]),
            Slot(name: "Accessory", candidateExerciseIDs: [known.id, unknown.id], rotates: true)
        ])
        var config = GymConfig.standard
        config.trainingSplit = TrainingSplit(kind: .custom, days: [routine],
                                            startedAt: now.addingTimeInterval(-7 * 86_400))
        try store.saveGymConfig(config, at: now)
        let plan = ExercisePlan(exercise: focus, sets: [.init(load: 100, reps: 10)])
        for daysAgo in [4, 2] {
            let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let workout = UUID()
            store.modelContext.insert(StoredExerciseSession(RecordedExerciseSession(
                workoutID: workout, exerciseID: focus.id, startedAt: start, plan: plan,
                completion: .completed, completedAt: start.addingTimeInterval(120),
                updatedAt: start.addingTimeInterval(120))))
            store.modelContext.insert(StoredSetLog(SetRecord(
                exerciseID: focus.id, load: 100, reps: 10, rpe: .seven,
                performedAt: start.addingTimeInterval(60), workoutID: workout,
                acceptedPlanID: plan.id, effortWasReported: true)))
        }
        store.modelContext.insert(StoredSetLog(SetRecord(
            exerciseID: known.id, load: 30, reps: 10,
            performedAt: now.addingTimeInterval(-4 * 86_400 + 180))))
        try store.saveChanges()

        func assertEquivalent(completed: Int, due: Exercise) throws -> ExerciseRecommendation {
            let history = try store.allSets()
            XCTAssertEqual(CycleEngine.completedSessions(of: routine.kind, history: history,
                templates: [routine], startingAt: config.effectiveTrainingSplit.startedAt), completed)
            XCTAssertEqual(routine.slots[1].dueCandidate(completionCount: completed), due.id)
            // Explicit expected roster is independent of the optimized roster helper.
            let expected = try XCTUnwrap(store.referenceWorkoutRecommendations(
                for: [focus, due], now: now)[focus.id])
            XCTAssertEqual(try store.recommendation(for: focus, now: now), expected)
            return expected
        }
        let knownRoster = try assertEquivalent(completed: 2, due: known)
        XCTAssertEqual(knownRoster.action, .addSet)

        // A new calendar-day log advances rotation without adding accepted-plan
        // evidence. The unknown accessory must now suppress the extra-set offer.
        let rotationLog = SetRecord(exerciseID: focus.id, load: 100, reps: 10,
                                   performedAt: now.addingTimeInterval(-86_400))
        try store.log(rotationLog)
        let unknownRoster = try assertEquivalent(completed: 3, due: unknown)
        XCTAssertEqual(unknownRoster.action, .hold)
        XCTAssertNotEqual(unknownRoster, knownRoster)
        let explicitlyChosen = try XCTUnwrap(store.referenceWorkoutRecommendations(
            for: [focus, known], now: now)[known.id])
        XCTAssertEqual(try store.recommendation(for: known, now: now), explicitlyChosen,
                       "requesting the non-due accessory preserves that explicit selection")

        XCTAssertTrue(try store.deleteSet(id: rotationLog.id))
        XCTAssertEqual(try assertEquivalent(completed: 2, due: known), knownRoster)
    }

    func testSnapshotPreservesSessionIdentityOrderingExclusionsAndLegacyEvidence() throws {
        let store = try TrainingStore.inMemory()
        let exercises = ["A", "B"].map {
            Exercise(name: $0, muscles: [.primary(.chest)], equipment: .dumbbell,
                     progressionRule: .doubleProgression(range: RepRange(8, 12)))
        }
        for exercise in exercises { try store.upsert(exercise) }
        let workouts = [UUID(), UUID()]
        for exercise in exercises {
            let plan = ExercisePlan(exercise: exercise, sets: [.init(load: 50, reps: 10)])
            for (index, workout) in workouts.enumerated() {
                let start = now.addingTimeInterval(Double(index) * 86_400 - 60)
                let intent = RecordedExerciseSession(
                    workoutID: workout, exerciseID: exercise.id, startedAt: start, plan: plan,
                    completion: .completed, completedAt: index == 0 ? start.addingTimeInterval(120) : nil,
                    updatedAt: start)
                store.modelContext.insert(StoredExerciseSession(intent))
                for setIndex in (0..<3).reversed() {
                    let record = SetRecord(exerciseID: exercise.id, load: setIndex == 0 ? 25 : 50,
                        reps: 10, rpe: .seven, isWarmup: setIndex == 0,
                        performedAt: start.addingTimeInterval(120), workoutID: workout,
                        acceptedPlanID: setIndex == 2 ? UUID() : plan.id,
                        effortWasReported: setIndex == 1 ? nil : true)
                    store.modelContext.insert(StoredSetLog(record))
                    if setIndex == 0 { store.modelContext.insert(StoredSetLog(record)) }
                }
            }
            store.modelContext.insert(StoredSetLog(SetRecord(
                exerciseID: exercise.id, load: 50, reps: 10, rpe: .seven, performedAt: now)))
        }
        try store.saveChanges()
        let library = try store.exercises()
        for excluded in [nil, workouts[0], workouts[1]] as [UUID?] {
            let expected = try library.flatMap { try store.exerciseExposures(for: $0.id, excluding: excluded) }
            XCTAssertEqual(try store.allExerciseExposures(excluding: excluded), expected)
            XCTAssertEqual(try store.workoutRecommendations(for: exercises, workoutID: excluded, now: now),
                           try store.referenceWorkoutRecommendations(for: exercises, workoutID: excluded, now: now))
        }
    }
}
