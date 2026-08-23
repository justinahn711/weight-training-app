//
//  RestNotification.swift
//  ChickenBreast
//

import Foundation
import UserNotifications
import WeightTrainingCore

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
enum RestNotification {

    /// A single identifier, replaced rather than accumulated. Only one rest can
    /// be running, and a set logged mid-rest supersedes the one before it.
    static let identifier = "rest-complete"

    /// Schedules the alert for the end of this rest.
    ///
    /// - Parameter next: what's due when it fires, so a glance at the lock
    ///   screen is enough to start the set. Safe to name here because rest is
    ///   measured in minutes — unlike the weekly digest, whose findings would
    ///   be stale by the time it arrived.
    static func schedule(for rest: RestTimer, exercise: String, next: String?) async {
        // Turned off in Settings means no notification and no authorization
        // prompt — asking for permission to do something the lifter has
        // already declined is how an app trains someone to say no.
        guard RestAlertSettings.notificationEnabled else {
            cancel()
            return
        }

        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
              granted else { return }

        cancel()

        let remaining = rest.endsAt.timeIntervalSinceNow
        // Already over by the time we got here — nothing useful to schedule,
        // and a zero interval is rejected outright.
        guard remaining > 0.5 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rest's up"
        content.body = next.map { "\(exercise) — \($0)" } ?? exercise
        content.sound = .default
        // Deliberately not .timeSensitive yet. That level needs its own
        // entitlement, and an entitlement the App ID hasn't been granted fails
        // the whole device build rather than degrading — which is how
        // healthkit-access broke #26's first device build. Worth adding once it
        // can be verified against a real device; a normal alert delivers fine
        // in the meantime, it just won't pierce a Focus.

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        )
        try? await center.add(request)
    }

    /// Called whenever the rest stops being real: skipped, undone, or the
    /// session left. A buzz for a set you took back is worse than no buzz.
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
