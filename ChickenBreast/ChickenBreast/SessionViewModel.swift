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
    private let liveActivity: SessionActivityController
    private let draftID: UUID
    /// Finish can be tapped twice while navigation animates. Persistent
    /// progression and Live Activity teardown still belong to one explicit
    /// boundary, so repeated calls are harmless.
    @ObservationIgnored private var hasFinished = false
    @ObservationIgnored private var isActivityEnded = false
    /// Stable until its lock-screen action is consumed. Reusing this id as the
    /// set id makes duplicate App Intent delivery harmless.
    @ObservationIgnored private var liveLogActionID = UUID()
    @ObservationIgnored private var liveActivityExerciseID: UUID?

    private(set) var session: Session
    private(set) var failure: String?

    /// The weight for the next set, seeded from the target and adjusted with
    /// the stepper. Held here rather than in the view so it survives the view
    /// being rebuilt as the day advances.
    var pendingLoad: Load
    private(set) var pendingReps: Int

    /// An unlogged choice belongs to its exercise, not whichever lift happens
    /// to be visible now. This is what lets someone enter an unusual set, jump
    /// around occupied equipment, and return without the target silently
    /// replacing what they had already chosen (#131).
    private var pendingRepsByExercise: [UUID: Int] = [:]

    /// Pre-selected on the target so the common case — hit the target, log it —
    /// stays a single tap on the done button (#5).
    var pendingRPE: RPE

    /// The rest currently running, or nil between exercises. Wall-clock based,
    /// so it needs nothing running to stay correct across a backgrounding (#6).
    private(set) var rest: RestTimer?

    /// The one set the session UI may offer to undo. This is deliberately not
    /// derived from all history: old sets remain editable in Today, while Undo
    /// is a short-lived acknowledgement of the action that just happened.
    ///
    /// Moving to another exercise ends "just happened" even though nothing
    /// about the set itself changed, so leaving one is also cleared here —
    /// see `didChangeCurrentExercise()` (#169).
    private(set) var recentlyLoggedSet: SetRecord?

    init(store: TrainingStore, session: Session, draftID: UUID) {
        self.store = store
        self.session = session
        self.draftID = draftID
        self.liveActivity = SessionActivityController(workoutID: draftID)
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
            recentlyLoggedSet = record
            liveLogActionID = UUID()
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

    /// Removes the specifically named, just-logged set from session and disk.
    /// If a newer set has appeared, the stale offer disappears without
    /// touching history. Persistent corrections belong to the Today rows.
    func undoRecentlyLoggedSet(id: UUID) {
        guard recentlyLoggedSet?.id == id else { return }
        guard let record = session.undoLastSet(ifID: id) else {
            recentlyLoggedSet = nil
            return
        }
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
            recentlyLoggedSet = nil
            liveLogActionID = UUID()
            publishActivity()
        } catch {
            // Put it back rather than leaving screen and disk disagreeing.
            session.log(record)
            failure = "Couldn't undo that set: \(error.localizedDescription)"
        }
    }

    func dismissRecentSetUndo(id: UUID) {
        guard recentlyLoggedSet?.id == id else { return }
        recentlyLoggedSet = nil
    }

    /// Corrects an already logged row without disturbing the controls for the
    /// next set or the rest currently running (#130).
    ///
    /// A false result keeps the correction sheet and its entered values alive.
    @discardableResult
    func correctSet(_ record: SetRecord) -> Bool {
        do {
            guard try store.updateSet(record, in: &session) else {
                failure = "That set changed somewhere else. Your edits are still here; try again or cancel."
                return false
            }
            if recentlyLoggedSet?.id == record.id {
                recentlyLoggedSet = record
            }
            publishActivity()
            return true
        } catch {
            failure = "Couldn't save that correction: \(error.localizedDescription). Your edits are still here."
            return false
        }
    }

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

    /// Accepts only a value already resolved by the typed-entry sheet, and
    /// rechecks the current exercise in case its configuration changed while
    /// the sheet was open.
    @discardableResult
    func setTypedLoad(_ load: Load, for exerciseID: UUID) -> Bool {
        guard let current, current.id == exerciseID,
              current.exercise.canBuild(load) else { return false }
        pendingLoad = load
        return true
    }

    /// Adds one plate per sleeve, the way it goes on the bar (#77).
    ///
    /// A 45 on a two-sleeve barbell is 90 lb, not 45. Stepping there by the
    /// increment takes twenty-eight taps to reach a working weight; this takes
    /// the number of plates you'd actually pick up.
    /// `plate` is in the apparatus's own unit, the way `availablePlates` and
    /// the buttons express it — a 20 in a metric gym is 20 kg. Converting here
    /// rather than at the call site keeps the one place that turns a marked
    /// plate size into canonical pounds next to the arithmetic that uses it:
    /// this read them as pounds and put 38.1 kg on a bar the lifter had
    /// loaded to 60.
    func addPlate(_ plate: Double) {
        guard let exercise = current?.exercise, let loading = exercise.loading else { return }
        let perSleeve = loading.unit.pounds(from: plate)
        pendingLoad = Load(pendingLoad.pounds + perSleeve * Double(loading.sleeves))
    }

    /// Removes one plate shown in the current breakdown from every sleeve.
    ///
    /// This is deliberately tied to the visible breakdown rather than acting
    /// as another generic decrement: tapping a loaded 25 reverses adding that
    /// 25, while the ordinary stepper continues to mean one configured step.
    func removePlate(_ plate: Double) {
        guard let loading = current?.exercise.loading,
              let next = loading.removingPlate(plate, from: pendingLoad)
        else { return }
        pendingLoad = next
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
        setPendingReps(max(1, pendingReps + delta))
    }

    /// Selects an exact positive count for the visible exercise.
    func setPendingReps(_ reps: Int) {
        guard let exerciseID = current?.id, reps > 0 else { return }
        setPendingReps(reps, for: exerciseID)
    }

    /// Applies an exact count to the exercise whose entry UI was opened.
    ///
    /// Voice navigation can move the session while a sheet is presented. The
    /// exercise ID pins this write to its original subject, just like swap and
    /// configuration sheets do (#98, #120).
    func setPendingReps(_ reps: Int, for exerciseID: UUID) {
        guard reps > 0 else { return }
        pendingRepsByExercise[exerciseID] = reps
        if current?.id == exerciseID {
            pendingReps = reps
        }
    }

    // MARK: - Navigation

    func advance() {
        session.advance()
        didChangeCurrentExercise()
        saveDraft()
    }

    func goBack() {
        session.goBack()
        didChangeCurrentExercise()
        saveDraft()
    }

    func select(exerciseID: UUID) {
        session.select(exerciseID: exerciseID)
        didChangeCurrentExercise()
        saveDraft()
    }

    /// The one place every path that changes which exercise is on screen
    /// routes through, so the two things that must never survive that change
    /// can't be forgotten by whichever navigation method gets added next.
    ///
    /// `advance()`, `goBack()` and `select(exerciseID:)` used to each re-seed
    /// the pending values and stop there. `recentlyLoggedSet` stayed set to a
    /// set that belonged to the exercise just left, so its banner survived
    /// into the next exercise, and tapping it could delete a set from a lift
    /// already finished (#169). The same three methods also never told the
    /// lock screen anything had changed, so it kept showing the previous
    /// exercise, target and set count (#172) — the same missed spot with a
    /// different symptom. Routing both through the one call every navigation
    /// method already makes is what keeps a third one from reintroducing
    /// either bug.
    private func didChangeCurrentExercise() {
        recentlyLoggedSet = nil
        seedPendingFromCurrent()
        publishActivity()
    }

    /// Re-centres the input on the new exercise's target, using the last set
    /// already logged today if there is one — coming back to a lift mid-session
    /// should pick up where it left off, not reset to the target.
    private func seedPendingFromCurrent() {
        guard let current else { return }
        if let lastToday = current.loggedSets.last(where: { !$0.isWarmup }) {
            pendingLoad = lastToday.load
        } else {
            // On a cold start there's no target, so the stepper opens at the
            // lightest thing the equipment can actually be set to — an empty
            // bar, not zero.
            pendingLoad = current.prescription.load ?? current.exercise.minimumLoad
        }
        // A draft made after the last logged set wins. Without this ordering,
        // entering 25 after set one, checking another exercise, and returning
        // would replace 25 with set one's reps even though nothing was logged.
        pendingReps = pendingRepsByExercise[current.id]
            ?? current.loggedSets.last(where: { !$0.isWarmup })?.reps
            ?? current.prescription.reps
        pendingRepsByExercise[current.id] = pendingReps
        // RPE always resets to the target rather than carrying the last set's
        // value forward. Effort is the one field that genuinely differs set to
        // set, and inheriting a 9.5 from the previous set would quietly log
        // fatigue that hasn't happened yet.
        pendingRPE = current.prescription.rpe
        // Open only for the first exercise of the day (#157) — everywhere
        // else stays collapsed, per #15's original reasoning. Comparing
        // identity rather than `session.currentIndex == 0` survives a swap:
        // whichever lift is actually first in the lineup gets read, not
        // whichever one happened to be first when the day was planned. Safe
        // to recompute on every visit, including a return trip: once the
        // ramp for a lift disappears behind a logged working set, this value
        // has nothing left to show either way.
        isWarmupRampExpanded = current.id == session.exercises.first?.id
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
            // Started outside `commit`, so nothing else on this path tells the
            // lock screen the rest changed unless this does (#172).
            publishActivity()
        case .adjustLoad(let delta):
            pendingLoad = max(current.exercise.minimumLoad,
                              Load(pendingLoad.pounds + delta.pounds))
        case .repeatLast:
            if let last = current.loggedSets.last(where: { !$0.isWarmup }) {
                pendingLoad = last.load
                setPendingReps(last.reps)
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
        if let reps = snapped.reps { setPendingReps(reps) }
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

    /// Finishes this workout exactly once. Navigation and disappearance are
    /// deliberately not finishing signals; only the visible Finish action is.
    @discardableResult
    func finish() -> Bool {
        guard !hasFinished else { return true }
        do {
            // Pull in sets logged from the lock-screen intent while this view
            // was not active. Disk is authoritative for performed work.
            session = try store.resumeSession(
                WorkoutDraft(session: session, id: draftID)
            )
            let applied = try store.applyProgression(for: session, now: session.startedAt)
            for entry in applied {
                loadedStates[entry.exercise.id] = entry.result.state
            }
            // Clear after progression. If this save fails, retrying is safe:
            // progression is idempotent for the session day, while retaining
            // the draft keeps a failed Finish recoverable.
            try store.clearWorkoutDraft(id: draftID)
            hasFinished = true
            endActivity()
            return true
        } catch {
            failure = "Couldn't finish this workout: \(error.localizedDescription)"
            return false
        }
    }

    /// Keeps exercise order and position durable without storing a derived
    /// result. Failure is visible, because otherwise Back would promise a
    /// resume state the app had not actually saved.
    private func saveDraft() {
        do {
            try store.saveWorkoutDraft(WorkoutDraft(session: session, id: draftID))
        } catch {
            failure = "Couldn't save where you left off: \(error.localizedDescription)"
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
    /// Takes the lift being swapped rather than reading `current`.
    ///
    /// This is the *read* half of #120 and it was missed the first time. The
    /// sheet's content closure is re-evaluated when a voice-driven `advance()`
    /// lands, so a list built from `current` silently repainted to the new
    /// lift's alternatives — and whatever was picked from it went into the old
    /// lift's slot. It also filtered out the wrong exercise, so the lift being
    /// replaced appeared as a candidate for itself and picking it no-opped
    /// against the Core identity guard with nothing said.
    func swapCandidates(for replaced: SessionExercise) -> [Exercise] {
        let ids = replaced.slot?.candidateExerciseIDs ?? []
        let candidates = ids.compactMap { id in allExercises.first { $0.id == id } }
            .filter { $0.id != replaced.exercise.id }
        return ExerciseSearch.rankedByStaleness(candidates, lastPerformed: lastPerformed)
    }

    /// Fuzzy search across the whole library, for everything else.
    func searchResults(_ query: String, for replaced: SessionExercise) -> [Exercise] {
        ExerciseSearch.search(query, in: allExercises)
            .filter { $0.id != replaced.exercise.id }
    }

    // MARK: - Live Activity (#23)

    /// Pulls lock-screen actions into the same in-memory session before the app
    /// publishes another ActivityKit update. Without this foreground boundary,
    /// the stale view model overwrites the set count and starts a second rest
    /// timeline when the phone unlocks.
    func reconcileLiveActivityActions() {
        guard let activityState = liveActivity.currentState() else {
            publishActivity()
            return
        }
        do {
            session = try store.resumeSession(
                WorkoutDraft(session: session, id: draftID)
            )
            if let actionID = activityState.logActionID {
                liveLogActionID = actionID
            }

            let activitySet = activityState.lastLoggedSetID.flatMap { setID in
                session.allLoggedSets.first { $0.id == setID }
            }
            recentlyLoggedSet = activitySet

            if let record = activitySet, let endsAt = activityState.restEndsAt {
                rest = RestTimer(
                    startedAt: record.performedAt,
                    duration: max(0, endsAt.timeIntervalSince(record.performedAt)),
                    setID: record.id
                )
            } else {
                rest = nil
                RestNotification.cancel()
            }
            publishActivity()
        } catch {
            failure = "Couldn't refresh lock-screen changes: \(error.localizedDescription)"
        }
    }

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
        if liveActivityExerciseID != current.exercise.id {
            liveActivityExerciseID = current.exercise.id
            liveLogActionID = UUID()
        }
        let state = SessionActivityAttributes.ContentState(
            exerciseName: current.exercise.name,
            targetLine: current.prescription.displayLine(in: GymSettings.shared.unit),
            setsLogged: current.workingSets.count,
            exerciseID: current.exercise.id,
            targetPounds: current.prescription.load?.pounds,
            targetReps: current.prescription.reps,
            targetRPE: current.prescription.rpe.value,
            logActionID: liveLogActionID,
            lastLoggedSetID: recentlyLoggedSet?.id,
            restEndsAt: rest?.endsAt
        )
        isActivityEnded = false
        liveActivity.start(dayKind: session.kind.rawValue.capitalized, state: state)
    }

    /// Leaving the workout route pauses its glanceable surface without
    /// discarding the resumable draft. Returning to Resume publishes a fresh
    /// activity from the same session.
    func leaveSession() {
        endActivity()
    }

    /// Takes the lock screen down when the session ends.
    private func endActivity() {
        guard !isActivityEnded else { return }
        isActivityEnded = true
        liveActivity.end()
        // Rest belongs to a session in progress. Leaving ends the session
        // route, so a pending alert would arrive for training that's already
        // finished.
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
    /// Applies a correction to the lift the config sheet was opened for.
    ///
    /// Takes the exercise explicitly rather than reading `current`. The sheet
    /// pins its subject for the whole presentation (#98), but this wrote
    /// through `current` — and `current` can move while the sheet is open,
    /// because `SessionView` stays alive underneath it and the mic keeps
    /// listening: a spoken "next exercise" advances the session. Saving then
    /// wrote the increment and loading style you had just corrected for one
    /// lift onto whichever lift had become current, and left the one you
    /// edited untouched. Two lifts wrong from one correct action, silently.
    func updateConfiguration(
        of exercise: Exercise,
        increment: LoadIncrement,
        loading: LoadingStyle?
    ) {
        do {
            var corrected = exercise
            corrected.increment = increment
            corrected.loading = loading
            try store.upsert(corrected)

            // The session's copy only needs rebuilding if this is still the
            // lift on screen. If the day moved on while the sheet was open the
            // store now holds the correction and the next visit to that lift
            // reads it — there is nothing on screen to update.
            guard let current, current.exercise.id == corrected.id else { return }

            let rebuilt = try store.sessionExercise(
                for: corrected,
                slot: current.slot,
                startedAt: session.startedAt
            )
            // Not `replaceCurrent`: that is the swap path and no-ops when the
            // replacement is the same lift, which a reconfiguration always is.
            session.reconfigureCurrent(with: rebuilt)
            seedPendingFromCurrent()
            // Not a navigation change — this is still the exercise the banner
            // belongs to, so `recentlyLoggedSet` is left alone rather than
            // routed through `didChangeCurrentExercise()`. The lock screen is
            // still told, though: it's cheap, and it keeps every mutation of
            // what's on screen in the same habit rather than trusting each one
            // to remember on its own (#172).
            publishActivity()
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
    func createAndSwap(_ replaced: SessionExercise, to exercise: Exercise) {
        do {
            try store.create(exercise)
            swap(replaced, to: exercise)
        } catch {
            failure = "Couldn't add that exercise: \(error.localizedDescription)"
        }
    }

    /// Swaps the lift filling the current slot.
    ///
    /// The replacement is rebuilt from disk so it arrives with its own target
    /// and its own history — a swap is not an inheritance.
    /// Takes the lift being replaced rather than reading `current`.
    ///
    /// The swap sheet is decided over several seconds and the day can move
    /// underneath it — the mic keeps listening beneath the sheet, so "next
    /// exercise" advances the session mid-decision. Reading `current` at the
    /// end meant picking a replacement for Leg Press could replace Calf Raise
    /// and leave Leg Press alone (#120). Same shape as #98's config write.
    func swap(_ replaced: SessionExercise, to exercise: Exercise) {
        do {
            let replacement = try store.sessionExercise(
                for: exercise,
                slot: replaced.slot,
                startedAt: session.startedAt
            )
            // Asked before the write, and about the lift that was replaced.
            //
            // Checking `current?.id == replacement.id` afterwards asks whether
            // the visible lift happens to be the same *exercise* as the
            // replacement — `SessionExercise.id` is the exercise's id, not a
            // per-instance one. Swap Leg Press for Hack Squat while the day has
            // already advanced to Hack Squat and that reads true, so a lift
            // nobody touched had its pending load, rest timer and warmup ramp
            // reset mid-set. `updateConfiguration` already asks it this way.
            let wasVisible = current?.id == replaced.id
            session.replace(exerciseWithID: replaced.id, with: replacement)
            saveDraft()
            // Only the visible lift's pending state and advice are the screen's
            // to reset. Swapping one the day has already moved past changes the
            // day, not what is in front of you.
            guard wasVisible else { return }
            // Cleared before `didChangeCurrentExercise` publishes, not after:
            // the old lift's rest doesn't belong to the one replacing it, and
            // the lock screen should never show a countdown ticking against an
            // exercise that isn't running it anymore.
            rest = nil
            // A swap onto the visible slot is a different exercise arriving
            // where the old one was — the same shape as advancing to one, so
            // it gets the same treatment: the old lift's undo banner and
            // lock-screen state don't belong to the new lift either (#169,
            // #172). The ramp disclosure is not reset here (#157) —
            // `seedPendingFromCurrent`, called from `didChangeCurrentExercise`,
            // already recomputed it for whichever exercise now occupies this
            // slot, and overriding that unconditionally to collapsed would
            // undefault an expanded ramp every time the *first* slot's lift
            // was swapped.
            didChangeCurrentExercise()
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
            setPendingReps(reps)
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

    /// Whether the ramp block is expanded.
    ///
    /// Collapsed by default (#15): on most days the ramp is glanced at, not
    /// read. #157 is the report that "most days" was doing all the work in
    /// that sentence — collapsed *and* absent on 15 of 19 library lifts meant
    /// it was never seen once. `seedPendingFromCurrent` now opens this for the
    /// first exercise of the day specifically, where a ramp is the first thing
    /// on the screen worth reading rather than a footnote on the way to
    /// something already warmed up from the exercise before it.
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

    /// The rep numbers offered on the row: a fixed 1...20, the same for every
    /// exercise and every set.
    ///
    /// #171 is a deliberate reversal of the previous design, not a constant
    /// tweak. The row used to be a window centred on the target
    /// (`target-5...target+8`), and the reasoning for that was sound on its
    /// own: it kept the likely answer under the thumb and ran past the target
    /// so a good set was never rounded down. But the same window is what made
    /// it unreadable. A 13-rep target produced 8...21 — no 1, and a ceiling
    /// that corresponds to nothing a lifter would name — and a Row programmed
    /// `RepRange(8, 12)` showed a *lowest* chip of 6, which reads as "go
    /// lower," not as a neutral count. Widening the window doesn't fix this:
    /// the same number still moves between exercises, and the lowest chip
    /// still isn't 1 for most targets.
    ///
    /// A fixed row costs one thing: an exercise whose usual count sits above
    /// 20 (myo-reps, drop sets) never sees its number on the row. That case
    /// already had to reach for the #131 `Other` control before this change —
    /// it's the intended escape hatch, not a bug to route around — and it's a
    /// smaller cost than a strength lift missing 1, which is not an edge case
    /// but a top single or a failed set's rep count, and was reachable only
    /// through that same control before this fix.
    ///
    /// In exchange, the row is now genuinely fixed: the same numbers sit in
    /// the same places every set, so a thumb that's learned where "8" lives
    /// doesn't have to look, and nothing about the target or the current
    /// selection ever moves it — which was already the reason it was pinned
    /// to the target rather than the selection, just not carried far enough.
    var repChoices: [Int] { Array(1...20) }

    /// The fixed quick row has no selected chip when the actual count is an
    /// exception. The secondary control uses this to show that exact value.
    var usesOtherRepCount: Bool {
        !repChoices.contains(pendingReps)
    }

    func dismissFailure() { failure = nil }
}
