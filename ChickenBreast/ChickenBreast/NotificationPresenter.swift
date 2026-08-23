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
        // This method only runs while the app is in the foreground, and a rest
        // can only be running with the session on screen — leaving it ends the
        // session and cancels the alert. So reaching here for a rest means the
        // banner is up and about to buzz, and the alert has nothing to add.
        //
        // Letting both through is worse than either alone: they land on the
        // same instant, the system's alert takes the vibration motor first, and
        // the buzz queues up behind it. It reads as the app telling you twice
        // and being late the second time.
        //
        // Away from the phone this method is never called and the notification
        // does the whole job, which is the split that was intended all along.
        if notification.request.identifier == RestNotification.identifier {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }
}
