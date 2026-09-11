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
            rpe: rpe.flatMap { RPE($0) ?? RPE(snapping: $0) },
            isWarmup: false,
            performedAt: Date()
        )
        let inserted = try store.logIfAbsent(record)
        guard inserted else { return .result() }

        // The lock screen has to reflect the tap immediately: rest restarts and
        // the set count moves. Nothing else is watching — the session screen
        // isn't on screen, or the phone wouldn't be locked.
        await SessionActivityRefresh.afterLoggedSet(
            workoutID: workoutID,
            setID: setID,
            restEndsAt: record.performedAt.addingTimeInterval(
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
        await SessionActivityRefresh.afterUndo(workoutID: workoutID, setID: id)
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

    static func current(workoutID: String) -> Activity<SessionActivityAttributes>? {
        Activity<SessionActivityAttributes>.activities.first {
            $0.attributes.workoutID == workoutID
        }
    }

    static func afterLoggedSet(
        workoutID: String,
        setID: UUID,
        restEndsAt: Date
    ) async {
        guard let activity = current(workoutID: workoutID) else { return }
        var state = activity.content.state
        state.setsLogged += 1
        state.restEndsAt = restEndsAt
        state.lastLoggedSetID = setID
        state.logActionID = UUID()
        await activity.update(ActivityContent(state: state, staleDate: restEndsAt))
    }

    static func clearRest(workoutID: String) async {
        guard let activity = current(workoutID: workoutID) else { return }
        var state = activity.content.state
        state.restEndsAt = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    static func afterUndo(workoutID: String, setID: UUID) async {
        guard let activity = current(workoutID: workoutID),
              activity.content.state.lastLoggedSetID == setID else { return }
        var state = activity.content.state
        state.setsLogged = max(0, state.setsLogged - 1)
        state.restEndsAt = nil
        state.lastLoggedSetID = nil
        state.logActionID = UUID()
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
