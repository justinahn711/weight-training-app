//
//  AppStore.swift
//  ChickenBreast
//

import Foundation
import WeightTrainingStore

/// The process's one `TrainingStore`.
///
/// Exists because the session screen is no longer the only thing that writes.
/// A Live Activity button runs a `LiveActivityIntent` in this same process but
/// outside any view (#23), and if it opened its own store there would be two
/// `ModelContainer`s over one file: two caches that don't see each other's
/// writes, so a set logged from the lock screen would be missing from the
/// session screen until relaunch.
///
/// Opened lazily and kept, rather than injected, because the intent has nothing
/// to be injected from — it's constructed by the system.
@MainActor
final class AppStore {
    static let shared = AppStore()

    private var opened: TrainingStore?

    private init() {}

    /// The store, opening it on first use.
    ///
    /// Sync is requested here rather than at each call site so every entry
    /// point — the app launching, an intent firing on a locked phone — gets the
    /// same store with the same CloudKit configuration.
    func store() throws -> TrainingStore {
        if let opened { return opened }
        let store = try TrainingStore(syncsWithCloudKit: true)
        opened = store
        return store
    }
}
