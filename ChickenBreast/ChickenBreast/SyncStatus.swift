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
        } else if case .failed(let reason, _) = status.lastExport {
            // Reachable but not arriving. Worth its own line: this is the case
            // that otherwise looks identical to working sync.
            line("iCloud didn't accept the last save: \(reason)")
        }
    }

    private func line(_ text: String) -> some View {
        Label(text, systemImage: "icloud.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
