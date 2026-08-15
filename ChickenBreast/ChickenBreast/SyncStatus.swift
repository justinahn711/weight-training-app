//
//  SyncStatus.swift
//  ChickenBreast
//

import CloudKit
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

    private(set) var state: State = .checking

    /// Whether the store was even asked to sync, which is a separate question
    /// from whether iCloud is reachable.
    private(set) var storeRequestedSync = false

    /// Turns SwiftData's error into something that says what to do.
    ///
    /// `loadIssueModelContainer` is what SwiftData reports when it can't build
    /// a CloudKit container, and by far the most common cause is running a
    /// build that carries no iCloud entitlement — which is every simulator
    /// build here, since entitlements are only applied when signing for a
    /// device.
    static func explain(_ failure: String?) -> String {
        guard let failure else { return "the store opened without CloudKit" }
        if failure.contains("loadIssueModelContainer") {
            return "no iCloud entitlement in this build — sync needs a device build"
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
            Label(status.state.summary, systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
