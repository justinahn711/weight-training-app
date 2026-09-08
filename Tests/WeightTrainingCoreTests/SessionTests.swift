import XCTest
@testable import WeightTrainingCore

final class PrescriptionTests: XCTestCase {

    private let bench = Exercise(
        name: "Flat Bench",
        muscles: [.primary(.chest)],
        equipment: .barbell,
        progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight)
    )

    private let incline = Exercise(
        name: "Incline DB Press",
        muscles: [.primary(.chest)],
        equipment: .dumbbell,
        progressionRule: .doubleProgression(range: RepRange(8, 12))
    )

    func testColdStartAdmitsItHasNoTarget() {
        let prescription = Prescription(exercise: incline, state: nil)
        XCTAssertTrue(prescription.isColdStart)
        XCTAssertNil(prescription.load)
        XCTAssertEqual(prescription.displayLine, "First time — just log it")
    }

    /// Reps and RPE still come from the rule on a cold start, so the input
    /// controls in #4 and #5 have something sane to centre on.
    func testColdStartStillCarriesRuleDefaults() {
        XCTAssertEqual(Prescription(exercise: incline, state: nil).reps, 8)
        XCTAssertEqual(Prescription(exercise: incline, state: nil).rpe, .eight)
        XCTAssertEqual(Prescription(exercise: bench, state: nil).reps, 5)
    }

    func testStoredTargetWins() {
        let state = ProgressState(
            exerciseID: incline.id,
            targetLoad: Load(70),
            targetReps: 11,
            targetRPE: RPE(8.5)
        )
        let prescription = Prescription(exercise: incline, state: state)
        XCTAssertFalse(prescription.isColdStart)
        XCTAssertEqual(prescription.load, Load(70))
        XCTAssertEqual(prescription.displayLine, "70 lb × 11 @ RPE 8.5")
    }

    /// A state that has a load but no explicit reps still falls back to the
    /// rule rather than showing a blank.
    func testPartialStateFallsBackToTheRule() {
        let state = ProgressState(exerciseID: incline.id, targetLoad: Load(70))
        let prescription = Prescription(exercise: incline, state: state)
        XCTAssertEqual(prescription.reps, 8)
        XCTAssertEqual(prescription.rpe, .eight)
    }

    /// The screen must never invent a target — that's the progression engine's
    /// job, and a fabricated number costs a working set.
    func testPrescriptionNeverInventsALoad() {
        let state = ProgressState(exerciseID: incline.id, targetReps: 12)
        XCTAssertNil(Prescription(exercise: incline, state: state).load)
    }
}

final class LastPerformanceTests: XCTestCase {
    private let exerciseID = UUID()
    private let day1 = Date(timeIntervalSince1970: 1_760_000_000)

    private func set(_ load: Double, _ reps: Int, at offset: TimeInterval,
                     warmup: Bool = false, rpe: RPE? = nil) -> SetRecord {
        SetRecord(exerciseID: exerciseID, load: Load(load), reps: reps,
                  rpe: rpe, isWarmup: warmup, performedAt: day1.addingTimeInterval(offset))
    }

    func testNoHistoryYieldsNothing() {
        XCTAssertNil(LastPerformance.mostRecent(in: []))
    }

    func testWarmupsOnlyYieldNothing() {
        let history = [set(45, 10, at: 0, warmup: true)]
        XCTAssertNil(LastPerformance.mostRecent(in: history),
                     "a warmup says nothing about what the lift can do")
    }

    func testPicksTheMostRecentSessionOnly() {
        let sevenDays: TimeInterval = 7 * 86_400
        let history = [
            set(65, 12, at: 0),
            set(65, 11, at: 200),
            set(70, 11, at: sevenDays),
            set(70, 10, at: sevenDays + 200),
            set(70, 8, at: sevenDays + 400),
        ]
        let last = LastPerformance.mostRecent(in: history)
        XCTAssertEqual(last?.sets.count, 3, "older session excluded")
        XCTAssertEqual(last?.displayLine, "70 lb × 11, 10, 8")
    }

    func testWarmupsExcludedFromTheSummary() {
        let history = [
            set(45, 10, at: 0, warmup: true),
            set(70, 11, at: 300),
            set(70, 10, at: 500),
        ]
        XCTAssertEqual(LastPerformance.mostRecent(in: history)?.displayLine, "70 lb × 11, 10")
    }

    /// A drop in load across the session has to stay visible, so the compact
    /// form is only used when every set shared a weight.
    func testMixedLoadsAreSpelledOut() {
        let history = [set(70, 8, at: 0), set(60, 10, at: 200)]
        XCTAssertEqual(
            LastPerformance.mostRecent(in: history)?.displayLine,
            "70 lb × 8, 60 lb × 10"
        )
    }

    func testTopSetIsTheHeaviest() {
        let history = [set(60, 12, at: 0), set(75, 6, at: 200), set(70, 8, at: 400)]
        XCTAssertEqual(LastPerformance.mostRecent(in: history)?.topSet?.load, Load(75))
    }

    func testSetsComeBackInPerformedOrder() {
        let history = [set(70, 8, at: 400), set(70, 11, at: 0), set(70, 10, at: 200)]
        XCTAssertEqual(
            LastPerformance.mostRecent(in: history)?.sets.map(\.reps),
            [11, 10, 8]
        )
    }
}

final class SessionTests: XCTestCase {

    private func exercise(_ name: String) -> Exercise {
        Exercise(
            name: name,
            muscles: [.primary(.chest)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
    }

    private func session(_ names: [String] = ["A", "B", "C"]) -> Session {
        Session(
            kind: .push,
            exercises: names.map {
                let lift = exercise($0)
                return SessionExercise(
                    exercise: lift,
                    prescription: Prescription(exercise: lift, state: nil)
                )
            }
        )
    }

    // MARK: - Navigation

    func testStartsOnTheFirstExercise() {
        XCTAssertEqual(session().current?.exercise.name, "A")
    }

    func testAdvanceMovesForwardAndStopsAtTheEnd() {
        var day = session()
        day.advance()
        XCTAssertEqual(day.current?.exercise.name, "B")
        day.advance()
        XCTAssertTrue(day.isOnLastExercise)
        day.advance()
        XCTAssertEqual(day.current?.exercise.name, "C", "must not run off the end")
    }

    func testGoBackStopsAtTheStart() {
        var day = session()
        day.goBack()
        XCTAssertEqual(day.current?.exercise.name, "A")
    }

    /// Jumping straight to a lift matters when the rack you wanted is taken.
    func testSelectJumpsToAnyExercise() {
        var day = session()
        let target = day.exercises[2].id
        day.select(exerciseID: target)
        XCTAssertEqual(day.current?.exercise.name, "C")
    }

    func testSelectingAnUnknownExerciseIsIgnored() {
        var day = session()
        day.select(exerciseID: UUID())
        XCTAssertEqual(day.current?.exercise.name, "A")
    }

    func testEmptyDayHasNoCurrentExercise() {
        let empty = Session(kind: .push, exercises: [])
        XCTAssertNil(empty.current)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Logging

    func testLoggingAttachesToTheRightExercise() {
        var day = session()
        let first = day.exercises[0].id
        day.log(SetRecord(exerciseID: first, load: Load(70), reps: 10, performedAt: Date()))
        XCTAssertEqual(day.exercises[0].loggedSets.count, 1)
        XCTAssertEqual(day.exercises[1].loggedSets.count, 0)
    }

    /// Sets are keyed by exercise, not by cursor position, so logging can't
    /// land on the wrong lift if the screen advanced in between.
    func testLoggingIgnoresTheCursor() {
        var day = session()
        let third = day.exercises[2].id
        day.log(SetRecord(exerciseID: third, load: Load(70), reps: 10, performedAt: Date()))
        XCTAssertEqual(day.currentIndex, 0)
        XCTAssertEqual(day.exercises[2].loggedSets.count, 1)
    }

    func testLoggingAnUnknownExerciseIsIgnored() {
        var day = session()
        day.log(SetRecord(exerciseID: UUID(), load: Load(70), reps: 10, performedAt: Date()))
        XCTAssertTrue(day.allLoggedSets.isEmpty)
    }

    func testStartedCountTracksExercisesTouched() {
        var day = session()
        XCTAssertEqual(day.startedCount, 0)
        day.log(SetRecord(exerciseID: day.exercises[0].id, load: Load(70), reps: 10, performedAt: Date()))
        day.log(SetRecord(exerciseID: day.exercises[0].id, load: Load(70), reps: 9, performedAt: Date()))
        XCTAssertEqual(day.startedCount, 1, "two sets on one lift is still one started")
    }

    func testWarmupsAreSeparableFromWorkingSets() {
        var day = session()
        let id = day.exercises[0].id
        let now = Date()
        day.log(SetRecord(exerciseID: id, load: Load(45), reps: 10, isWarmup: true, performedAt: now))
        day.log(SetRecord(exerciseID: id, load: Load(70), reps: 10, performedAt: now.addingTimeInterval(60)))
        XCTAssertEqual(day.exercises[0].loggedSets.count, 2)
        XCTAssertEqual(day.exercises[0].workingSets.count, 1)
    }

    // MARK: - Undo

    func testCorrectingASetKeepsItsPlaceAndLeavesOtherSetsUntouched() {
        var day = session(["A", "B"])
        let exerciseID = day.current!.id
        let first = SetRecord(
            exerciseID: exerciseID, load: Load(100), reps: 8,
            performedAt: Date(timeIntervalSince1970: 1_772_000_000)
        )
        let second = SetRecord(
            exerciseID: exerciseID, load: Load(105), reps: 7,
            performedAt: Date(timeIntervalSince1970: 1_772_000_100)
        )
        day.log(first)
        day.log(second)

        var corrected = first
        corrected.reps = 75
        corrected.isWarmup = true
        corrected.rpe = nil

        XCTAssertTrue(day.correctSet(corrected))
        XCTAssertEqual(day.exercises[0].loggedSets, [corrected, second])
        XCTAssertEqual(day.exercises[0].loggedSets.first?.reps, 75,
                       "correction must preserve actual reps beyond quick-entry ranges")
        XCTAssertEqual(day.currentIndex, 0)
    }

    func testCorrectionCannotMoveASetToAnotherExercise() {
        var day = session(["A", "B"])
        let original = SetRecord(
            exerciseID: day.exercises[0].id, load: Load(100), reps: 8,
            performedAt: Date(timeIntervalSince1970: 1_772_000_000)
        )
        day.log(original)

        let moved = SetRecord(
            id: original.id,
            exerciseID: day.exercises[1].id,
            load: original.load,
            reps: original.reps,
            performedAt: original.performedAt
        )

        XCTAssertFalse(day.correctSet(moved))
        XCTAssertEqual(day.exercises[0].loggedSets, [original])
    }

    /// The undo in #8 has to reach across exercises: a mistap is often noticed
    /// just after moving on, which is exactly when a per-exercise undo fails.
    func testUndoReachesBackwardAcrossExercises() {
        var day = session()
        let now = Date()
        let first = SetRecord(exerciseID: day.exercises[0].id, load: Load(70), reps: 10, performedAt: now)
        let second = SetRecord(exerciseID: day.exercises[1].id, load: Load(50), reps: 12,
                               performedAt: now.addingTimeInterval(300))
        day.log(first)
        day.log(second)
        day.advance()
        day.advance()

        XCTAssertEqual(day.undoLastSet(), second)
        XCTAssertEqual(day.undoLastSet(), first)
        XCTAssertNil(day.undoLastSet(), "nothing left to undo")
        XCTAssertTrue(day.allLoggedSets.isEmpty)
    }

    func testUndoRemovesTheLatestByTimeNotByPosition() {
        var day = session()
        let now = Date()
        let older = SetRecord(exerciseID: day.exercises[1].id, load: Load(50), reps: 12, performedAt: now)
        let newer = SetRecord(exerciseID: day.exercises[0].id, load: Load(70), reps: 10,
                              performedAt: now.addingTimeInterval(300))
        day.log(older)
        day.log(newer)
        XCTAssertEqual(day.undoLastSet(), newer)
    }

    func testAllLoggedSetsComeBackInPerformedOrder() {
        var day = session()
        let now = Date()
        day.log(SetRecord(exerciseID: day.exercises[1].id, load: Load(50), reps: 12,
                          performedAt: now.addingTimeInterval(300)))
        day.log(SetRecord(exerciseID: day.exercises[0].id, load: Load(70), reps: 10, performedAt: now))
        XCTAssertEqual(day.allLoggedSets.map(\.reps), [10, 12])
    }

    // MARK: - Reconfiguring the lift on screen (#98)

    private func machine() -> Exercise {
        Exercise(
            name: "Hack Squat",
            muscles: [.primary(.quads)],
            equipment: .plateLoaded,
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            loading: .unmeasuredMachine(sleeves: 2)
        )
    }

    private func onScreen(_ lift: Exercise, logged: [SetRecord] = []) -> Session {
        Session(kind: .legs, exercises: [
            SessionExercise(
                exercise: lift,
                prescription: Prescription(exercise: lift, state: nil),
                loggedSets: logged
            )
        ])
    }

    /// Correcting a machine mid-session reached the store and not the screen.
    ///
    /// `replaceCurrent` is the swap path and deliberately no-ops when the
    /// replacement is the same lift — re-inserting during a swap would discard
    /// sets logged against it. But a reconfiguration is the same lift by
    /// definition, so it was silently dropped: the corrected empty weight
    /// persisted while the session kept the old one, and the plate buttons it
    /// unlocks never appeared. Found on a phone, where force-quitting the app
    /// made the change show up.
    func testReconfiguringTheCurrentLiftTakesEvenThoughTheIdIsUnchanged() {
        var session = onScreen(machine())
        XCTAssertFalse(session.current!.exercise.loading!.isMeasured, "starts unmeasured")

        var measured = session.current!.exercise
        measured.loading = LoadingStyle(
            baseWeight: Load(75),
            sleeves: 2,
            availablePlates: measured.loading!.availablePlates,
            unit: .pounds
        )
        session.reconfigureCurrent(with: SessionExercise(
            exercise: measured,
            prescription: Prescription(exercise: measured, state: nil)
        ))

        XCTAssertEqual(
            session.current?.exercise.loading?.baseWeight, Load(75),
            "the correction has to reach the session, not only the store"
        )
        XCTAssertTrue(session.current!.exercise.loading!.isMeasured)
    }

    /// And the swap path keeps the guard that makes it safe.
    func testReplacingTheCurrentLiftWithItselfIsStillANoOp() {
        let lift = machine()
        let logged = SetRecord(
            exerciseID: lift.id, load: Load(100), reps: 8,
            performedAt: Date(timeIntervalSince1970: 1_772_000_000)
        )
        var session = onScreen(lift, logged: [logged])

        session.replaceCurrent(with: SessionExercise(
            exercise: lift,
            prescription: Prescription(exercise: lift, state: nil)
        ))

        XCTAssertEqual(
            session.current?.loggedSets.count, 1,
            "a swap onto the same lift must not discard what was logged against it"
        )
    }

    // MARK: - Swapping a lift the day has moved past (#120)

    /// A swap is decided in a sheet, and the day can move while it is open.
    ///
    /// `SessionView` stays alive beneath the swap sheet and the mic keeps
    /// listening, so a spoken "next exercise" advances the session between
    /// choosing a replacement and picking it. Targeting the current index then
    /// swapped whichever lift had become current and left the one being looked
    /// at untouched — two lifts wrong from one correct action, the same shape
    /// as the config write in #98.
    func testSwappingALiftTheDayHasMovedPastLandsOnThatLift() {
        var day = session(["A", "B", "C"])
        let opened = day.current!            // A, the lift the sheet was opened for
        day.advance()                        // "next exercise" — current is now B
        XCTAssertEqual(day.current?.exercise.name, "B")

        let replacement = SessionExercise(
            exercise: exercise("D"),
            prescription: Prescription(exercise: exercise("D"), state: nil)
        )
        day.replace(exerciseWithID: opened.id, with: replacement)

        XCTAssertEqual(day.exercises.map(\.exercise.name), ["D", "B", "C"],
                       "the swap lands where it was aimed")
        XCTAssertEqual(day.current?.exercise.name, "B",
                       "and the lift the day moved on to is untouched")
    }

    /// A lift that is no longer in the day at all is not a crash and not a
    /// silent write somewhere else.
    func testSwappingALiftThatIsNoLongerThereChangesNothing() {
        var day = session(["A", "B", "C"])
        let stranger = SessionExercise(
            exercise: exercise("Z"),
            prescription: Prescription(exercise: exercise("Z"), state: nil)
        )
        day.replace(exerciseWithID: UUID(), with: stranger)
        XCTAssertEqual(day.exercises.map(\.exercise.name), ["A", "B", "C"])
    }

    /// The identity guard still applies: swapping a lift for itself is a no-op,
    /// so sets logged against it this session survive.
    func testSwappingALiftForItselfKeepsWhatWasLoggedAgainstIt() {
        let lift = exercise("A")
        var day = Session(kind: .push, exercises: [
            SessionExercise(
                exercise: lift,
                prescription: Prescription(exercise: lift, state: nil),
                loggedSets: [SetRecord(exerciseID: lift.id, load: Load(100), reps: 8,
                                       performedAt: Date(timeIntervalSince1970: 1_772_000_000))]
            )
        ])
        day.replace(exerciseWithID: lift.id, with: SessionExercise(
            exercise: lift,
            prescription: Prescription(exercise: lift, state: nil)
        ))
        XCTAssertEqual(day.current?.loggedSets.count, 1)
    }

}
