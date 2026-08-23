//
//  RestAlertSettings.swift
//  ChickenBreast
//

import Foundation

/// What the rest alert is allowed to do, which is the lifter's call (#69).
///
/// The alert has two channels and they are not interchangeable. The buzz is
/// tactile and reaches a phone face-up on a bench; the notification is visual
/// and reaches a phone in a pocket. Which of those is wanted depends on where
/// the phone is and who else is in the room, and the app can't know either —
/// so it asks once, in Settings, and then does what it was told.
///
/// Plain `UserDefaults` rather than `@AppStorage`, because `SessionViewModel`
/// reads this too and it isn't a view. The keys are shared with the `Toggle`s
/// in `SettingsView`, which bind to the same store.
enum RestAlertSettings {

    /// Whether rest ending is allowed to post a notification.
    static let notificationKey = "rest-alert-notification"

    /// Whether the banner reports when the buzz actually went out.
    static let timingKey = "rest-alert-timing"

    /// Both default on. The notification is the channel that survives the
    /// phone being away, which is the case #69 exists for; the timing readout
    /// is on because the lateness it measures is still being chased, and it
    /// costs one line of caption text to leave visible.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notificationKey: true,
            timingKey: true,
        ])
    }

    static var notificationEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationKey)
    }

    static var showsTiming: Bool {
        UserDefaults.standard.bool(forKey: timingKey)
    }
}
