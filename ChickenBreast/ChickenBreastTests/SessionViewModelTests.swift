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
/// device to behave correctly. `TrainingStore.inMemory()` is used only because
/// `SessionViewModel.init` requires *a* store to exist — no test below calls a
/// method that reads or writes through it. Nothing here calls `logSet`,
/// `advance`, `goBack`, `select`, `skipRest`, `startRest` or anything else
/// that reaches `TrainingStore`, `GymSettings.shared` or `ActivityKit`; see
/// the bottom of this file for why those are explicitly left for a UI or
/// integration test instead, not silently skipped.
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

    private func sessionExercise(_ exercise: Exercise) -> SessionExercise {
        SessionExercise(
            exercise: exercise,
            prescription: Prescription(load: Load(135), reps: 5, rpe: .eight)
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
        let session = Session(kind: .push, exercises: roster.map(sessionExercise))
        return SessionViewModel(store: store, session: session, draftID: UUID())
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
