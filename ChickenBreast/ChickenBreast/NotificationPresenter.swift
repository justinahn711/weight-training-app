//
//  NotificationPresenter.swift
//  ChickenBreast
//

import UserNotifications

/// Lets the rest alert through while the app is on screen (#69).
///
/// iOS drops a local notification silently when the app that scheduled it is
/// in the foreground, unless a delegate says otherwise. There wasn't one, so
/// "Rest's up" was being discarded every time the session was being watched —
/// which is most of the time, because `isIdleTimerDisabled` keeps that screen
/// awake for the whole rest.
///
/// That left the haptic as the only thing between the lifter and a missed set,
/// and a haptic is a single fragile call with no failure it can report. Two
/// independent channels is the point: this one has a sound and a banner and
/// works even when the Taptic Engine won't.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    /// Wired in `ChickenBreastApp.init`, which is early enough — the first rest
    /// is minutes away from launch.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A banner over your own session was called noise once, and it would be
        // — if the haptic worked. It doesn't, and a set you didn't start is
        // louder than a banner you did.
        completionHandler([.banner, .sound, .list])
    }
}
