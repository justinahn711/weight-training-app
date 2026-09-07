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

    /// Diagnostic detail is opt-in. Keep this value shared with both
    /// `@AppStorage` readers so an unset preference means the same thing at
    /// launch, in Settings, and in the rest banner (#133).
    static let timingDefault = false

    /// Whether the Sunday digest reminder is wanted (#110).
    ///
    /// Defaults **off**. Unlike the rest notification above, this asks for a
    /// weekly interruption, and it used to be arranged by requesting
    /// notification access at first launch — before the person had seen a
    /// digest, or the app. Off by default means the reminder exists for people
    /// who went looking for it, which is the only group it was ever useful to.
    static let digestKey = "digest-reminder"

    /// Notifications default on because that channel survives the phone being
    /// away, which is the case #69 exists for. Timing is troubleshooting
    /// detail, so it stays available in Settings without appearing in an
    /// ordinary workout unless explicitly enabled.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notificationKey: true,
            timingKey: timingDefault,
        ])
    }

    static var notificationEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationKey)
    }

    static var showsTiming: Bool {
        UserDefaults.standard.bool(forKey: timingKey)
    }
}
