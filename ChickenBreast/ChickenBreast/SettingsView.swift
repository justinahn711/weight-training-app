//
//  SettingsView.swift
//  ChickenBreast
//

import SwiftUI
import UserNotifications
import WeightTrainingStore

/// The few things about the app that are a preference rather than a rule, and
/// the two questions about your data that need somewhere to be asked.
///
/// Deliberately small. Almost everything this app does is derived from logged
/// sets and shouldn't be configurable — a setting for it would be a second
/// source of truth. What lands here is the handful of choices that depend on
/// the room rather than the training: where the phone is during rest, and how
/// loudly it's allowed to say so.
///
/// Backup (#87, #88) and sync state (#89) sit here for a different reason.
/// They aren't preferences at all; they're the answers to "is my training
/// safe", and this is where someone goes looking for them.
struct SettingsView: View {
    /// Nil only when the store failed to open, which is the one case where
    /// there is nothing to export and nowhere to restore to.
    let store: TrainingStore?
    let sync: SyncStatus

    @AppStorage(RestAlertSettings.notificationKey) private var notification = true
    @AppStorage(RestAlertSettings.timingKey) private var timing = true

    /// Whether iOS will actually deliver what the toggle above asks for. A
    /// toggle that's on while notifications are denied at the system level is
    /// the app claiming something it can't do.
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            Section {
                Toggle("Notify when rest is over", isOn: $notification)

                if notification, let authorization, authorization == .denied {
                    Label(
                        "Notifications are off for ChickenBreast in iOS Settings, so this won't arrive.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Rest alert")
            } footer: {
                Text(notification
                     ? "A banner when the target passes, so a phone in a pocket still tells you. The buzz happens either way."
                     : "The phone will buzz when rest is over and say nothing else.")
            }

            Section {
                Toggle("Show alert timing", isOn: $timing)
            } footer: {
                Text("Adds a line to the rest banner reporting how late the buzz went out. Useful while that's still being chased; noise once it isn't.")
            }

            if let store {
                BackupSection(store: store)
            }

            SyncSection(status: sync)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authorization = await UNUserNotificationCenter.current()
                .notificationSettings()
                .authorizationStatus
        }
        // Asked again on the way in, because this is the screen someone opens
        // to check rather than to be told. A state computed at launch and left
        // there would answer a question about a different moment.
        .task {
            if let store { await sync.refresh(store: store) }
        }
    }
}
