//
//  SessionIntents.swift
//  ChickenBreast
//

import ActivityKit
import AppIntents
import Foundation
import WeightTrainingCore
import WeightTrainingStore

/// Logging a set from the lock screen (#23).
///
/// `LiveActivityIntent` runs in the app's process without unlocking the phone
/// and without bringing the app forward, which is what makes the issue's
/// done-when reachable — a full exercise logged with the phone in a pocket.
///
/// Not voice. The issue imagines tapping the Dynamic Island and speaking, but
/// iOS refuses microphone access while the device is locked, so speech from
/// here cannot work at any level of effort. Buttons are the part that can.
///
/// The set to log arrives as parameters rather than being re-derived here, so
/// what gets logged is exactly what the screen was showing when it was tapped.
struct LogTargetSetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Log the target set"
    static var description = IntentDescription("Logs the set shown on the lock screen.")

    /// Runs in the app's process rather than opening the app.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Exercise") var exerciseID: String
    /// Titled by what it is rather than by its unit: the value is the stored
    /// canonical pounds, and a system-facing label saying "Pounds" would be a
    /// unit claim in front of a lifter whose gym is metric (#67).
    @Parameter(title: "Weight") var pounds: Double
    @Parameter(title: "Reps") var reps: Int
    @Parameter(title: "RPE") var rpe: Double?
    @Parameter(title: "Workout") var workoutID: String
    @Parameter(title: "Action") var actionID: String

    init() {}

    init(
        exerciseID: UUID,
        pounds: Double,
        reps: Int,
        rpe: Double?,
        workoutID: String,
        actionID: UUID
    ) {
        self.exerciseID = exerciseID.uuidString
        self.pounds = pounds
        self.reps = reps
        self.rpe = rpe
        self.workoutID = workoutID
        self.actionID = actionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: exerciseID),
              let setID = UUID(uuidString: actionID),
              let workoutUUID = UUID(uuidString: workoutID),
              let activity = SessionActivityRefresh.current(workoutID: workoutID),
              activity.content.state.logActionID == setID,
              activity.content.state.restEndsAt.map({ $0 <= Date() }) ?? true else {
            return .result()
        }

        let store = try AppStore.shared.store()
        let record = SetRecord(
            id: setID,
            exerciseID: id,
            load: Load(pounds),
            reps: reps,
            // The Live Activity displays the target RPE, but tapping Log does
            // not report that the set actually felt that way.
            rpe: nil,
            isWarmup: false,
            performedAt: Date()
        )
        guard let draft = try store.workoutDraft(), draft.id == workoutUUID else { return .result() }
        if let exercise = try store.exercise(id: id) {
            let refreshed = try store.sessionExercise(
                for: exercise,
                slot: nil,
                startedAt: draft.startedAt,
                workoutID: workoutUUID
            )
            // Recovery targets are proposals until the lifter chooses Use,
            // Adjust, or Dismiss in the workout. A stale Live Activity from a
            // prior process must not log one without an active prescription.
            if refreshed.acceptedPlan == nil,
               refreshed.recommendation?.action == .deload {
                return .result()
            }
        }
        let saved = try store.logWorkoutSet(
            record, workoutID: workoutUUID, startedAt: draft.startedAt, effortReported: false
        )
        guard saved.inserted else { return .result() }

        let nextTarget = try? SessionActivityRefresh.nextPlannedTarget(
            store: store,
            workoutID: workoutUUID,
            exerciseID: id,
            startedAt: draft.startedAt
        )

        // The lock screen has to reflect the tap immediately: rest restarts and
        // the set count and per-set target move. Nothing else is watching — the
        // session screen isn't on screen, or the phone wouldn't be locked.
        await SessionActivityRefresh.afterLoggedSet(
            workoutID: workoutID,
            setID: setID,
            nextTarget: nextTarget,
            restStartedAt: saved.record.performedAt,
            restEndsAt: saved.record.performedAt.addingTimeInterval(
                (try? store.exercise(id: id))?.restTarget ?? 180
            )
        )
        return .result()
    }
}

/// Ends the current rest early from the lock screen.
struct SkipRestIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Skip rest"
    static var description = IntentDescription("Ends the current rest.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Workout") var workoutID: String

    init() {}

    init(workoutID: String) {
        self.workoutID = workoutID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await SessionActivityRefresh.clearRest(workoutID: workoutID)
        return .result()
    }
}

/// Takes back only the set most recently logged from this Live Activity.
struct UndoLiveSetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Undo the last set"
    static var description = IntentDescription("Removes the set just logged from the lock screen.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Workout") var workoutID: String
    @Parameter(title: "Set") var setID: String

    init() {}

    init(workoutID: String, setID: UUID) {
        self.workoutID = workoutID
        self.setID = setID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: setID),
              let activity = SessionActivityRefresh.current(workoutID: workoutID),
              activity.content.state.lastLoggedSetID == id else { return .result() }
        let store = try AppStore.shared.store()
        _ = try store.deleteSet(id: id)
        let nextTarget: SessionActivityRefresh.PlannedTarget?
        if let workoutUUID = UUID(uuidString: workoutID),
           let draft = try store.workoutDraft(), draft.id == workoutUUID {
            nextTarget = try? SessionActivityRefresh.nextPlannedTarget(
                store: store,
                workoutID: workoutUUID,
                exerciseID: activity.content.state.exerciseID,
                startedAt: draft.startedAt
            )
        } else {
            nextTarget = nil
        }
        await SessionActivityRefresh.afterUndo(
            workoutID: workoutID,
            setID: id,
            nextTarget: nextTarget
        )
        return .result()
    }
}

/// Updates whichever session activity is running.
///
/// The intent can't reach the session view model — the view isn't on screen, and
/// may never have been in this process' lifetime — so it edits the running
/// activity's content directly. The session screen rebuilds from the store when
/// it next appears, which is what keeps the two from disagreeing.
@MainActor
enum SessionActivityRefresh {

    struct PlannedTarget {
        let line: String
        let set: PlannedWorkingSet
    }

    static func current(workoutID: String) -> Activity<SessionActivityAttributes>? {
        Activity<SessionActivityAttributes>.activities.first {
            $0.attributes.workoutID == workoutID
        }
    }

    // Each of the three below edits the activity and then makes the rest
    // alerts match the rest it now shows (#261). The intent runs in the app's
    // process but not through `SessionViewModel` — the session screen may
    // never have been built — so this is the lock screen's copy of
    // `SessionViewModel.syncRestAlerts()`. Each returns early, touching
    // neither the activity nor the alerts, when there's no activity to act
    // on, so a stale or duplicate delivery leaves the alerts as they were.

    static func afterLoggedSet(
        workoutID: String,
        setID: UUID,
        nextTarget: PlannedTarget?,
        restStartedAt: Date,
        restEndsAt: Date,
        alerts: RestAlertScheduling = SystemRestAlerts()
    ) async {
        guard let activity = current(workoutID: workoutID) else { return }
        var state = loggingSet(
            setID,
            restStartedAt: restStartedAt,
            restEndsAt: restEndsAt,
            in: activity.content.state
        )
        apply(nextTarget, to: &state)
        syncRestAlerts(to: state, using: alerts)
        await activity.update(ActivityContent(state: state, staleDate: restEndsAt))
    }

    static func clearRest(
        workoutID: String,
        alerts: RestAlertScheduling = SystemRestAlerts()
    ) async {
        guard let activity = current(workoutID: workoutID) else { return }
        let state = clearingRest(in: activity.content.state)
        syncRestAlerts(to: state, using: alerts)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    static func afterUndo(
        workoutID: String,
        setID: UUID,
        nextTarget: PlannedTarget?,
        alerts: RestAlertScheduling = SystemRestAlerts()
    ) async {
        guard let activity = current(workoutID: workoutID),
              activity.content.state.lastLoggedSetID == setID else { return }
        let before = activity.content.state
        var state = undoing(setID, in: before)
        apply(nextTarget, to: &state)
        // Only when the rest actually went: a hand-started rest outlives the
        // undo, and its alerts with it.
        if state.restEndsAt != before.restEndsAt {
            syncRestAlerts(to: state, using: alerts)
        }
        await activity.update(ActivityContent(state: state, staleDate: state.restEndsAt))
    }

    // MARK: Pure state changes, so the decisions can be unit-tested

    typealias State = SessionActivityAttributes.ContentState

    static func loggingSet(
        _ setID: UUID,
        restStartedAt: Date,
        restEndsAt: Date,
        in state: State
    ) -> State {
        var state = state
        state.setsLogged += 1
        state.restStartedAt = restStartedAt
        state.restEndsAt = restEndsAt
        // Every rest this intent can start is anchored to the set just
        // logged — there's no lock-screen control for a hand-started one
        // (#200) — so `restSetID` and `lastLoggedSetID` are the same value
        // here, same as `SessionViewModel.beginRest` publishing both from
        // one `commit`.
        state.restSetID = setID
        state.lastLoggedSetID = setID
        state.logActionID = UUID()
        return state
    }

    static func clearingRest(in state: State) -> State {
        var state = state
        state.restStartedAt = nil
        state.restEndsAt = nil
        state.restSetID = nil
        return state
    }

    /// Takes the set back, and the rest only if that set started it — the
    /// same rule as `SessionViewModel.undoRecentlyLoggedSet` (#8). An
    /// activity from before #200 carries neither `restStartedAt` nor
    /// `restSetID`, and every rest it could show was the logged set's, which
    /// is how `RestTimer.reconciled` reads it too.
    static func undoing(_ setID: UUID, in state: State) -> State {
        var state = state
        let restBelongsToSet = state.restSetID == setID
            || (state.restSetID == nil && state.restStartedAt == nil)
        state.setsLogged = max(0, state.setsLogged - 1)
        if restBelongsToSet {
            state = clearingRest(in: state)
        }
        state.lastLoggedSetID = nil
        state.logActionID = UUID()
        return state
    }

    /// The pending alerts for whatever rest `state` shows: the pair for it,
    /// named by the lift and target on the lock screen, or none. Settings'
    /// toggle is honoured inside `RestNotification.schedule`.
    static func syncRestAlerts(to state: State, using alerts: RestAlertScheduling) {
        guard let endsAt = state.restEndsAt else {
            alerts.cancel()
            return
        }
        // Only the end and the check-in matter to the alerts, and both hang
        // off `endsAt`; an activity without a start time still gets them.
        let startedAt = state.restStartedAt ?? endsAt
        alerts.schedule(
            for: RestTimer(
                startedAt: startedAt,
                duration: max(0, endsAt.timeIntervalSince(startedAt)),
                setID: state.restSetID
            ),
            exercise: state.exerciseName,
            next: state.targetLine
        )
    }

    /// Reads the accepted plan after a lock-screen write and returns the exact
    /// next set. This is the same persisted boundary the foreground session
    /// resumes from; deriving from the old activity state would repeat set one
    /// for plans such as 10/10/9.
    static func nextPlannedTarget(
        store: TrainingStore,
        workoutID: UUID,
        exerciseID: UUID,
        startedAt: Date
    ) throws -> PlannedTarget? {
        guard let exercise = try store.exercise(id: exerciseID) else { return nil }
        let refreshed = try store.sessionExercise(
            for: exercise,
            slot: nil,
            startedAt: startedAt,
            workoutID: workoutID
        )
        guard let plan = refreshed.acceptedPlan,
              let target = SessionActivitySelection.nextPlannedSet(
                  in: plan, completedWorkingSets: refreshed.workingSets.count
              ) else { return nil }
        let index = refreshed.workingSets.count
        let unit = try store.gymConfig().unit
        return PlannedTarget(
            line: "Set \(index + 1) of \(plan.sets.count) · "
                + "\(target.load.formatted(in: unit)) × \(target.reps) @ \(target.rpe)",
            set: target
        )
    }

    private static func apply(
        _ target: PlannedTarget?,
        to state: inout SessionActivityAttributes.ContentState
    ) {
        guard let target else { return }
        state.targetLine = target.line
        state.targetPounds = target.set.load.pounds
        state.targetReps = target.set.reps
        state.targetRPE = target.set.rpe.value
    }
}
