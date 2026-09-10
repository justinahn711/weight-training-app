//
//  SyncStatus.swift
//  ChickenBreast
//

import CloudKit
import CoreData
import Observation
import SwiftUI
import WeightTrainingStore

/// Whether sync is actually working.
///
/// Exists because nothing else can answer the question. SwiftData accepts a
/// CloudKit configuration without checking the entitlement or the account and
/// fails later, silently — so "is my data reaching iCloud" is unanswerable from
/// the store alone. This asks CloudKit directly.
@MainActor
@Observable
final class SyncStatus {

    enum State: Equatable {
        case checking
        case syncing
        case noAccount
        case restricted
        case failed(String)

        var summary: String {
            switch self {
            case .checking:   return "Checking iCloud…"
            case .syncing:    return "Syncing with iCloud"
            case .noAccount:  return "Not signed into iCloud — training is saved on this phone only"
            case .restricted: return "iCloud is restricted on this device"
            case .failed(let reason): return "iCloud unavailable: \(reason)"
            }
        }

        var isHealthy: Bool { self == .syncing }
    }

    /// The last mirroring export that finished, if one ever has.
    ///
    /// `State` answers "could we sync" — the account exists, the container
    /// built. This answers "did a set actually leave the phone", which is the
    /// question a reachable-but-idle store can't distinguish. A fresh simulator
    /// with no iCloud account sits at `.noAccount` and never exports; a signed-in
    /// one reports a success here within a minute of a logged set.
    enum Export: Equatable {
        case none
        case succeeded(Date)
        case failed(String, Date)
    }

    private(set) var state: State = .checking
    private(set) var lastExport: Export = .none

    /// When CloudKit last finished handing rows down to this device.
    ///
    /// Watched rather than ignored because an import is the one moment a
    /// duplicate can appear: `deduplicate()` runs at launch, and on a fresh
    /// install the first import arrives after it, seeding having already
    /// inserted the library into an apparently empty store. Whoever owns the
    /// store reconciles when this changes.
    private(set) var lastImport: Date?

    /// Whether the store was even asked to sync, which is a separate question
    /// from whether iCloud is reachable.
    private(set) var storeRequestedSync = false

    /// Why mirroring failed to start, when it did.
    ///
    /// Setup is the gate — nothing imports or exports until it succeeds — and
    /// the account check alone can't stand in for it. The common causes do show
    /// up there: a stale iCloud session reports `couldNotDetermine`, and the
    /// badge already says so. What it can't see is a setup that fails while the
    /// account is perfectly `.available` — a zone problem, a quota, a
    /// transient CloudKit error. Those would otherwise leave the app looking
    /// healthy and syncing nothing, which is how #19 stayed hidden for a day.
    private(set) var setupFailure: String?

    private var eventWatch: Task<Void, Never>?

    /// Turns SwiftData's error into something that says what to do.
    ///
    /// `loadIssueModelContainer` is SwiftData's blanket "couldn't build the
    /// CloudKit container", and on its own it says nothing about why. The two
    /// causes need different fixes and must not be collapsed:
    ///
    /// - A schema CloudKit refuses. Any non-optional attribute without a
    ///   default sinks the whole store, and the underlying error names it.
    ///   This is a code bug, and it's what #19 actually hit.
    /// - A missing or unreachable entitlement, which is a signing problem.
    ///
    /// Not the simulator case either way: simulator builds carry the entitlement
    /// and export to real CloudKit. What they lack is APNs, so remote changes
    /// never get pushed down. And a simulator with no iCloud account fails more
    /// quietly still — the container builds and the account check reports
    /// `.noAccount`.
    static func explain(_ failure: String?) -> String {
        guard let failure else { return "the store opened without CloudKit" }
        if failure.contains("all attributes be optional") {
            // Keep the attribute names: they're the entire fix.
            let names = failure
                .split(separator: ":")
                .last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return "a model attribute has no default, so CloudKit rejected the schema (\(names))"
        }
        if failure.contains("loadIssueModelContainer") {
            return "CloudKit couldn't open the store — check the schema and the entitlement"
        }
        return failure
    }

    func refresh(store: TrainingStore) async {
        storeRequestedSync = store.isCloudKitEnabled

        guard storeRequestedSync else {
            state = .failed(Self.explain(store.cloudKitFailure))
            return
        }

        do {
            switch try await CKContainer.default().accountStatus() {
            case .available:
                state = .syncing
            case .noAccount:
                state = .noAccount
            case .restricted:
                state = .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                state = .failed("couldn't reach iCloud")
            @unknown default:
                state = .failed("unknown account state")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }

        watchMirroringEvents()
    }

    /// Listens for mirroring events, so a failed export can't pass for a working
    /// one and an import can't land unnoticed.
    ///
    /// SwiftData is `NSPersistentCloudKitContainer` underneath and posts the
    /// same event notifications, which is the only place either outcome is
    /// reported — the store's save succeeds long before CloudKit is consulted,
    /// so nothing on the write path can tell you it later failed, and nothing at
    /// all announces rows arriving from another device.
    ///
    /// Events post twice, once on start and once on finish; only the finished
    /// ones carry a verdict, so the unfinished ones are dropped.
    private func watchMirroringEvents() {
        guard eventWatch == nil else { return }
        eventWatch = Task { [weak self] in
            let events = NotificationCenter.default.notifications(
                named: NSPersistentCloudKitContainer.eventChangedNotification
            )
            for await note in events {
                guard
                    let event = note.userInfo?[
                        NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                    ] as? NSPersistentCloudKitContainer.Event,
                    let finished = event.endDate
                else { continue }

                guard event.type == .export else {
                    // The event carries no "did anything change" flag, so every
                    // successful import is reported. That's affordable: the only
                    // listener re-runs `deduplicate()`, which on a clean store
                    // is one fetch per entity and no writes.
                    if event.type == .import, event.succeeded {
                        self?.lastImport = finished
                    }
                    // Setup is the gate: nothing imports or exports until it
                    // succeeds, so a failure here means the store is local-only
                    // no matter how healthy everything upstream looks. A later
                    // success clears it, because setup retries on every launch
                    // and recovers on its own once the account does.
                    if event.type == .setup {
                        self?.setupFailure = event.succeeded
                            ? nil
                            : (event.error?.localizedDescription ?? "unknown error")
                    }
                    continue
                }

                // Ends the loop once the status object is gone, rather than
                // leaving a task awaiting notifications nobody reads.
                guard let self else { break }

                self.lastExport = event.succeeded
                    ? .succeeded(finished)
                    : .failed(event.error?.localizedDescription ?? "unknown error", finished)
            }
        }
    }
}

/// A one-line sync indicator.
///
/// Shown only when something is wrong. A permanent "everything is fine" badge
/// is noise on a screen whose job is to tell you what to train.
struct SyncBadge: View {
    let status: SyncStatus

    var body: some View {
        if !status.state.isHealthy, status.state != .checking {
            line(status.state.summary)
        } else if let setupFailure = status.setupFailure {
            // Ranked above the export failure because it explains it: when
            // setup never completed, no export was ever attempted, so a
            // "didn't accept the last save" line would be describing a
            // consequence and pointing at the wrong thing.
            line("iCloud sync didn't start: \(setupFailure)")
        } else if case .failed(let reason, _) = status.lastExport {
            // Reachable but not arriving. Worth its own line: this is the case
            // that otherwise looks identical to working sync.
            line("iCloud didn't accept the last save: \(reason)")
        }
    }

    private func line(_ text: String) -> some View {
        Label(text, systemImage: "icloud.slash")
            .font(.caption)
            // `.secondary` at caption size fails WCAG contrast — the system
            // audit measured it (#114). Secondary was the wrong role anyway:
            // every string this renders is a warning that training may not be
            // reaching the other device, which is the last thing on the screen
            // that should recede into the background.
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The deliberate answer to "is my training backed up right now" (#89).
///
/// `SyncBadge` and this are not redundant: the badge interrupts, this one
/// answers. The badge stays silent while everything is fine, which is right on
/// a screen you're reading for your next set and useless when you came
/// specifically to check.
///
/// The states that matter are the quiet ones. A phone never signed into iCloud
/// sits at `.noAccount` from its first session and looks completely normal —
/// months of training can accumulate on one device with nothing on screen that
/// reads as wrong.
struct SyncSection: View {
    let status: SyncStatus

    var body: some View {
        Section {
            LabeledContent {
                Text(headline).foregroundStyle(tint)
            } label: {
                Label("iCloud", systemImage: symbol)
            }

            switch status.lastExport {
            case .succeeded(let date):
                LabeledContent("Last sent up", value: date.formatted(.relative(presentation: .named)))
            case .failed(_, let date):
                LabeledContent("Last attempt", value: date.formatted(.relative(presentation: .named)))
            case .none:
                EmptyView()
            }

            if let lastImport = status.lastImport {
                LabeledContent(
                    "Last received",
                    value: lastImport.formatted(.relative(presentation: .named))
                )
            }

            if let setupFailure = status.setupFailure {
                detail("Sync didn't start: \(setupFailure)")
            }

            // Ranked below setup, which explains it: when setup never
            // completed no export was attempted, so this line would be
            // describing a consequence and pointing at the wrong thing.
            if status.setupFailure == nil, case .failed(let reason, _) = status.lastExport {
                detail("iCloud didn't accept the last save: \(reason)")
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(footer)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var headline: String {
        switch status.state {
        case .checking:   return "Checking…"
        case .syncing:    return "On"
        case .noAccount:  return "This phone only"
        case .restricted: return "Restricted"
        case .failed:     return "Unavailable"
        }
    }

    private var symbol: String {
        switch status.state {
        case .checking:               return "icloud"
        case .syncing:                return "checkmark.icloud"
        case .noAccount, .restricted: return "icloud.slash"
        case .failed:                 return "exclamationmark.icloud"
        }
    }

    private var tint: Color {
        switch status.state {
        case .checking:               return .secondary
        case .syncing:                return .green
        case .noAccount, .restricted: return .orange
        case .failed:                 return .orange
        }
    }

    /// Kept honest about which problems are problems.
    ///
    /// An unreachable iCloud in a gym basement is normal and not worth
    /// alarming about; a save iCloud refused is not, and is the case that
    /// otherwise looks identical to working sync. Collapsing both to a red
    /// mark would train the reader to ignore the one that matters.
    private var footer: String {
        switch status.state {
        case .checking:
            return "Asking iCloud whether it can see this device."
        case .syncing:
            if case .failed = status.lastExport {
                return "iCloud is reachable but refused the last save, so recent training may exist only on this phone. Export a backup."
            }
            return "Training on this phone reaches your other devices. iCloud is one account holding one copy, though — export a backup for anything you'd hate to lose."
        case .noAccount:
            return "Training is saved on this phone only, and nothing is leaving it. Sign into iCloud in the Settings app to sync — and export a backup either way."
        case .restricted:
            return "iCloud is turned off for this device by a profile or parental controls. Export a backup to keep a copy."
        case .failed:
            return "Can't reach iCloud right now. That's normal in a basement and usually fixes itself; if it persists, export a backup."
        }
    }
}
