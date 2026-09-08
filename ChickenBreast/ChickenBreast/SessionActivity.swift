//
//  SessionActivity.swift
//  ChickenBreast
//

import ActivityKit
import Foundation

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
    /// Reattach after returning from Train or relaunching. ActivityKit owns the
    /// activity across process boundaries; keeping only this controller's
    /// original reference would create a duplicate on Resume and leave the old
    /// one impossible for Finish to end.
    private var activity: Activity<SessionActivityAttributes>? =
        Activity<SessionActivityAttributes>.activities.first

    /// Whether the system will accept one at all. False when the user has
    /// turned Live Activities off for the app, which is a setting rather than
    /// an error.
    private var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(dayKind: String, state: SessionActivityAttributes.ContentState) {
        guard isAvailable, activity == nil else {
            update(state)
            return
        }
        activity = try? Activity.request(
            attributes: SessionActivityAttributes(dayKind: dayKind),
            content: ActivityContent(state: state, staleDate: nil)
        )
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

    /// Takes the activity down.
    ///
    /// Immediate rather than left to expire: leaving a session's target on the
    /// lock screen after the session ended is worse than never having shown it,
    /// because it's indistinguishable from a session still in progress.
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
