import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

@MainActor
final class SessionLoadingTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private var incline: Exercise { ExerciseLibrary.push[0] }

    /// #16's done-when: opening push day fills every slot with a target.
    func testPushDayFillsEverySlotFromTheTemplate() throws {
        let session = try store.startSession(kind: .push)
        XCTAssertEqual(session.kind, .push)
        XCTAssertEqual(
            session.exercises.map(\.exercise.name),
            ["Incline DB Press", "Flat Bench", "Seated DB OHP",
             "Lateral Raise", "Tricep Pressdown", "Chest Fly"],
            "slot order, with the rotating slot showing the side that's due"
        )
        XCTAssertEqual(session.exercises.count, DayTemplateLibrary.push.slots.count)
        XCTAssertEqual(session.current?.exercise.name, "Incline DB Press")

        // Every filled slot carries the slot it's filling, so #18 can swap
        // without losing the job.
        for exercise in session.exercises {
            XCTAssertNotNil(exercise.slot, exercise.exercise.name)
        }
    }

    /// The other side of the rotating pair comes up next push day.
    func testTheRotatingSlotAlternatesBetweenSessions() throws {
        let fly = ExerciseLibrary.all.first { $0.name == "Chest Fly" }!
        XCTAssertEqual(try store.startSession(kind: .push).exercises.last?.exercise.name,
                       "Chest Fly")

        // Log a push session so one is on the books.
        let incline = ExerciseLibrary.all.first { $0.name == "Incline DB Press" }!
        try store.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                                rpe: RPE(8), performedAt: Date().addingTimeInterval(-86_400)))
        try store.log(SetRecord(exerciseID: fly.id, load: Load(50), reps: 12,
                                rpe: RPE(8), performedAt: Date().addingTimeInterval(-86_400)))

        XCTAssertEqual(try store.startSession(kind: .push).exercises.last?.exercise.name,
                       "Skull Crushers")
    }

    func testEveryDayLoads() throws {
        for kind in DayKind.allCases {
            let session = try store.startSession(kind: kind)
            XCTAssertEqual(
                session.exercises.count,
                DayTemplateLibrary.template(for: kind).slots.count,
                "\(kind.rawValue) day"
            )
        }
    }

    /// A fresh install has no targets, so the screen must say so rather than
    /// invent one.
    func testFreshInstallIsAllColdStarts() throws {
        let session = try store.startSession(kind: .push)
        for exercise in session.exercises {
            XCTAssertTrue(exercise.prescription.isColdStart, exercise.exercise.name)
            XCTAssertNil(exercise.lastPerformance)
            XCTAssertTrue(exercise.loggedSets.isEmpty)
        }
    }

    /// The session reads the *stored* exercise, so a corrected increment (#20)
    /// is what shows up at the rack.
    func testSessionUsesTheStoredExerciseNotTheLibraryDefinition() throws {
        var edited = incline
        edited.increment = LoadIncrement(pounds: 5)
        edited.name = "Incline DB Press (30°)"
        try store.upsert(edited)

        let session = try store.startSession(kind: .push)
        XCTAssertEqual(session.current?.exercise.name, "Incline DB Press (30°)")
        XCTAssertEqual(session.current?.exercise.increment.pounds, 5)
    }

    func testStoredTargetBecomesThePrescription() throws {
        try store.save(ProgressState(
            exerciseID: incline.id,
            targetLoad: Load(70),
            targetReps: 11,
            targetRPE: .eight
        ))

        let session = try store.startSession(kind: .push)
        XCTAssertEqual(session.current?.prescription.load, Load(70))
        XCTAssertEqual(session.current?.prescription.displayLine, "70 lb × 11 @ RPE 8")
    }

    func testPreviousSessionBecomesLastPerformance() throws {
        let lastWeek = Date().addingTimeInterval(-7 * 86_400)
        for (index, reps) in [11, 10, 8].enumerated() {
            try store.log(SetRecord(
                exerciseID: incline.id, load: Load(70), reps: reps, rpe: RPE(8),
                performedAt: lastWeek.addingTimeInterval(Double(index) * 200)
            ))
        }

        let session = try store.startSession(kind: .push)
        XCTAssertEqual(session.current?.lastPerformance?.displayLine, "70 lb × 11, 10, 8")
    }

    // MARK: - Resuming

    /// The app gets backgrounded constantly — by a call, by the screen locking,
    /// by being force-quit. Sets logged earlier today have to come back as part
    /// of the session, not vanish while sitting safely on disk.
    func testTodaysSetsAreRehydratedIntoTheSession() throws {
        let now = Date()
        let warmup = SetRecord(exerciseID: incline.id, load: Load(45), reps: 10,
                               isWarmup: true, performedAt: now.addingTimeInterval(-600))
        let working = SetRecord(exerciseID: incline.id, load: Load(70), reps: 12,
                                rpe: RPE(8), performedAt: now.addingTimeInterval(-300))
        try store.log(warmup)
        try store.log(working)

        let session = try store.startSession(kind: .push, startedAt: now)
        XCTAssertEqual(session.current?.loggedSets, [warmup, working])
        XCTAssertEqual(session.current?.workingSets.count, 1)
        XCTAssertEqual(session.startedCount, 1)
    }

    /// ...and today's work must not also be reported as "last time", which
    /// would show the same sets twice under two different headings.
    func testTodaysSetsAreExcludedFromLastPerformance() throws {
        let now = Date()
        let lastWeek = now.addingTimeInterval(-7 * 86_400)
        try store.log(SetRecord(exerciseID: incline.id, load: Load(65), reps: 12,
                                rpe: RPE(8), performedAt: lastWeek))
        try store.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 11,
                                rpe: RPE(8), performedAt: now.addingTimeInterval(-300)))

        let session = try store.startSession(kind: .push, startedAt: now)
        XCTAssertEqual(session.current?.lastPerformance?.displayLine, "65 lb × 12",
                       "last time is the previous session, not this one")
        XCTAssertEqual(session.current?.loggedSets.count, 1)
    }

    /// A lift the user deleted shouldn't reappear just because the day names it.
    func testDeletedExercisesAreSkipped() throws {
        // Simulate removal by seeding a store that never had the lift.
        let fresh = try TrainingStore.inMemory()
        let subset = Array(ExerciseLibrary.push.dropFirst())
        try fresh.upsert(subset)

        let session = try fresh.startSession(kind: .push)
        XCTAssertEqual(session.exercises.count, DayTemplateLibrary.push.slots.count - 1,
                       "the incline slot has no other candidate, so it drops")
        XCTAssertFalse(session.exercises.contains { $0.exercise.id == incline.id })
    }
}

/// The loop that makes the app more than a notebook: perform a session, and
/// next time the lift comes up it has a target.
///
/// The engine (#9, #10) and the store existed for several milestones without
/// anything connecting them, so every lift stayed on "first time — just log
/// it" forever. These tests are that connection.
@MainActor
final class ProgressionApplicationTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
        try store.seedLibraryIfNeeded()
        try store.seedTemplatesIfNeeded()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    private var incline: Exercise { ExerciseLibrary.all.first { $0.name == "Incline DB Press" }! }

    /// Log a first session blind, and the second one opens with a target.
    func testAColdLiftGainsATargetAfterOneSession() throws {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var session = try store.startSession(kind: .push, startedAt: day)
        XCTAssertTrue(try XCTUnwrap(session.current).prescription.isColdStart)

        for index in 0..<3 {
            let record = SetRecord(exerciseID: incline.id, load: Load(65), reps: 10,
                                   rpe: RPE(8),
                                   performedAt: day.addingTimeInterval(Double(index) * 200))
            try store.log(record)
            session.log(record)
        }
        try store.applyProgression(for: session, now: day)

        let next = try store.startSession(kind: .push,
                                          startedAt: day.addingTimeInterval(3 * 86_400))
        let prescription = try XCTUnwrap(next.current).prescription
        XCTAssertFalse(prescription.isColdStart)
        XCTAssertEqual(prescription.load, Load(65))
        XCTAssertEqual(prescription.reps, 11, "one more rep than the weakest set")
    }

    /// Leaving and re-entering a session must not be worth a load jump.
    func testApplyingTwiceInOneDayChangesNothingTheSecondTime() throws {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var session = try store.startSession(kind: .push, startedAt: day)
        let record = SetRecord(exerciseID: incline.id, load: Load(70), reps: 12,
                               rpe: RPE(8), performedAt: day)
        try store.log(record)
        session.log(record)

        let first = try store.applyProgression(for: session, now: day)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try store.progressState(forExercise: incline.id)?.consecutiveTopHits, 1)

        let second = try store.applyProgression(for: session, now: day)
        XCTAssertTrue(second.isEmpty, "already advanced today")
        XCTAssertEqual(try store.progressState(forExercise: incline.id)?.consecutiveTopHits, 1,
                       "walking out and back in is not a qualifying session")
    }

    /// Two sessions at the top of the range earn the jump, on the second.
    func testTwoCleanSessionsEarnALoadJump() throws {
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        let second = first.addingTimeInterval(3 * 86_400)

        for day in [first, second] {
            var session = try store.startSession(kind: .push, startedAt: day)
            for index in 0..<3 {
                let record = SetRecord(exerciseID: incline.id, load: Load(70), reps: 12,
                                       rpe: RPE(8),
                                       performedAt: day.addingTimeInterval(Double(index) * 200))
                try store.log(record)
                session.log(record)
            }
            try store.applyProgression(for: session, now: day)
        }

        let state = try XCTUnwrap(try store.progressState(forExercise: incline.id))
        XCTAssertEqual(state.targetLoad, Load(75), "the next dumbbell up")
        XCTAssertEqual(state.targetReps, 8, "back to the bottom of the range")
    }

    /// Exercises that weren't touched keep whatever they had.
    func testUntouchedExercisesAreLeftAlone() throws {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var session = try store.startSession(kind: .push, startedAt: day)
        let record = SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                               rpe: RPE(8), performedAt: day)
        try store.log(record)
        session.log(record)

        let applied = try store.applyProgression(for: session, now: day)
        XCTAssertEqual(applied.count, 1)
        let bench = ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
        XCTAssertNil(try store.progressState(forExercise: bench.id))
    }

    /// A warmup-only exercise produced no evidence, so it earns no target.
    func testWarmupsAloneDoNotAdvanceALift() throws {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var session = try store.startSession(kind: .push, startedAt: day)
        let record = SetRecord(exerciseID: incline.id, load: Load(45), reps: 10,
                               isWarmup: true, performedAt: day)
        try store.log(record)
        session.log(record)

        XCTAssertTrue(try store.applyProgression(for: session, now: day).isEmpty)
        XCTAssertNil(try store.progressState(forExercise: incline.id))
    }

    /// Missed sessions accumulate into a deload proposal, end to end.
    func testRepeatedMissesEventuallyProposeADeload() throws {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        try store.save(ProgressState(exerciseID: incline.id, targetLoad: Load(80),
                                     targetReps: 8))

        for index in 0..<2 {
            let day = start.addingTimeInterval(Double(index) * 3 * 86_400)
            var session = try store.startSession(kind: .push, startedAt: day)
            let record = SetRecord(exerciseID: incline.id, load: Load(80), reps: 5,
                                   rpe: RPE(9.5), performedAt: day)
            try store.log(record)
            session.log(record)
            try store.applyProgression(for: session, now: day)
        }

        let state = try XCTUnwrap(try store.progressState(forExercise: incline.id))
        XCTAssertEqual(state.stallCount, 2)
        let suggestion = DeloadDetector.evaluate(
            exercise: incline, state: state,
            history: try store.sets(forExercise: incline.id)
        )
        XCTAssertEqual(suggestion?.to, Load(70), "80 less 10%, snapped to a real dumbbell")
    }
}
