//
//  SessionViewModelTests.swift
//  ChickenBreastTests
//

import XCTest
import WeightTrainingCore
import WeightTrainingStore
@testable import ChickenBreast

/// Unit coverage for the app target (#181).
///
/// Before this target existed, a pure `SessionViewModel` computation like
/// `repChoices` — an `[Int]` derived from nothing at all — could only be
/// exercised by booting a simulator through `ChickenBreastUITests`, a 10-20
/// minute round trip. That gap is why #98, #125, #169 and #172 were each
/// found by a person in a gym instead of by `swift test`.
///
/// This suite deliberately stays on one side of a line: everything here reads
/// or mutates in-memory view-model state and touches nothing that requires a
/// device to behave correctly. `TrainingStore.inMemory()` is used because
/// `SessionViewModel.init` requires *a* store to exist, and a handful of
/// tests below do call `logSet`/`logWarmup` — a real write through that
/// in-memory store — where what's being asserted is plain view-model state
/// (`pendingLoad`, `pendingReps`, `session.current?.loggedSets`) rather than
/// anything about persistence, notifications, or `ActivityKit` itself; see
/// "Warmup ramp leads the exercise (#206)" below and the bottom of this file
/// for exactly what that does and doesn't cover, and why `advance`, `goBack`,
/// `select`, `skipRest` and `startRest` are still left for a UI or
/// integration test instead.
@MainActor
final class SessionViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func benchPress(loading: LoadingStyle? = nil) -> Exercise {
        Exercise(
            name: "Flat Bench",
            muscles: [.primary(.chest), .secondary(.triceps)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight),
            needsWarmupRamp: true,
            loading: loading
        )
    }

    private func lateralRaise() -> Exercise {
        Exercise(
            name: "Lateral Raise",
            muscles: [.primary(.sideDelts)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(12, 15))
        )
    }

    private func sessionExercise(
        _ exercise: Exercise,
        loggedSets: [SetRecord] = []
    ) -> SessionExercise {
        SessionExercise(
            exercise: exercise,
            prescription: Prescription(load: Load(135), reps: 5, rpe: .eight),
            loggedSets: loggedSets
        )
    }

    /// A warmup `SetRecord` at a rung's exact numbers, as if it had already
    /// been logged earlier today — used to simulate ramp progress without
    /// going through `logWarmup` (#206).
    private func warmupRecord(_ rung: WarmupSet, exerciseID: UUID) -> SetRecord {
        SetRecord(
            exerciseID: exerciseID,
            load: rung.load,
            reps: rung.reps,
            isWarmup: true,
            performedAt: Date()
        )
    }

    /// One exercise unless `extra` names more, all pre-seeded so the target
    /// row shows a realistic prescription rather than a cold start.
    private func makeViewModel(
        exercises: [Exercise] = [],
        extraCount: Int = 0
    ) throws -> SessionViewModel {
        let store = try TrainingStore.inMemory()
        var roster = exercises.isEmpty ? [benchPress()] : exercises
        for i in 0..<extraCount {
            roster.append(lateralRaise().renamed("Extra \(i)"))
        }
        let session = Session(kind: .push, exercises: roster.map { sessionExercise($0) })
        return SessionViewModel(store: store, session: session, draftID: UUID())
    }

    /// The `SessionExercise`-level counterpart to `makeViewModel(exercises:)`,
    /// for tests that need to control `loggedSets` directly — simulating ramp
    /// progress without going through `logWarmup` (#206).
    private func makeViewModel(sessionExercises: [SessionExercise]) throws -> SessionViewModel {
        let store = try TrainingStore.inMemory()
        let session = Session(kind: .push, exercises: sessionExercises)
        return SessionViewModel(store: store, session: session, draftID: UUID())
    }

    // MARK: - Next up: moving on once last time's set count is matched

    /// A dumbbell lift with no ramp, so `logSet()` writes a working set from
    /// the first tap, and a last performance of `sets` working sets.
    private func liftWithHistory(_ name: String, sets: Int) -> SessionExercise {
        let lift = lateralRaise().renamed(name)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            .addingTimeInterval(-3 * 86_400)
        let last = (0..<sets).map {
            SetRecord(exerciseID: lift.id, load: Load(20), reps: 12,
                      performedAt: noon.addingTimeInterval(Double($0) * 90))
        }
        return SessionExercise(
            exercise: lift,
            prescription: Prescription(load: Load(20), reps: 12, rpe: .eight),
            lastPerformance: sets > 0 ? LastPerformance(performedAt: noon, sets: last) : nil
        )
    }

    private func autoAdvanceViewModel(lastSets: Int = 2) throws -> SessionViewModel {
        UserDefaults.standard.set(true, forKey: RestAlertSettings.autoAdvanceKey)
        return try makeViewModel(sessionExercises: [
            liftWithHistory("First", sets: lastSets),
            liftWithHistory("Second", sets: 3),
        ])
    }

    func test_pendingAdvance_armsOnTheSetThatMatchesLastTime() throws {
        let vm = try autoAdvanceViewModel(lastSets: 2)
        vm.logSet()
        XCTAssertNil(vm.pendingAdvance, "one short of last time is not done")
        vm.logSet()
        XCTAssertEqual(vm.pendingAdvance?.exercise.name, "Second")
        XCTAssertEqual(vm.current?.exercise.name, "First", "armed, not moved: the rest is still running")
    }

    func test_pendingAdvance_neverArmsOnAFirstOuting() throws {
        let vm = try autoAdvanceViewModel(lastSets: 0)
        vm.logSet(); vm.logSet(); vm.logSet()
        XCTAssertNil(vm.pendingAdvance, "unknown means silent")
    }

    func test_pendingAdvance_neverArmsWhenSwitchedOff() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        UserDefaults.standard.set(false, forKey: RestAlertSettings.autoAdvanceKey)
        defer { UserDefaults.standard.set(true, forKey: RestAlertSettings.autoAdvanceKey) }
        vm.logSet()
        XCTAssertNil(vm.pendingAdvance)
    }

    func test_pendingAdvance_neverArmsOnTheLastExercise() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.advance()
        vm.logSet(); vm.logSet(); vm.logSet()
        XCTAssertNil(vm.pendingAdvance, "there is nowhere to go; finishing stays deliberate")
    }

    func test_stay_disarmsAndGoingBeyondDoesNotReArm() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        XCTAssertNotNil(vm.pendingAdvance)
        vm.stayOnCurrentExercise()
        XCTAssertNil(vm.pendingAdvance)
        vm.logSet()
        XCTAssertNil(vm.pendingAdvance, "equality is exact: set two of a usual one re-arms nothing")
        vm.restDidComplete()
        XCTAssertEqual(vm.current?.exercise.name, "First")
    }

    func test_undoingTheArmingSet_disarms() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        let id = try XCTUnwrap(vm.recentlyLoggedSet?.id)
        vm.undoRecentlyLoggedSet(id: id)
        XCTAssertNil(vm.pendingAdvance)
    }

    func test_restDidComplete_movesOnAndLeavesAWayBack() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        vm.restDidComplete()
        XCTAssertEqual(vm.current?.exercise.name, "Second")
        XCTAssertNil(vm.pendingAdvance)
        XCTAssertNil(vm.rest, "a finished rest has nothing to say on the next lift")
        XCTAssertEqual(vm.autoAdvancedFrom?.exercise.name, "First")
        XCTAssertNil(vm.recentlyLoggedSet, "the undo offer belongs to the lift just left (#169)")

        vm.undoAutoAdvance()
        XCTAssertEqual(vm.current?.exercise.name, "First")
        XCTAssertNil(vm.autoAdvancedFrom)
    }

    func test_movedOnNotice_staysUntilTheFirstSetOnTheNewLift() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        vm.restDidComplete()
        XCTAssertEqual(vm.autoAdvancedFrom?.exercise.name, "First")
        vm.logSet()
        XCTAssertNil(vm.autoAdvancedFrom, "logging on the new lift is the action the notice waits for")
    }

    func test_restDidComplete_doesNothingWhenNothingIsArmed() throws {
        let vm = try autoAdvanceViewModel(lastSets: 2)
        vm.logSet()
        vm.restDidComplete()
        XCTAssertEqual(vm.current?.exercise.name, "First")
    }

    func test_skipRest_whileArmed_movesOnNow() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        vm.skipRest()
        XCTAssertEqual(vm.current?.exercise.name, "Second")
        XCTAssertEqual(vm.autoAdvancedFrom?.exercise.name, "First")
    }

    func test_manualNavigation_disarms() throws {
        let vm = try autoAdvanceViewModel(lastSets: 1)
        vm.logSet()
        vm.advance()
        XCTAssertNil(vm.pendingAdvance)
        XCTAssertNil(vm.autoAdvancedFrom, "a move the lifter made needs no way back offered")
    }

    // MARK: - The rest clock gives up ten minutes past target

    func test_expireRestIfNeeded_clearsAClockTenMinutesPastTarget() throws {
        let vm = try makeViewModel()
        vm.pendingLoad = Load(135)
        vm.setPendingReps(5)
        vm.logSet()
        let rest = try XCTUnwrap(vm.rest, "logging a working set starts a rest")

        vm.expireRestIfNeeded(now: rest.endsAt.addingTimeInterval(599))
        XCTAssertNotNil(vm.rest, "still inside the overrun the clock keeps counting")

        vm.expireRestIfNeeded(now: rest.expiresAt)
        XCTAssertNil(vm.rest)
        XCTAssertNotNil(vm.recentlyLoggedSet, "the set stays logged; only the clock gives up")
        XCTAssertEqual(vm.current?.loggedSets.count, 1)
    }

    func test_expireRestIfNeeded_doesNothingWithoutARest() throws {
        let vm = try makeViewModel()
        vm.expireRestIfNeeded(now: Date().addingTimeInterval(100_000))
        XCTAssertNil(vm.rest)
    }

    // MARK: - Zero load is not a set (critique: unknown means silent)

    private func coldStartViewModel(equipment: Equipment) throws -> SessionViewModel {
        let lift = Exercise(
            name: "Cold \(equipment.rawValue)",
            muscles: [.primary(.chest)],
            equipment: equipment,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
        return try makeViewModel(sessionExercises: [SessionExercise(
            exercise: lift,
            prescription: Prescription(load: nil, reps: 10, rpe: .eight)
        )])
    }

    func test_canLogSet_falseForAColdStartDumbbellAtZero() throws {
        let vm = try coldStartViewModel(equipment: .dumbbell)
        XCTAssertEqual(vm.pendingLoad, .zero, "sanity: a cold-start dumbbell opens at zero")
        XCTAssertFalse(vm.canLogSet)
    }

    func test_logSet_atZeroOnLoadedEquipment_writesNothing() throws {
        let vm = try coldStartViewModel(equipment: .machineStack)
        vm.logSet()
        vm.logSet(isWarmup: true)
        XCTAssertTrue(vm.session.current?.loggedSets.isEmpty ?? false,
                      "a tap on a zero load must not write 0 lb into history")
        XCTAssertNil(vm.recentlyLoggedSet)
    }

    func test_canLogSet_trueOnceAWeightIsSet() throws {
        let vm = try coldStartViewModel(equipment: .dumbbell)
        vm.pendingLoad = Load(20)
        XCTAssertTrue(vm.canLogSet)
        vm.logSet()
        XCTAssertEqual(vm.session.current?.loggedSets.count, 1)
    }

    func test_canLogSet_trueForBodyweightAtZeroAddedLoad() throws {
        let vm = try coldStartViewModel(equipment: .bodyweight)
        vm.pendingLoad = .zero
        XCTAssertTrue(vm.canLogSet, "zero added load is a real bodyweight set")
    }

    // MARK: - Records at log time

    /// A dumbbell lift with `history` already on disk from three days ago.
    private func viewModelWithHistory(_ history: [(load: Double, reps: Int)]) throws -> SessionViewModel {
        let store = try TrainingStore.inMemory()
        let lift = lateralRaise()
        try store.create(lift)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
            .addingTimeInterval(-3 * 86_400)
        for (index, set) in history.enumerated() {
            // Scored like the sets `logSet` writes, or a matching set would
            // beat them on RPE-adjusted estimated max.
            try store.log(SetRecord(exerciseID: lift.id, load: Load(set.load), reps: set.reps, rpe: .eight,
                                    performedAt: noon.addingTimeInterval(Double(index) * 90)))
        }
        let session = Session(kind: .push, exercises: [SessionExercise(
            exercise: lift, prescription: Prescription(load: Load(20), reps: 12, rpe: .eight)
        )])
        return SessionViewModel(store: store, session: session, draftID: UUID())
    }

    func test_logSet_firstOutingIsNotARecord() throws {
        let vm = try viewModelWithHistory([])
        vm.logSet()
        XCTAssertNil(vm.recentRecord, "a first session is a data point, not a record (#70)")
        XCTAssertTrue(vm.recordSetIDs.isEmpty)
    }

    func test_logSet_beatingEarlierTodayOnANewLiftIsNotARecord() throws {
        let vm = try viewModelWithHistory([])
        vm.pendingLoad = Load(20)
        vm.logSet()
        vm.pendingLoad = Load(30)
        vm.logSet()
        XCTAssertNil(vm.recentRecord, "records are judged against previous days, not the warm-up to a first session")
    }

    func test_logSet_heavierThanEverIsARecordAndUndoTakesItBack() throws {
        let vm = try viewModelWithHistory([(20, 12), (20, 12)])
        vm.pendingLoad = Load(25)
        vm.logSet()
        let logged = try XCTUnwrap(vm.recentlyLoggedSet)
        XCTAssertEqual(vm.recentRecord?.kind, .heaviest(Load(25)))
        XCTAssertEqual(vm.recentRecord?.set.id, logged.id)
        XCTAssertTrue(vm.recordSetIDs.contains(logged.id))

        vm.undoRecentlyLoggedSet(id: logged.id)
        XCTAssertNil(vm.recentRecord)
        XCTAssertFalse(vm.recordSetIDs.contains(logged.id))
    }

    func test_logSet_matchingHistoryIsNotARecord() throws {
        let vm = try viewModelWithHistory([(20, 12)])
        vm.pendingLoad = Load(20)
        vm.setPendingReps(12)
        vm.logSet()
        XCTAssertNil(vm.recentRecord)
    }

    func test_logSet_moreRepsAtTheSameWeightIsARecord_headlinedBelowHeaviest() throws {
        let vm = try viewModelWithHistory([(20, 12)])
        vm.pendingLoad = Load(20)
        vm.setPendingReps(14)
        vm.logSet()
        XCTAssertEqual(vm.recentRecord?.kind, .reps(14, at: Load(20)))
    }

    func test_dismissingTheBanner_keepsTheRowBadge() throws {
        let vm = try viewModelWithHistory([(20, 12)])
        vm.pendingLoad = Load(25)
        vm.logSet()
        let id = try XCTUnwrap(vm.recentlyLoggedSet?.id)
        vm.dismissRecentSetUndo(id: id)
        XCTAssertNil(vm.recentRecord)
        XCTAssertTrue(vm.recordSetIDs.contains(id))
    }

    // MARK: - Warmup ramp leads the exercise (#206)
    //
    // `seedPendingFromCurrent` runs inside `init`, so building a view model is
    // enough to exercise it without calling any of the store-writing methods
    // excluded at the bottom of this file — except where a test is explicitly
    // about `logSet`/`logWarmup`'s own new behavior, which follows the same
    // precedent `test_reconcile_*` above already set: the in-memory store and
    // a test host with Live Activities disabled make those calls safe here,
    // see the note at the end of this file for exactly what that covers.

    /// The done-when this issue names first: a plate-built lift with a ramp
    /// still ahead of it seeds the first rung, not the working weight.
    func test_seedPendingFromCurrent_seedsFirstUnloggedRungWhenRampIsActive() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))
        let firstRung = try XCTUnwrap(ramp.first)

        XCTAssertEqual(vm.nextWarmupRung, firstRung)
        XCTAssertEqual(vm.pendingLoad, firstRung.load)
        XCTAssertEqual(vm.pendingReps, firstRung.reps)
        XCTAssertTrue(vm.isOnActiveWarmupRung)
    }

    /// The regression this issue asks to guard hardest against: a lift
    /// ineligible for a ramp (#157's `equipment.isPlateBuilt`) must seed
    /// exactly like it always has — the working weight, no rung involved.
    func test_seedPendingFromCurrent_seedsWorkingWeightWhenNoRampIsEligible() throws {
        let vm = try makeViewModel(sessionExercises: [sessionExercise(lateralRaise())])

        XCTAssertNil(vm.nextWarmupRung)
        XCTAssertTrue(vm.warmupRamp.isEmpty)
        XCTAssertEqual(vm.pendingLoad, Load(135), "the prescription's load, unchanged by this issue")
        XCTAssertFalse(vm.isOnActiveWarmupRung)
    }

    /// Rungs already logged earlier today — before this view model even
    /// existed, e.g. a resumed draft — are skipped rather than re-suggested.
    func test_seedPendingFromCurrent_skipsRungsAlreadyLoggedToday() throws {
        let bench = benchPress()
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))
        let alreadyDone = ramp.prefix(2).map { warmupRecord($0, exerciseID: bench.id) }
        let vm = try makeViewModel(sessionExercises: [
            sessionExercise(bench, loggedSets: Array(alreadyDone))
        ])

        XCTAssertEqual(vm.nextWarmupRung, ramp[2])
        XCTAssertEqual(vm.pendingLoad, ramp[2].load)
        XCTAssertEqual(vm.pendingReps, ramp[2].reps)
    }

    /// Every rung already logged: the ramp is exhausted, so seeding falls
    /// through to the working weight exactly as a lift with no ramp does.
    func test_seedPendingFromCurrent_landsOnWorkingWeightOnceRampIsExhausted() throws {
        let bench = benchPress()
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))
        let allDone = ramp.map { warmupRecord($0, exerciseID: bench.id) }
        let vm = try makeViewModel(sessionExercises: [
            sessionExercise(bench, loggedSets: allDone)
        ])

        XCTAssertNil(vm.nextWarmupRung)
        XCTAssertEqual(vm.pendingLoad, Load(135))
        XCTAssertFalse(vm.isOnActiveWarmupRung)
    }

    /// `isOnActiveWarmupRung` reflects the numbers on screen, not just
    /// whether a rung exists — editing the stepper away from the suggestion
    /// is what lets a working set through without a separate escape hatch
    /// (the "must not trap" constraint in #206).
    func test_isOnActiveWarmupRung_falseOnceThePendingValuesAreEdited() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        XCTAssertTrue(vm.isOnActiveWarmupRung)

        vm.adjustLoad(by: 1)

        XCTAssertFalse(vm.isOnActiveWarmupRung, "the stepper moved the form off the suggested rung")
        XCTAssertNotNil(vm.nextWarmupRung, "the rung itself is still there to log — nothing was decided for the lifter")
    }

    /// The one control #206 asks for: skipping jumps straight to the working
    /// weight and the ramp stops being offered, in one tap.
    func test_clearWarmupRamp_jumpsToWorkingWeightAndHidesTheRamp() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        XCTAssertTrue(vm.isOnActiveWarmupRung, "sanity: starts on a rung")

        vm.clearWarmupRamp()

        XCTAssertTrue(vm.warmupRamp.isEmpty)
        XCTAssertNil(vm.nextWarmupRung)
        XCTAssertEqual(vm.pendingLoad, Load(135), "skip lands on the working weight, not wherever the stepper was")
    }

    /// Logging the rung the form is seeded to logs it as a warmup — never
    /// working volume — and advances to the next rung.
    func test_logSet_onActiveRung_logsAsWarmupAndAdvancesToTheNextRung() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))

        vm.logSet()

        let logged = try XCTUnwrap(vm.session.current?.loggedSets.last)
        XCTAssertTrue(logged.isWarmup)
        XCTAssertEqual(logged.load, ramp[0].load)
        XCTAssertEqual(logged.reps, ramp[0].reps)
        XCTAssertEqual(vm.pendingLoad, ramp[1].load, "advanced to the second rung")
        XCTAssertEqual(vm.pendingReps, ramp[1].reps)
        XCTAssertTrue(vm.session.current!.workingSets.isEmpty, "a rung never counts as working volume")
    }

    /// Logging every rung in turn ends on the working weight, exactly as the
    /// issue's done-when describes — no rung left dangling.
    func test_logSet_repeatedThroughTheWholeRamp_endsOnTheWorkingWeight() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))

        for _ in ramp {
            XCTAssertNotNil(vm.nextWarmupRung, "still expects a rung before logging it")
            vm.logSet()
        }

        XCTAssertNil(vm.nextWarmupRung)
        XCTAssertEqual(vm.pendingLoad, Load(135))
        XCTAssertFalse(vm.isOnActiveWarmupRung)
        XCTAssertEqual(vm.session.current?.loggedSets.filter(\.isWarmup).count, ramp.count)
        XCTAssertTrue(vm.session.current!.workingSets.isEmpty, "still nothing but warmups on the books")
    }

    /// The load-bearing constraint: someone can log a working set while the
    /// form sits on a warmup rung, just by dialling in the working numbers
    /// first — the app suggests the rung, it never gets to insist.
    func test_logSet_afterEditingOffTheRung_logsAWorkingSetInstead() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        XCTAssertTrue(vm.isOnActiveWarmupRung, "sanity: starts on a rung")

        vm.pendingLoad = Load(135)
        vm.setPendingReps(5)
        XCTAssertFalse(vm.isOnActiveWarmupRung)

        vm.logSet()

        let logged = try XCTUnwrap(vm.session.current?.loggedSets.last)
        XCTAssertFalse(logged.isWarmup, "a working set, not a warmup, despite a ramp still being active moments ago")
        XCTAssertEqual(logged.load, Load(135))
        XCTAssertNotNil(logged.rpe, "working sets are scored")
        XCTAssertTrue(vm.warmupRamp.isEmpty, "the ramp is retired the moment a working set lands (#15)")
    }

    /// `logWarmup(_:)` — the entry point a tappable rung row calls directly —
    /// logs exactly the rung passed, ignoring whatever the stepper currently
    /// holds, and still advances the form afterward.
    func test_logWarmup_logsTheExactRungPassedRegardlessOfPendingValues() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        let ramp = WarmupRamp.generate(for: bench, workingLoad: Load(135))
        vm.pendingLoad = Load(999)
        vm.setPendingReps(17)

        vm.logWarmup(ramp[0])

        let logged = try XCTUnwrap(vm.session.current?.loggedSets.last)
        XCTAssertEqual(logged.load, ramp[0].load, "the rung's own number, not the stray pending value")
        XCTAssertEqual(logged.reps, ramp[0].reps)
        XCTAssertEqual(vm.pendingLoad, ramp[1].load, "advances the same way logSet's dispatch does")
    }

    /// `Extra warmup` (#157's explicit escape hatch) survives this change
    /// unchanged: it always logs whatever is dialled in as an unplanned
    /// warmup and never advances the ramp itself — see "Decisions the owner
    /// should confirm" in the PR for why it wasn't subsumed.
    func test_logSet_explicitWarmupTrue_doesNotConsultTheRampAndDoesNotAdvance() throws {
        let bench = benchPress()
        let vm = try makeViewModel(sessionExercises: [sessionExercise(bench)])
        let seededLoad = vm.pendingLoad
        let seededReps = vm.pendingReps

        vm.logSet(isWarmup: true)

        let logged = try XCTUnwrap(vm.session.current?.loggedSets.last)
        XCTAssertTrue(logged.isWarmup)
        XCTAssertEqual(logged.load, seededLoad)
        XCTAssertNil(logged.rpe, "warmups are never scored")
        XCTAssertEqual(vm.pendingLoad, seededLoad, "Extra warmup leaves the stepper exactly where it was (#170)")
        XCTAssertEqual(vm.pendingReps, seededReps)
    }

    // MARK: - adjustRPE — the inline stepper's step through RPE.sessionChips

    func test_adjustRPE_stepsThroughSessionChipsInOrder() throws {
        let vm = try makeViewModel()
        vm.pendingRPE = .eight
        vm.adjustRPE(by: 1)
        XCTAssertEqual(vm.pendingRPE, RPE(8.5))
        vm.adjustRPE(by: 1)
        XCTAssertEqual(vm.pendingRPE, .nine)
        vm.adjustRPE(by: -2)
        XCTAssertEqual(vm.pendingRPE, .eight)
    }

    func test_adjustRPE_clampsAtBothEnds() throws {
        let vm = try makeViewModel()
        vm.pendingRPE = .six
        vm.adjustRPE(by: -1)
        XCTAssertEqual(vm.pendingRPE, .six, "six is the floor chip; stepping down further does nothing")

        vm.pendingRPE = .ten
        vm.adjustRPE(by: 1)
        XCTAssertEqual(vm.pendingRPE, .ten)
    }

    /// `pendingRPE` can start on 6.5 — `sessionChips` omits it, but voice
    /// parsing and a stored `ProgressState` both reach the wider
    /// `RPE.allowedValues` grid. A step from there must land somewhere on
    /// the chip grid rather than silently doing nothing.
    func test_adjustRPE_fromAnOffGridValue_snapsOntoTheChipGrid() throws {
        let vm = try makeViewModel()
        vm.pendingRPE = RPE(6.5)!
        vm.adjustRPE(by: 1)
        XCTAssertEqual(vm.pendingRPE, .seven, "one step up from the nearest chip at or below 6.5")

        vm.pendingRPE = RPE(6.5)!
        vm.adjustRPE(by: -1)
        XCTAssertEqual(vm.pendingRPE, .six, "one step down from the nearest chip at or below 6.5")
    }

    // MARK: - repChoices (#171, #181)

    /// The reason this issue exists: a pure `[Int]` that used to require a
    /// simulator to check at all.
    func test_repChoices_isFixedOneThroughTwenty() throws {
        let vm = try makeViewModel()
        XCTAssertEqual(vm.repChoices, Array(1...20))
    }

    /// #171's whole point was that the row no longer moves: a 13-rep target
    /// and a 5-rep target must produce the identical row.
    func test_repChoices_isIndependentOfTheTarget() throws {
        let fiveRepTarget = try makeViewModel(exercises: [benchPress()])
        let heavyRow = fiveRepTarget.repChoices

        let thirteenRepExercise = Exercise(
            name: "Leg Press",
            muscles: [.primary(.quads)],
            equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        )
        let highRepTarget = try makeViewModel(exercises: [thirteenRepExercise])

        XCTAssertEqual(heavyRow, highRepTarget.repChoices)
        XCTAssertEqual(highRepTarget.repChoices.first, 1)
        XCTAssertEqual(highRepTarget.repChoices.last, 20)
    }

    // MARK: - usesOtherRepCount

    /// The common case: whatever the row already offers needs no escape hatch.
    func test_usesOtherRepCount_falseForAnyChoiceOnTheRow() throws {
        let vm = try makeViewModel()
        for reps in [1, 8, 20] {
            vm.setPendingReps(reps)
            XCTAssertFalse(vm.usesOtherRepCount, "\(reps) is on the fixed row and should not need Other")
        }
    }

    /// #131's escape hatch: a myo-rep or drop-set count above 20 is exactly
    /// the case the fixed row was documented to give up (SessionViewModel.swift).
    func test_usesOtherRepCount_trueAboveTwenty() throws {
        let vm = try makeViewModel()
        vm.setPendingReps(25)
        XCTAssertTrue(vm.usesOtherRepCount)
    }

    /// `adjustReps` is the stepper path rather than a tapped chip; it should
    /// agree with `setPendingReps` about what counts as "on the row".
    func test_usesOtherRepCount_reflectsStepperAdjustments() throws {
        let vm = try makeViewModel()
        vm.setPendingReps(20)
        XCTAssertFalse(vm.usesOtherRepCount)
        vm.adjustReps(by: 1)
        XCTAssertEqual(vm.pendingReps, 21)
        XCTAssertTrue(vm.usesOtherRepCount)
    }

    // MARK: - progressLabel

    func test_progressLabel_firstOfOne() throws {
        let vm = try makeViewModel(exercises: [benchPress()])
        XCTAssertEqual(vm.progressLabel, "1 of 1")
    }

    func test_progressLabel_countsTheWholeRoster() throws {
        let vm = try makeViewModel(extraCount: 4)
        XCTAssertEqual(vm.progressLabel, "1 of 5")
    }

    // MARK: - plateOptions (#39)

    /// No base weight recorded means the app doesn't know what the plates
    /// are being added to — the row must stay empty rather than guess.
    ///
    /// `loading: nil` on a barbell would resolve to `.olympicBarbell` (a
    /// *measured* default, per `Equipment.defaultLoadingStyle`), so the
    /// unmeasured case has to be constructed explicitly rather than by
    /// omission.
    func test_plateOptions_emptyWhenApparatusUnmeasured() throws {
        let unmeasured = LoadingStyle(baseWeight: nil, sleeves: 2)
        let vm = try makeViewModel(exercises: [benchPress(loading: unmeasured)])
        XCTAssertEqual(vm.plateOptions, [])
    }

    /// Once measured, the row is the configured plates, heaviest first.
    func test_plateOptions_sortedDescendingWhenMeasured() throws {
        let loading = LoadingStyle(
            baseWeight: Load(45),
            sleeves: 2,
            availablePlates: [10, 45, 25, 5]
        )
        let vm = try makeViewModel(exercises: [benchPress(loading: loading)])
        XCTAssertEqual(vm.plateOptions, [45, 25, 10, 5])
    }

    // MARK: - reconcilePersistedSetsAfterHistoryEdit (#199)

    /// Unlike `logSet`/`skipRest`/`undoRecentlyLoggedSet` below, this method
    /// is safe to bring under this suite even though it reaches `store`,
    /// `RestNotification` and `SessionActivityController`: it never *writes*
    /// through the store (only `resumeSession`'s read), `RestNotification.
    /// cancel()` is a synchronous, unauthorized-safe no-op, and
    /// `SessionActivityController.start()`/`currentState()` both guard on
    /// `ActivityAuthorizationInfo().areActivitiesEnabled` — false in this test
    /// host, so they return immediately. What makes #169/#172/#173 unsafe to
    /// test here (an async schedule, a real ActivityKit request) never
    /// triggers on this path.
    ///
    /// `TrainingStore.inMemory()` needs its library seeded so `resumeSession`
    /// can resolve the exercise id back to an `Exercise` — without a seeded
    /// row, its lookup drops the exercise and the resumed session comes back
    /// empty regardless of what was logged.
    private func makeReconcilableViewModel() throws -> (vm: SessionViewModel, store: TrainingStore) {
        let store = try TrainingStore.inMemory()
        let seeded = try store.seedLibraryIfNeeded()
        let exercise = try XCTUnwrap(seeded.first)
        let sessionExercise = SessionExercise(
            exercise: exercise,
            prescription: Prescription(load: Load(135), reps: 5, rpe: .eight)
        )
        // Fixed and in the past so every `SetRecord.performedAt` logged
        // during the test (stamped with the real clock) safely lands after
        // it — `resumeSession` drops anything performed before the draft's
        // `startedAt`.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = Session(kind: .push, exercises: [sessionExercise], startedAt: start)
        let vm = SessionViewModel(store: store, session: session, draftID: UUID())
        return (vm, store)
    }

    /// The shape #199 describes end to end: History deletes the one set the
    /// session was resting on and offering to undo, from a different tab,
    /// while the session's route stays alive. Both stale pointers must clear.
    func test_reconcile_clearsUndoBannerAndRestForADeletedSet() throws {
        let (vm, store) = try makeReconcilableViewModel()
        vm.logSet()
        let logged = try XCTUnwrap(vm.recentlyLoggedSet)
        XCTAssertNotNil(vm.rest, "a working set starts a rest")

        // Stands in for `HistoryView`'s delete, which writes through the
        // store directly rather than through this view model.
        _ = try store.deleteSet(id: logged.id)

        vm.reconcilePersistedSetsAfterHistoryEdit()

        XCTAssertNil(vm.recentlyLoggedSet)
        XCTAssertNil(vm.rest)
        XCTAssertFalse(vm.session.allLoggedSets.contains { $0.id == logged.id })
    }

    /// The gap the prior-art branch (`feat/168-bulk-delete`, PR #186) left:
    /// its check only cancelled a rest nested inside "the banner still names
    /// this set", so a rest surviving `dismissRecentSetUndo` — which clears
    /// the banner without touching the rest it started — kept counting down
    /// for a set already gone from disk. Checked independently here.
    func test_reconcile_cancelsAnOrphanedRestEvenAfterItsBannerWasDismissed() throws {
        let (vm, store) = try makeReconcilableViewModel()
        vm.logSet()
        let logged = try XCTUnwrap(vm.recentlyLoggedSet)
        vm.dismissRecentSetUndo(id: logged.id)
        XCTAssertNil(vm.recentlyLoggedSet, "dismissing only clears the banner")
        XCTAssertEqual(vm.rest?.setID, logged.id, "not the rest it started")

        _ = try store.deleteSet(id: logged.id)
        vm.reconcilePersistedSetsAfterHistoryEdit()

        XCTAssertNil(vm.rest, "the rest must not survive the set that started it")
    }

    /// Deleting a set that is neither the current undo offer nor the rest's
    /// owner must leave both alone — reconciling is not a reason to discard
    /// state a History edit elsewhere on the day never touched.
    func test_reconcile_leavesUnrelatedStateAloneWhenAnOlderSetIsDeleted() throws {
        let (vm, store) = try makeReconcilableViewModel()
        vm.logSet()
        let first = try XCTUnwrap(vm.recentlyLoggedSet)
        vm.logSet()
        let second = try XCTUnwrap(vm.recentlyLoggedSet)
        XCTAssertNotEqual(first.id, second.id)

        _ = try store.deleteSet(id: first.id)
        vm.reconcilePersistedSetsAfterHistoryEdit()

        XCTAssertEqual(vm.recentlyLoggedSet?.id, second.id)
        XCTAssertEqual(vm.rest?.setID, second.id)
        XCTAssertFalse(vm.session.allLoggedSets.contains { $0.id == first.id })
        XCTAssertTrue(vm.session.allLoggedSets.contains { $0.id == second.id })
    }

    /// Progression is deliberately not rewound (#194's same judgement,
    /// applied here per the issue): a batch delete that clears every set
    /// still leaves the session itself resumable, just with nothing logged.
    func test_reconcile_survivesABatchDeleteThatClearsEveryLoggedSet() throws {
        let (vm, store) = try makeReconcilableViewModel()
        vm.logSet()
        let logged = try XCTUnwrap(vm.recentlyLoggedSet)

        _ = try store.deleteSets(ids: [logged.id])
        vm.reconcilePersistedSetsAfterHistoryEdit()

        XCTAssertNil(vm.recentlyLoggedSet)
        XCTAssertNil(vm.rest)
        XCTAssertTrue(vm.session.allLoggedSets.isEmpty)
        XCTAssertNil(vm.failure)
    }
}

private extension Exercise {
    /// Fixture convenience: renaming without re-declaring every parameter.
    func renamed(_ name: String) -> Exercise {
        var copy = self
        copy.name = name
        return copy
    }
}

// MARK: - What this file deliberately does not test (#181)
//
// `advance()`, `goBack()` and `select(exerciseID:)` — the exact three methods
// behind #169 and #172 — are the methods this issue's own description names
// as the motivating example, and they are NOT covered here. Each one calls
// `saveDraft()` (a real `store.saveWorkoutDraft` write) and `publishActivity()`
// (a real `ActivityKit` call via `SessionActivityController`), which is
// precisely the "touches TrainingStore, GymSettings.shared or ActivityKit"
// boundary the issue says needs more than a test target. A test that called
// them here would still not have caught #169 or #172: both bugs were about
// state that goes stale across a *lifetime* longer than one view-model
// instance behaving correctly in isolation — the fix (`didChangeCurrentExercise`
// as the one funnel every navigation method routes through) is now
// structurally load-bearing, and the risk this suite can't reach is someone
// adding a fourth navigation path that calls `session.select` directly and
// skips that funnel. Nothing short of a code-review convention or a lint rule
// closes that gap; it is not a gap a hosted XCTest can close either, since it
// is about a call site that doesn't exist yet.
//
// `logSet`, `logWarmup`, `skipRest`, `undoRecentlyLoggedSet` and
// `correctSet` are excluded for the same reason: every one of them commits
// through `store` and several also touch `RestNotification` or
// `publishActivity()`. They are real coverage gaps, but closing them means
// either refactoring the persistence and notification calls out of
// `SessionViewModel` (explicitly out of scope for this PR — see the issue)
// or accepting a slower, store-backed integration test, which is a different
// suite than the one this issue asked for.
//
// The one narrowing to that: #206's "Warmup ramp leads the exercise" section
// above *does* call `logSet` and `logWarmup` directly, for the same reason
// `reconcilePersistedSetsAfterHistoryEdit`'s tests already call `logSet()` as
// setup (see below) — `TrainingStore.inMemory()` makes the write safe in this
// host, and nothing under test there is `store`, `RestNotification`, or
// `ActivityKit` itself; it's `pendingLoad`, `pendingReps`, and
// `session.current?.loggedSets`, i.e. exactly the view-model state this suite
// already exists to check. What's still left to a UI or integration test:
// that tapping the real `Log Set` control invokes `logSet()` at all, that a
// rung logged this way actually reaches disk and survives a relaunch, and
// that the rest timer / Live Activity behave correctly around a warmup
// (already excluded above, unchanged by #206).
//
// `startRest()`, added for #173, lands in the same excluded set for the same
// reason: it calls `beginRest`, which touches `RestNotification` (a real
// `UNUserNotificationCenter` round trip) and `publishActivity()` (a real
// `ActivityKit` call) exactly like `commit` does. What's genuinely new and
// testable about #173 — that a rest not anchored to a set behaves like any
// other rest, and that `RestTimer.setID` can be `nil` instead of a fabricated
// `UUID()` — is covered at the `WeightTrainingCore` level in
// `RestTimerTests`, which is where that logic actually lives. Only the wiring
// (does tapping the button call `startRest`, does `startRest` reach for
// `Exercise.restTarget`) is left to the simulator, same as `logSet` above.
//
// `swapCandidates` and `searchResults` are pure given `allExercises`, but
// `allExercises` is a private property only populated by
// `loadSuggestionContext()`, which reads through `store.exercises()`. Testing
// them meaningfully would mean seeding the in-memory store first, which is
// the same store-dependency trade-off as above.
//
// `reconcilePersistedSetsAfterHistoryEdit` (#199) is the one deliberate
// exception to all of the above, in both directions. As the method under
// test, it's safe here for reasons `logSet`/`skipRest` aren't: it never
// writes through `store` (`resumeSession` only reads), `RestNotification.
// cancel()` is a synchronous fire-and-forget with no authorization
// dependency, and `SessionActivityController.start()`/`currentState()` both
// short-circuit on `ActivityAuthorizationInfo().areActivitiesEnabled`, which
// is false in this test host. As setup, its tests call the real `logSet()`
// (excluded above as a subject in its own right) rather than hand-assembling
// a `SetRecord` and `RestTimer` — the resulting `recentlyLoggedSet` and
// `rest` are exactly what History's edit needs to be reconciled against, and
// a hand-built stand-in could quietly drift from what `commit()` actually
// produces. `logSet()`'s own background `Task` for the rest-complete alert
// is fire-and-forget and asserted on nowhere here, so it never enters the
// test's timing.
