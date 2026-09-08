//
//  SettingsView.swift
//  ChickenBreast
//

import SwiftUI
import UIKit
import UserNotifications
import WeightTrainingCore
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
    @Environment(\.scenePhase) private var scenePhase
    /// Nil only when the store failed to open. That is the one case where
    /// there is nothing to export and nowhere to restore to, and equally the
    /// case where the gym section has nothing to write to — both are left out
    /// rather than shown doing nothing.
    let store: TrainingStore?
    let sync: SyncStatus

    /// Threaded through to `BackupSection` so a restore can rebuild the
    /// screens derived from the data it just replaced.
    var onRestored: () -> Void = {}

    @AppStorage(RestAlertSettings.notificationKey) private var notification = true
    @AppStorage(RestAlertSettings.timingKey) private var timing = RestAlertSettings.timingDefault
    @AppStorage(RestAlertSettings.digestKey) private var digestReminder = false

    /// Whether iOS will actually deliver what the toggle above asks for. A
    /// toggle that's on while notifications are denied at the system level is
    /// the app claiming something it can't do.
    @State private var authorization: UNAuthorizationStatus?
    @State private var liveActivity: LiveActivityDiagnosticSnapshot?

    /// The gym being edited, mirrored from `GymSettings.shared` for display.
    ///
    /// Refreshed on appear, and every edit is built from the shared config
    /// rather than from this copy: a CloudKit import landing while Settings is
    /// open used to be overwritten by the next plate toggle, which committed a
    /// snapshot taken before the import.
    @State private var gym: GymConfig = GymSettings.shared.config

    /// How many lifts the last change re-racked, so a change that reached
    /// twenty exercises says so instead of happening silently (#73).
    @State private var reracked: Int?

    /// How many lifts stopped following the gym's rack, so the section can say
    /// that a change made here will not reach all of them.
    @State private var withOwnRack: Int?

    var body: some View {
        Form {
            if store != nil {
                gymSection
                plateSection
            }

            Section {
                Toggle("Notify when rest is over", isOn: $notification)
                    // Asked here as well as at the first rest, because this is
                    // the other moment the benefit is concrete — somebody has
                    // just said they want the banner. Only on the way on: a
                    // prompt when switching a thing *off* is the app asking to
                    // do what it was told not to (#110).
                    .onChange(of: notification) { _, isOn in
                        guard isOn else { return }
                        Task {
                            await RestNotification.requestAccess()
                            authorization = await UNUserNotificationCenter.current()
                                .notificationSettings()
                                .authorizationStatus
                        }
                    }

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
                Toggle("Remind me on Sundays", isOn: $digestReminder)
                    .onChange(of: digestReminder) { _, isOn in
                        Task {
                            if isOn {
                                await DigestNotification.requestAndSchedule()
                                authorization = await UNUserNotificationCenter.current()
                                    .notificationSettings()
                                    .authorizationStatus
                            } else {
                                DigestNotification.cancel()
                            }
                        }
                    }
            } header: {
                Text("Weekly summary")
            } footer: {
                Text("A Sunday evening nudge to read the week's findings. The digest itself is always on the Train screen — this only decides whether the phone brings it up.")
            }

            Section {
                Toggle("Show alert timing", isOn: $timing)
            } footer: {
                Text("Adds a line to the rest banner reporting how late the buzz went out. Enable it while troubleshooting an alert.")
            }

            Section {
                if let liveActivity {
                    LabeledContent("System setting", value: liveActivity.isEnabled ? "On" : "Off")
                    LabeledContent("Current activity", value: liveActivity.presence.rawValue)

                    if liveActivity.activityCount > 1 {
                        Label(
                            "\(liveActivity.activityCount) activities are running. Starting a workout will keep the current one and remove stale duplicates.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let failure = liveActivity.lastFailure {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last start failure")
                                .font(.subheadline.weight(.medium))
                            Text(failure)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    if !liveActivity.isEnabled {
                        Button("Open iOS Settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                } else {
                    ProgressView("Checking Live Activities…")
                }
            } header: {
                Text("Live Activity")
            } footer: {
                Text("Shows the current exercise and rest on the Lock Screen and Dynamic Island. Training and rest alerts still work when this is unavailable.")
            }

            if let store {
                BackupSection(onRestored: onRestored, store: store)

                // Inside the same guard as backup, because the only thing that
                // ever refreshes it needs the store. Shown without one it sits
                // on "Checking…" forever — telling the person who came here to
                // ask whether sync works precisely nothing, in the one case
                // where it definitely doesn't.
                SyncSection(status: sync)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Pick up a gym that changed while this screen was elsewhere —
            // another device's edit arriving by sync, most often.
            gym = GymSettings.shared.config
            withOwnRack = try? store?.liftsWithOwnRack()
            authorization = await UNUserNotificationCenter.current()
                .notificationSettings()
                .authorizationStatus
            liveActivity = LiveActivityDiagnostics.snapshot()
        }
        // Asked again on the way in, because this is the screen someone opens
        // to check rather than to be told. A state computed at launch and left
        // there would answer a question about a different moment.
        .task {
            if let store { await sync.refresh(store: store) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            liveActivity = LiveActivityDiagnostics.snapshot()
        }
    }

    // MARK: - Gym

    private var gymSection: some View {
        Section {
            Picker("Units", selection: unitBinding) {
                ForEach(MassUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                value: barBinding,
                in: gym.unit == .pounds ? 15...75 : 5...35,
                step: gym.unit == .pounds ? 5 : 2.5
            ) {
                HStack {
                    Text("Bar")
                    Spacer(minLength: 12)
                    Text(gym.unit.format(pounds: gym.barWeight.pounds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Your gym")
        } footer: {
            Text(gymFooter)
        }
    }

    private var plateSection: some View {
        Section {
            ForEach(plateChoices, id: \.self) { plate in
                Toggle(isOn: plateBinding(for: plate)) {
                    Text(format(plate))
                }
            }
        } header: {
            Text("Plates on the rack")
        } footer: {
            Text(plateFooter)
        }
    }

    /// Says that exceptions exist, and how many.
    ///
    /// The old text ended "unless it's been given a rack of its own", which is
    /// true and unfalsifiable from this screen: nothing said whether any lift
    /// had one. A change made here quietly skips them, which is #73's rule
    /// working correctly and looking like it did not (#123).
    private var plateFooter: String {
        if gym.availablePlates.isEmpty {
            return "Pick at least one plate size — with none, nothing can be loaded."
        }
        let base = "What every lift is built from, unless it's been given a rack of its own."
        guard let withOwnRack, withOwnRack > 0 else { return base }
        return "\(base) \(withOwnRack) \(withOwnRack == 1 ? "lift has" : "lifts have") one, and won't follow changes here."
    }

    private var gymFooter: String {
        if let reracked {
            return reracked == 0
                ? "Nothing needed changing."
                : "Re-racked \(reracked) \(reracked == 1 ? "lift" : "lifts"). Any lift you'd configured yourself was left alone."
        }
        return "Weights, targets and plate lines are all shown in this. What's logged is unchanged — switching units doesn't rewrite your history."
    }

    /// Plate sizes offered for a rack in this unit. Chosen per world, never
    /// converted: a metric gym has 20s and 1.25s, not 22.05s and 1.13s.
    private var plateChoices: [Double] {
        gym.unit == .pounds
            ? [45, 35, 25, 15, 10, 5, 2.5, 1.25]
            : [25, 20, 15, 10, 5, 2.5, 1.25]
    }

    /// Delegates to Core. This was a second verbatim copy of the old
    /// one-decimal rule, and it drove the "Plates on the rack" toggles — so
    /// the gym screen offered a 1.2 kg plate and a 1.2 lb plate, neither of
    /// which exists.
    private func format(_ value: Double, withSymbol: Bool = false) -> String {
        gym.unit.format(value, withSymbol: withSymbol)
    }

    private var unitBinding: Binding<MassUnit> {
        Binding(
            get: { gym.unit },
            set: { unit in
                // Switching units replaces the rack rather than converting it.
                // A pound rack run through a multiplier describes 20.4 kg
                // plates, which is not a thing anyone owns — the honest move is
                // to hand back the standard rack of the new world and let it be
                // corrected from there.
                commit(GymConfig(unit: unit))
            }
        )
    }

    private var barBinding: Binding<Double> {
        Binding(
            get: { gym.barWeight.value(in: gym.unit) },
            set: { value in
                var updated = GymSettings.shared.config
                updated.barWeight = Load(value, updated.unit)
                commit(updated)
            }
        )
    }

    private func plateBinding(for plate: Double) -> Binding<Bool> {
        Binding(
            get: { gym.availablePlates.contains(plate) },
            set: { keep in
                var updated = GymSettings.shared.config
                var plates = Set(updated.availablePlates)
                if keep {
                    plates.insert(plate)
                } else if plates.count > 1 {
                    // Never the last one. An empty rack is not a gym with no
                    // plates, it is a gym where nothing is buildable: the
                    // engine answers `nearestBuildable` from the bar alone, so
                    // every proposal collapses to 20 kg and gets written into
                    // progress state as though it were a real target.
                    plates.remove(plate)
                }
                updated.availablePlates = plates.sorted(by: >)
                commit(updated)
            }
        )
    }

    private func commit(_ updated: GymConfig) {
        gym = updated
        guard let store else { return }
        reracked = try? GymSettings.shared.save(updated, to: store)
        // Deliberately not recounted. `GymConfig.applied(to:)` returns early
        // for an exception and copies `usesGymRack` through unchanged for a
        // follower, so no gym save can change which lifts are exceptions — the
        // recount was provably a no-op, and it cost a second full fetch and
        // decode of the library on the main actor for every plate toggle.
    }
}
