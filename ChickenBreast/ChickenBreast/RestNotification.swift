//
//  RestNotification.swift
//  ChickenBreast
//

import Foundation
import UserNotifications
import WeightTrainingCore

/// What `SessionViewModel` needs from the rest alerts, as a seam (#261, #263).
///
/// The view model decides *whether* a rest's alerts should exist; this is the
/// only way it reaches the notification centre, so a unit test can stand in a
/// recorder and assert what was scheduled and cancelled without a real
/// `UNUserNotificationCenter`, an authorization prompt, or a device. The
/// lock-screen intents use it too (`SessionActivityRefresh`).
///
/// Main-actor explicitly rather than by the app target's default: this file
/// is also compiled into the widget extension, which has no such default,
/// because `SessionIntents.swift` is.
@MainActor
protocol RestAlertScheduling {
    /// Replaces whatever is pending with the pair for `rest`.
    func schedule(for rest: RestTimer, exercise: String, next: String?)
    /// Removes both pending alerts.
    func cancel()
}

/// The real centre, through `RestNotification`.
@MainActor
struct SystemRestAlerts: RestAlertScheduling {
    /// Usable as a default argument from any context; it holds nothing.
    nonisolated init() {}

    func schedule(for rest: RestTimer, exercise: String, next: String?) {
        RestNotification.schedule(for: rest, exercise: exercise, next: next)
    }

    func cancel() {
        RestNotification.cancel()
    }
}

/// Tells you rest is over when you aren't looking at the phone (#69).
///
/// #23's whole premise is the phone staying in a pocket with the session on the
/// lock screen. That only works if something reaches out at the moment the next
/// set is due — otherwise the rest clock is useful only while being watched,
/// which is the situation the Live Activity was built to escape.
///
/// One notification at the target, never a repeat. Rest running long is
/// information rather than an error — the session screen counts the overrun up
/// rather than nagging — and a second buzz would be the app deciding your rest
/// was wrong.
@MainActor
enum RestNotification {

    /// A single identifier, replaced rather than accumulated. Only one rest can
    /// be running, and a set logged mid-rest supersedes the one before it.
    static let identifier = "rest-complete"

    /// The check-in that fires when the clock has counted a full
    /// `RestTimer.maximumOverrun` past the target: ten minutes over is more
    /// likely a phone left on a bench than a rest.
    static let idleIdentifier = "rest-idle-check"

    /// Schedules the alert for the end of this rest.
    ///
    /// - Parameter next: what's due when it fires, so a glance at the lock
    ///   screen is enough to start the set. Safe to name here because rest is
    ///   measured in minutes — unlike the weekly digest, whose findings would
    ///   be stale by the time it arrived.
    ///
    /// Returns at once; the authorization check and the requests happen on a
    /// task. A `cancel()` or a newer `schedule` issued before that task gets
    /// there wins — the late task sees its ticket is stale and adds nothing —
    /// so a rest skipped a moment after it began can't have its alerts
    /// resurrected by the schedule that was still waiting on access.
    static func schedule(for rest: RestTimer, exercise: String, next: String?) {
        generation &+= 1
        let ticket = generation
        // Turned off in Settings means no notification and no authorization
        // prompt — asking for permission to do something the lifter has
        // already declined is how an app trains someone to say no.
        guard RestAlertSettings.notificationEnabled else {
            removePending()
            return
        }

        Task {
            // The moment this asks is already right — a rest timer is
            // running, so the alert it wants permission for is the thing
            // about to happen.
            guard await requestAccess(), ticket == generation else { return }
            add(for: rest, exercise: exercise, next: next, now: Date())
        }
    }

    /// Bumped by every `schedule` and `cancel`, so only the latest one acts.
    private static var generation = 0

    /// Replaces the pending pair. No suspension between the remove and the
    /// adds, so nothing can interleave with them.
    private static func add(for rest: RestTimer, exercise: String, next: String?, now: Date) {
        let center = UNUserNotificationCenter.current()
        removePending()
        let plan = Self.plan(for: rest, now: now)

        // Already over by the time we got here — nothing useful to schedule,
        // and a zero interval is rejected outright. The check-in below is
        // still owed: a rest resumed after its target is still a rest (#263).
        if let completionIn = plan.completionIn {
            let content = UNMutableNotificationContent()
            content.title = "Rest's up"
            content.body = next.map { "\(exercise) — \($0)" } ?? exercise
            content.sound = .default
            // Deliberately not .timeSensitive yet. That level needs its own
            // entitlement, and an entitlement the App ID hasn't been granted
            // fails the whole device build rather than degrading — which is
            // how healthkit-access broke #26's first device build. Worth
            // adding once it can be verified against a real device; a normal
            // alert delivers fine in the meantime, it just won't pierce a
            // Focus.
            center.add(
                UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: completionIn, repeats: false)
                ),
                withCompletionHandler: nil
            )
        }

        // Scheduled with the rest itself, so the two always agree and one
        // `cancel()` clears both.
        if let idleCheckIn = plan.idleCheckIn {
            let idle = UNMutableNotificationContent()
            idle.title = "Still working out?"
            idle.body = "Your rest has been running for ten minutes."
            idle.sound = .default
            center.add(
                UNNotificationRequest(
                    identifier: idleIdentifier,
                    content: idle,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: idleCheckIn, repeats: false)
                ),
                withCompletionHandler: nil
            )
        }
    }

    /// When each of the two alerts should fire for `rest`, as intervals from
    /// `now`, or nil for one that has nothing left to say.
    ///
    /// Pulled out of `schedule` so the timing can be checked without a
    /// notification centre.
    struct Plan: Equatable {
        /// Seconds until "Rest's up".
        var completionIn: TimeInterval?
        /// Seconds until "Still working out?".
        var idleCheckIn: TimeInterval?
    }

    /// Anything under half a second is treated as already due: a zero or
    /// negative interval is rejected outright by the trigger.
    static func plan(for rest: RestTimer, now: Date) -> Plan {
        let remaining = rest.endsAt.timeIntervalSince(now)
        let untilCheckIn = rest.expiresAt.timeIntervalSince(now)
        return Plan(
            completionIn: remaining > 0.5 ? remaining : nil,
            idleCheckIn: untilCheckIn > 0.5 ? untilCheckIn : nil
        )
    }

    /// Asks for notification access, serialised against every other prompt.
    ///
    /// What the first-rest request lacked was a guarantee that nothing else
    /// was asking at the same time: starting a session while launch was still
    /// settling could stack this on the Health sheet (#110). Also called from
    /// the Settings toggle, which is the other moment the benefit is concrete.
    ///
    /// - Returns: whether notifications may be posted.
    @discardableResult
    static func requestAccess() async -> Bool {
        await PermissionQueue.shared.run {
            let center = UNUserNotificationCenter.current()
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Called whenever the rest stops being real: skipped, undone, swapped
    /// away, expired, or the session left. A buzz for a set you took back is worse than no buzz.
    static func cancel() {
        generation &+= 1
        removePending()
    }

    private static func removePending() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier, idleIdentifier])
    }
}
