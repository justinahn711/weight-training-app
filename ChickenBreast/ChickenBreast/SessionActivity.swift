//
//  SessionActivity.swift
//  ChickenBreast
//

import ActivityKit
import Foundation
import WeightTrainingCore

/// What the lock screen and Dynamic Island show during a session (#23).
///
/// Shared with the widget extension, which renders it. Deliberately a handful
/// of pre-formatted strings and one date rather than domain types: everything
/// crossing into the extension is encoded, decoded, and re-rendered by the
/// system, so the less structure that has to survive the trip the fewer ways
/// there are for the two sides to disagree about a lift.
struct SessionActivityAttributes: ActivityAttributes {

    /// The parts that change while the session runs.
    struct ContentState: Codable, Hashable {
        /// The lift being performed right now.
        var exerciseName: String

        /// The target, already formatted — "135 lb × 8 @ 8", or the cold-start
        /// line for a lift with no history.
        var targetLine: String

        /// Working sets done today. Not "3 of 4" — the app prescribes a target,
        /// never a set count, so there is no denominator to show.
        var setsLogged: Int

        /// What the lock-screen button would log, carried as values rather than
        /// looked up when it's tapped.
        ///
        /// The button must log exactly the set shown above it. Re-deriving the
        /// target inside the intent would let the two drift — the phone can sit
        /// locked for minutes while a suggestion elsewhere moves the target —
        /// and logging a weight the screen never displayed is the one outcome
        /// worse than not logging at all.
        var exerciseID: UUID
        var targetPounds: Double?
        var targetReps: Int
        var targetRPE: Double?

        /// Stable identity for the currently offered Log action. The intent
        /// also uses it as the persisted set id, making a repeated delivery
        /// idempotent.
        var logActionID: UUID? = nil

        /// The lock-screen set which can still be taken back. Optional fields
        /// keep activities created by an older build decodable after upgrade.
        var lastLoggedSetID: UUID? = nil

        /// Whether there's a target to log at all. A first-ever lift has none,
        /// and the button hides rather than inventing one.
        var canLogTarget: Bool { targetPounds != nil }

        /// When the current rest ends, or nil when not resting.
        ///
        /// A date rather than a countdown, for the same reason `RestTimer`
        /// stores `startedAt`: the widget renders it with `Text(timerInterval:)`
        /// and the system ticks it down on its own. Sending a decrementing
        /// number would need an update per second, which the system would
        /// throttle long before the rest was over.
        var restEndsAt: Date?

        var isResting: Bool { restEndsAt != nil }
    }

    /// Fixed for the life of the activity.
    var dayKind: String
    /// Optional so an activity created before resumable workouts shipped can
    /// still be decoded and adopted after an upgrade.
    var workoutID: String? = nil
}

struct LiveActivityDiagnosticSnapshot: Equatable {
    enum Presence: String { case active = "Active", stale = "Stale", inactive = "Inactive" }
    let isEnabled: Bool
    let presence: Presence
    let activityCount: Int
    let lastFailure: String?
}

@MainActor
enum LiveActivityDiagnostics {
    private static let failureKey = "liveActivity.lastRequestFailure"

    static func snapshot() -> LiveActivityDiagnosticSnapshot {
        let activities = Activity<SessionActivityAttributes>.activities
        let presence: LiveActivityDiagnosticSnapshot.Presence
        if activities.contains(where: { $0.activityState == .active }) {
            presence = .active
        } else if activities.contains(where: { $0.activityState == .stale }) {
            presence = .stale
        } else {
            presence = .inactive
        }
        return LiveActivityDiagnosticSnapshot(
            isEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
            presence: presence,
            activityCount: activities.count,
            lastFailure: UserDefaults.standard.string(forKey: failureKey)
        )
    }

    static func record(_ error: Error) {
        UserDefaults.standard.set(
            "\(String(reflecting: type(of: error))): \(error.localizedDescription)",
            forKey: failureKey
        )
    }

    static func clearFailure() {
        UserDefaults.standard.removeObject(forKey: failureKey)
    }
}

/// Drives the session's Live Activity.
///
/// Every mutation the session makes routes through here rather than through
/// ActivityKit directly, so there is one place that knows whether an activity
/// exists and one place that decides what it says.
///
/// Failures are swallowed on purpose. A Live Activity is a convenience laid
/// over a session that works perfectly without it — the phone in your pocket is
/// nice, the set being logged is not optional — so nothing here is allowed to
/// interrupt a lift with an error.
@MainActor
final class SessionActivityController {
    private let workoutID: String
    private var activity: Activity<SessionActivityAttributes>?
    private var reconciliation: Task<Void, Never>?

    init(workoutID: UUID) {
        self.workoutID = workoutID.uuidString
    }

    /// Whether the system will accept one at all. False when the user has
    /// turned Live Activities off for the app, which is a setting rather than
    /// an error.
    private var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(dayKind: String, state: SessionActivityAttributes.ContentState) {
        guard isAvailable else { return }
        reconciliation?.cancel()
        reconciliation = Task { [weak self] in
            guard let self else { return }
            let running = Activity<SessionActivityAttributes>.activities
            // Prefer exact workout identity. A legacy activity from before
            // #132 had no id, so the same day kind is the safe upgrade bridge.
            let keeperID = SessionActivitySelection.keeperID(
                workoutID: workoutID,
                dayKind: dayKind,
                from: running.map {
                    SessionActivityCandidate(
                        id: $0.id,
                        workoutID: $0.attributes.workoutID,
                        dayKind: $0.attributes.dayKind
                    )
                }
            )
            let keeper = running.first { $0.id == keeperID }

            if let keeper {
                activity = keeper
                for duplicate in running where duplicate.id != keeper.id {
                    await duplicate.end(nil, dismissalPolicy: .immediate)
                }
                guard !Task.isCancelled else { return }
                LiveActivityDiagnostics.clearFailure()
                update(state)
                return
            }

            // No current activity: remove leftovers before requesting their
            // replacement, so ActivityKit never has to choose which workout to
            // show on the Lock Screen.
            for stale in running {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
            guard !Task.isCancelled else { return }
            do {
                activity = try Activity.request(
                    attributes: SessionActivityAttributes(
                        dayKind: dayKind,
                        workoutID: workoutID
                    ),
                    content: ActivityContent(state: state, staleDate: nil)
                )
                LiveActivityDiagnostics.clearFailure()
            } catch {
                LiveActivityDiagnostics.record(error)
            }
        }
    }

    func update(_ state: SessionActivityAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(
                ActivityContent(
                    state: state,
                    // Rest ending is the moment the content stops being true,
                    // so the system dims it then rather than showing a finished
                    // countdown as if it were live.
                    staleDate: state.restEndsAt
                )
            )
        }
    }

    /// The system's copy is authoritative for actions performed while locked.
    /// Query ActivityKit rather than the controller's cached reference because
    /// an intent can run in a different process lifetime.
    func currentState() -> SessionActivityAttributes.ContentState? {
        Activity<SessionActivityAttributes>.activities.first {
            $0.attributes.workoutID == workoutID
        }?.content.state
    }

    /// Takes the activity down.
    ///
    /// Immediate rather than left to expire: leaving a session's target on the
    /// lock screen after the session ended is worse than never having shown it,
    /// because it's indistinguishable from a session still in progress.
    func end() {
        let inFlight = reconciliation
        inFlight?.cancel()
        reconciliation = nil
        let adoptedLegacyID = activity?.attributes.workoutID == nil ? activity?.id : nil
        self.activity = nil
        Task {
            // A request is synchronous once entered and can win a race with
            // cancellation. Wait for it to settle, then query ActivityKit
            // again so Finish cannot leave a just-created activity behind.
            await inFlight?.value
            let owned = Activity<SessionActivityAttributes>.activities.filter {
                $0.attributes.workoutID == workoutID || $0.id == adoptedLegacyID
            }
            for activity in owned {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
