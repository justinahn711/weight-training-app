//
//  SettingsView.swift
//  ChickenBreast
//

import SwiftUI
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
    /// Nil only when the store failed to open. That is the one case where
    /// there is nothing to export and nowhere to restore to, and equally the
    /// case where the gym section has nothing to write to — both are left out
    /// rather than shown doing nothing.
    let store: TrainingStore?
    let sync: SyncStatus

    @AppStorage(RestAlertSettings.notificationKey) private var notification = true
    @AppStorage(RestAlertSettings.timingKey) private var timing = true

    /// Whether iOS will actually deliver what the toggle above asks for. A
    /// toggle that's on while notifications are denied at the system level is
    /// the app claiming something it can't do.
    @State private var authorization: UNAuthorizationStatus?

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

    var body: some View {
        Form {
            if store != nil {
                gymSection
                plateSection
            }

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
            // Pick up a gym that changed while this screen was elsewhere —
            // another device's edit arriving by sync, most often.
            gym = GymSettings.shared.config
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
            Text(gym.availablePlates.isEmpty
                 ? "Pick at least one plate size — with none, nothing can be loaded."
                 : "What every lift is built from, unless it's been given a rack of its own.")
        }
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

    private func format(_ value: Double) -> String {
        let number = value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(number) \(gym.unit.symbol)"
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
    }
}
