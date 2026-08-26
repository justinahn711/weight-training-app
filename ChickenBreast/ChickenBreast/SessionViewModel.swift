//
//  SessionViewModel.swift
//  ChickenBreast
//

import Foundation
import Observation
import WeightTrainingCore
import WeightTrainingStore

/// Drives the session screen: owns the in-flight `Session` and mirrors every
/// change onto disk.
///
/// Sets are written the instant they're logged rather than batched at the end
/// of the day. A lifting app gets backgrounded constantly — by a phone call, by
/// the screen locking, by another app — and an unsaved set is a lost set.
@MainActor
@Observable
final class SessionViewModel {
    private let store: TrainingStore
    private let liveActivity = SessionActivityController()

    private(set) var session: Session
    private(set) var failure: String?

    /// The weight for the next set, seeded from the target and adjusted with
    /// the stepper. Held here rather than in the view so it survives the view
    /// being rebuilt as the day advances.
    var pendingLoad: Load
    var pendingReps: Int

    /// Pre-selected on the target so the common case — hit the target, log it —
    /// stays a single tap on the done button (#5).
    var pendingRPE: RPE

    /// The rest currently running, or nil between exercises. Wall-clock based,
    /// so it needs nothing running to stay correct across a backgrounding (#6).
    private(set) var rest: RestTimer?

    init(store: TrainingStore, session: Session) {
        self.store = store
        self.session = session
        let prescription = session.current?.prescription
        self.pendingLoad = prescription?.load ?? Load.zero
        self.pendingReps = prescription?.reps ?? 8
        self.pendingRPE = prescription?.rpe ?? .eight
        // Resuming a session that already has sets on it should pick up where
        // it left off, exactly as navigating back to a lift does.
        seedPendingFromCurrent()
    }

    var current: SessionExercise? { session.current }

    /// Position in the day, e.g. "3 of 7".
    var progressLabel: String {
        "\(session.currentIndex + 1) of \(session.exercises.count)"
    }

    // MARK: - Logging

    func logSet(isWarmup: Bool = false) {
        guard let current else { return }
        let record = SetRecord(
            exerciseID: current.exercise.id,
            load: pendingLoad,
            reps: pendingReps,
            // Warmups are never scored.
            rpe: isWarmup ? nil : pendingRPE,
            isWarmup: isWarmup,
            performedAt: Date()
        )

        commit(record, startsRest: !isWarmup)
    }

    /// Logs one rung of the warmup ramp exactly as shown, without disturbing
    /// the working weight already dialled in below.
    func logWarmup(_ rung: WarmupSet) {
        guard let current else { return }
        commit(
            SetRecord(
                exerciseID: current.exercise.id,
                load: rung.load,
                reps: rung.reps,
                isWarmup: true,
                performedAt: Date()
            ),
            startsRest: false
        )
    }

    private func commit(_ record: SetRecord, startsRest: Bool) {
        guard let current else { return }
        do {
            try store.log(record)
            session.log(record)
            // Log, start resting, and be ready for the next set — one tap does
            // all three (#6). Warmups don't start a rest; ramping is continuous
            // and a countdown there is just noise.
            if startsRest {
                let timer = RestTimer(
                    startedAt: record.performedAt,
                    duration: current.exercise.restTarget,
                    setID: record.id
                )
                rest = timer
                // The alert is what makes resting with the phone away possible
                // (#69); the Live Activity only helps if you're looking.
                let name = current.exercise.name
                let next = current.prescription.isColdStart
                    ? nil
                    : current.prescription.displayLine(in: GymSettings.shared.unit)
                Task { await RestNotification.schedule(for: timer, exercise: name, next: next) }
            }
            publishActivity()
        } catch {
            failure = "Couldn't save that set: \(error.localizedDescription)"
        }
    }

    /// Dismisses the rest clock without touching the logged set.
    func skipRest() {
        rest = nil
        RestNotification.cancel()
        publishActivity()
    }

    /// Removes the most recent set from both the session and disk. Backs #8.
    func undoLastSet() {
        guard let record = session.undoLastSet() else { return }
        do {
            try store.deleteSet(id: record.id)
            // A set that never happened can't be resting from. Only the rest
            // that *this* set started is cleared, so undoing an older mistake
            // mid-rest doesn't cancel the rest you're actually taking (#8).
            if rest?.setID == record.id {
                rest = nil
                // A buzz for a set you took back is worse than no buzz at all.
                RestNotification.cancel()
            }
        } catch {
            // Put it back rather than leaving screen and disk disagreeing.
            session.log(record)
            failure = "Couldn't undo that set: \(error.localizedDescription)"
        }
    }

    var canUndo: Bool { !session.allLoggedSets.isEmpty }

    // MARK: - Weight and reps

    /// What the lifter weighed most recently, for seeding a bodyweight lift.
    ///
    /// Read once when the session opens rather than per set: it can't change
    /// mid-session, and a store round trip between sets is a round trip nobody
    /// asked for.
    private(set) var latestBodyweight: Double?

    /// Seeds a bodyweight lift with the lifter's own weight (#71).
    ///
    /// Only when there's no target yet — a lift with history already knows what
    /// it proposed last time, and that number already included bodyweight.
    /// Without this, a first set of pull-ups starts at zero and logs as a set
    /// that moved nothing.
    func seedBodyweightIfNeeded() {
        guard let current, current.exercise.isBodyweight,
              current.prescription.load == nil,
              pendingLoad == .zero,
              let weight = latestBodyweight else { return }
        pendingLoad = Load(weight)
    }

    /// Steps the weight by the exercise's real increment — the next dumbbell
    /// up, 5 lb on a barbell — so the stepper can only produce loads the
    /// equipment can actually make.
    func adjustLoad(by steps: Int) {
        guard let exercise = current?.exercise else { return }
        let next = pendingLoad.pounds + Double(steps) * exercise.increment.pounds
        // Floored at what the equipment can present, not at zero. Stepping down
        // to 15 lb on a 45 lb bar is not a light set, it's an impossible one —
        // and the engine already refuses to propose such loads, so the one
        // place a human dials a weight has to refuse them too.
        pendingLoad = max(exercise.minimumLoad, Load(next))
    }

    /// Adds one plate per sleeve, the way it goes on the bar (#77).
    ///
    /// A 45 on a two-sleeve barbell is 90 lb, not 45. Stepping there by the
    /// increment takes twenty-eight taps to reach a working weight; this takes
    /// the number of plates you'd actually pick up.
    func addPlate(_ pounds: Double) {
        guard let exercise = current?.exercise, let loading = exercise.loading else { return }
        pendingLoad = Load(pendingLoad.pounds + pounds * Double(loading.sleeves))
    }

    /// Back to the empty apparatus, to build a weight up from scratch.
    ///
    /// The other half of plate entry: adding is fast only if starting over is
    /// too, otherwise a mistake means stepping all the way back down.
    func clearToBar() {
        guard let exercise = current?.exercise, let loading = exercise.loading,
              loading.isMeasured else { return }
        pendingLoad = loading.minimumLoad
    }

    /// The plates worth offering for this lift, heaviest first.
    ///
    /// Empty unless the apparatus has been measured (#39) — without a base
    /// weight the app doesn't know what the plates are being added to, and a
    /// running total built on an unknown bar would be a guess presented as a
    /// number.
    var plateOptions: [Double] {
        guard let loading = current?.exercise.loading, loading.isMeasured else { return [] }
        return loading.availablePlates.sorted(by: >)
    }

    func adjustReps(by delta: Int) {
        pendingReps = max(1, pendingReps + delta)
    }

    // MARK: - Navigation

    func advance() {
        session.advance()
        seedPendingFromCurrent()
    }

    func goBack() {
        session.goBack()
        seedPendingFromCurrent()
    }

    func select(exerciseID: UUID) {
        session.select(exerciseID: exerciseID)
        seedPendingFromCurrent()
    }

    /// Re-centres the input on the new exercise's target, using the last set
    /// already logged today if there is one — coming back to a lift mid-session
    /// should pick up where it left off, not reset to the target.
    private func seedPendingFromCurrent() {
        guard let current else { return }
        if let lastToday = current.loggedSets.last(where: { !$0.isWarmup }) {
            pendingLoad = lastToday.load
            pendingReps = lastToday.reps
        } else {
            // On a cold start there's no target, so the stepper opens at the
            // lightest thing the equipment can actually be set to — an empty
            // bar, not zero.
            pendingLoad = current.prescription.load ?? current.exercise.minimumLoad
            pendingReps = current.prescription.reps
        }
        // RPE always resets to the target rather than carrying the last set's
        // value forward. Effort is the one field that genuinely differs set to
        // set, and inheriting a 9.5 from the previous set would quietly log
        // fatigue that hasn't happened yet.
        pendingRPE = current.prescription.rpe
    }

    // MARK: - Voice

    /// What was heard, snapped and waiting. Nil when nothing is pending.
    private(set) var heard: SnappedInput?

    /// When the pending input will commit itself, or nil when it never will.
    private(set) var autoCommitAt: Date?

    /// How long a confident parse sits on screen before committing.
    ///
    /// Long enough to read and cancel, short enough that waiting isn't worse
    /// than tapping. Anything uncertain never starts the clock at all.
    static let autoCommitDelay: TimeInterval = 3

    /// Applies a heard command.
    ///
    /// Set-shaped commands fill the form and wait. Everything else — next,
    /// timers, adjustments — acts immediately, because none of them writes a
    /// set and all of them are trivially undone.
    func handle(_ parse: VoiceParse, now: Date = Date()) {
        guard let current else { return }

        switch parse.command {
        case .nextExercise:
            advance()
        case .startTimer(let seconds):
            rest = RestTimer(startedAt: now, duration: seconds, setID: UUID())
        case .adjustLoad(let delta):
            pendingLoad = max(current.exercise.minimumLoad,
                              Load(pendingLoad.pounds + delta.pounds))
        case .repeatLast:
            if let last = current.loggedSets.last(where: { !$0.isWarmup }) {
                pendingLoad = last.load
                pendingReps = last.reps
                pendingRPE = last.rpe ?? current.prescription.rpe
            }
        case .note:
            // Notes have nowhere to live yet; dropped rather than pretended at.
            break
        case .logSet:
            guard let snapped = VoiceSnapper.snap(parse, for: current.exercise,
                                                  reference: pendingLoad) else { return }
            heard = snapped
            autoCommitAt = snapped.canAutoCommit
                ? now.addingTimeInterval(Self.autoCommitDelay)
                : nil
        }
    }

    /// Writes the pending values into the form and logs the set.
    func commitHeard() {
        guard let snapped = heard else { return }
        if let load = snapped.load { pendingLoad = load }
        if let reps = snapped.reps { pendingReps = reps }
        if let rpe = snapped.rpe { pendingRPE = rpe }
        clearHeard()
        logSet()
    }

    /// Any tap cancels — the form keeps whatever it had.
    func clearHeard() {
        heard = nil
        autoCommitAt = nil
    }

    // MARK: - Finishing

    /// Turns what was performed into next session's targets.
    ///
    /// Leaving the session is what finishes it — there is no "done" button to
    /// forget to press, and a session abandoned halfway still produced real
    /// work that should count. The store owns the rule, including the
    /// once-per-day guard that keeps walking out and back in from being worth
    /// a load jump.
    func applyProgression() {
        do {
            let applied = try store.applyProgression(for: session)
            for entry in applied {
                loadedStates[entry.exercise.id] = entry.result.state
            }
        } catch {
            failure = "Couldn't save your progress: \(error.localizedDescription)"
        }
    }

    // MARK: - Swapping

    /// Every exercise on disk, for the swap sheet's search.
    private var allExercises: [Exercise] = []
    private var lastPerformed: [UUID: Date] = [:]

    /// The current slot's own candidates, stalest first — the one-tap path.
    ///
    /// Excludes what's already on screen: offering to swap a lift for itself is
    /// a row that can only waste a tap.
    var swapCandidates: [Exercise] {
        guard let current else { return [] }
        let ids = current.slot?.candidateExerciseIDs ?? []
        let candidates = ids.compactMap { id in allExercises.first { $0.id == id } }
            .filter { $0.id != current.exercise.id }
        return ExerciseSearch.rankedByStaleness(candidates, lastPerformed: lastPerformed)
    }

    /// Fuzzy search across the whole library, for everything else.
    func searchResults(_ query: String) -> [Exercise] {
        guard let current else { return [] }
        return ExerciseSearch.search(query, in: allExercises)
            .filter { $0.id != current.exercise.id }
    }

    // MARK: - Live Activity (#23)

    /// Pushes the current lift, target and rest to the lock screen.
    ///
    /// Called after anything that changes what someone glancing at their phone
    /// would need to know, rather than on a timer: the countdown itself ticks
    /// on the widget's side from `restEndsAt`, so updates are only needed when
    /// the *facts* change, not when the clock does.
    func publishActivity() {
        guard let current else {
            liveActivity.end()
            return
        }
        let state = SessionActivityAttributes.ContentState(
            exerciseName: current.exercise.name,
            targetLine: current.prescription.displayLine(in: GymSettings.shared.unit),
            setsLogged: current.workingSets.count,
            exerciseID: current.exercise.id,
            targetPounds: current.prescription.load?.pounds,
            targetReps: current.prescription.reps,
            targetRPE: current.prescription.rpe.value,
            restEndsAt: rest?.endsAt
        )
        liveActivity.start(dayKind: session.kind.rawValue.capitalized, state: state)
    }

    /// Takes the lock screen down when the session ends.
    func endActivity() {
        liveActivity.end()
        // Rest belongs to a session in progress. Leaving ends the session
        // (SessionView.onDisappear), so a pending alert would arrive for
        // training that's already finished.
        RestNotification.cancel()
    }

    /// Corrects what the app assumes about this machine (#20, #39).
    ///
    /// Rebuilt through the store rather than patched in place, for the same
    /// reason a swap is: the prescription, the plate line and the suggestions
    /// are all derived from the exercise, so they have to be recomputed from
    /// the corrected one. #20's done-when is that a changed increment reflows
    /// the lift's suggestions immediately, and rebuilding is what makes that
    /// true without a relaunch.
    ///
    /// The edit persists, so it survives the session and syncs to your other
    /// devices — a stack measured once should stay measured.
    func updateConfiguration(increment: LoadIncrement, loading: LoadingStyle?) {
        guard let current else { return }
        do {
            var corrected = current.exercise
            corrected.increment = increment
            corrected.loading = loading
            try store.upsert(corrected)

            let rebuilt = try store.sessionExercise(
                for: corrected,
                slot: current.slot,
                startedAt: session.startedAt
            )
            session.replaceCurrent(with: rebuilt)
            seedPendingFromCurrent()
            loadSuggestionContext()
        } catch {
            failure = "Couldn't save that setting: \(error.localizedDescription)"
        }
    }

    /// Adds a lift that didn't exist, then swaps to it (#76).
    ///
    /// Created and used in one move, because the only reason to invent a lift
    /// mid-session is to do it now. It persists and syncs like any other, and
    /// counts towards volume from its first set — the muscle report reads what
    /// was trained, never what was planned.
    func createAndSwap(to exercise: Exercise) {
        do {
            try store.create(exercise)
            swap(to: exercise)
        } catch {
            failure = "Couldn't add that exercise: \(error.localizedDescription)"
        }
    }

    /// Swaps the lift filling the current slot.
    ///
    /// The replacement is rebuilt from disk so it arrives with its own target
    /// and its own history — a swap is not an inheritance.
    func swap(to exercise: Exercise) {
        guard let current else { return }
        do {
            let replacement = try store.sessionExercise(
                for: exercise,
                slot: current.slot,
                startedAt: session.startedAt
            )
            session.replaceCurrent(with: replacement)
            seedPendingFromCurrent()
            // The old lift's advice has nothing to say about this one.
            rest = nil
            isWarmupRampExpanded = false
        } catch {
            failure = "Couldn't swap that exercise: \(error.localizedDescription)"
        }
    }

    // MARK: - Suggestions

    /// Chips dismissed during this session.
    ///
    /// Session-scoped and never persisted: rule three is "dismissed once,
    /// silent for the rest of the session", not silent forever. Tomorrow's
    /// session gets to make its case again.
    private var dismissedSuggestions: Set<String> = []

    /// Cached history per exercise, so building chips after every logged set
    /// doesn't re-read the whole store each time.
    private var historyCache: [UUID: [SetRecord]] = [:]

    var suggestions: [Suggestion] {
        guard let current else { return [] }
        return SuggestionEngine.suggestions(
            exercise: current.exercise,
            prescription: current.prescription,
            loggedToday: current.loggedSets,
            state: state(for: current),
            history: historyCache[current.id] ?? current.loggedSets,
            pendingLoad: pendingLoad,
            pendingReps: pendingReps
        )
        .filter { !dismissedSuggestions.contains($0.id) }
    }

    /// Applies a chip to the pending values — and *only* to the pending values.
    ///
    /// Nothing is logged and no target is written. The chip moves the number
    /// the done button already commits, so accepting one is exactly equivalent
    /// to having dialled that number by hand.
    func accept(_ suggestion: Suggestion) {
        switch suggestion.kind {
        case .load(let load), .deload(let load):
            pendingLoad = load
        case .reps(let reps):
            pendingReps = reps
        case .swap:
            // Needs slot candidates from #16 and the swap UI in #18.
            break
        }
        dismissedSuggestions.insert(suggestion.id)
    }

    func dismiss(_ suggestion: Suggestion) {
        dismissedSuggestions.insert(suggestion.id)
    }

    /// Reconstructs the state the chips reason about.
    ///
    /// The prescription already carries the session's target; stall count comes
    /// from the state loaded with the session.
    private func state(for exercise: SessionExercise) -> ProgressState {
        var state = loadedStates[exercise.id] ?? ProgressState(exerciseID: exercise.id)
        state.targetLoad = exercise.prescription.load
        state.targetReps = exercise.prescription.reps
        state.targetRPE = exercise.prescription.rpe
        return state
    }

    /// Progress states as they were when the session opened.
    private var loadedStates: [UUID: ProgressState] = [:]

    /// Fills the caches the chips read from.
    func loadSuggestionContext() {
        latestBodyweight = try? store.bodyweight(on: Date())
        seedBodyweightIfNeeded()
        for exercise in session.exercises {
            historyCache[exercise.id] = (try? store.sets(forExercise: exercise.id)) ?? []
            if let state = try? store.progressState(forExercise: exercise.id) {
                loadedStates[exercise.id] = state
            }
        }
        allExercises = (try? store.exercises()) ?? []
        lastPerformed = (try? store.lastPerformedDates()) ?? [:]
    }

    // MARK: - Plates and warmups

    /// How to build the weight currently dialled in, for plate-built lifts.
    var plateBreakdown: PlateBreakdown? {
        current?.exercise.plateBreakdown(for: pendingLoad)
    }

    /// Exercises whose ramp has been dismissed. Kept per exercise and only for
    /// this session — clearing the block on bench says nothing about RDL later.
    private var clearedRamps: Set<UUID> = []

    /// Whether the ramp block is expanded. Collapsed by default (#15): on most
    /// days the ramp is glanced at, not read.
    var isWarmupRampExpanded = false

    /// The ramp for the current lift, or empty when one isn't wanted.
    ///
    /// Disappears once the first working set is logged — a ramp is a plan for
    /// getting to the first work set, and it's noise afterwards.
    var warmupRamp: [WarmupSet] {
        guard let current,
              !clearedRamps.contains(current.id),
              current.workingSets.isEmpty else { return [] }
        return WarmupRamp.generate(
            for: current.exercise,
            workingLoad: current.prescription.load ?? pendingLoad
        )
    }

    /// One tap to clear the block, per #15.
    func clearWarmupRamp() {
        guard let current else { return }
        clearedRamps.insert(current.id)
        isWarmupRampExpanded = false
    }

    /// The rep numbers offered on the row, centred on the target.
    ///
    /// The window is fixed to the target rather than following the selection,
    /// which would slide the row out from under a finger already reaching for
    /// it. It runs well past the top of the range so a genuinely good set never
    /// has to be rounded down to fit the UI.
    var repChoices: [Int] {
        guard let target = current?.prescription.reps else { return Array(1...20) }
        let lowest = max(1, target - 5)
        return Array(lowest...(target + 8))
    }

    func dismissFailure() { failure = nil }
}
