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
    @Parameter(title: "Pounds") var pounds: Double
    @Parameter(title: "Reps") var reps: Int
    @Parameter(title: "RPE") var rpe: Double?

    init() {}

    init(exerciseID: UUID, pounds: Double, reps: Int, rpe: Double?) {
        self.exerciseID = exerciseID.uuidString
        self.pounds = pounds
        self.reps = reps
        self.rpe = rpe
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: exerciseID) else { return .result() }

        let store = try AppStore.shared.store()
        let record = SetRecord(
            exerciseID: id,
            load: Load(pounds),
            reps: reps,
            rpe: rpe.flatMap { RPE($0) ?? RPE(snapping: $0) },
            isWarmup: false,
            performedAt: Date()
        )
        try store.log(record)

        // The lock screen has to reflect the tap immediately: rest restarts and
        // the set count moves. Nothing else is watching — the session screen
        // isn't on screen, or the phone wouldn't be locked.
        await SessionActivityRefresh.afterLoggedSet(
            exerciseID: id,
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

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await SessionActivityRefresh.clearRest()
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

    private static var current: Activity<SessionActivityAttributes>? {
        Activity<SessionActivityAttributes>.activities.first
    }

    static func afterLoggedSet(exerciseID: UUID, restEndsAt: Date) async {
        guard let activity = current else { return }
        var state = activity.content.state
        state.setsLogged += 1
        state.restEndsAt = restEndsAt
        await activity.update(ActivityContent(state: state, staleDate: restEndsAt))
    }

    static func clearRest() async {
        guard let activity = current else { return }
        var state = activity.content.state
        state.restEndsAt = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
