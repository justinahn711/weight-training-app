import Foundation
import Observation
import WeightTrainingCore
import WeightTrainingStore

/// The gym the app is currently rendering in (#67, #73).
///
/// A cache in front of the store, not a second source of truth. The record on
/// disk is authoritative and syncs; this exists because formatting a weight
/// happens hundreds of times a screen and must not become a fetch, and because
/// SwiftUI needs something observable to redraw against when the unit changes.
///
/// Deliberately *not* `@AppStorage`. A preference kept in `UserDefaults` would
/// not sync, so the same lifter opening the app on a second device would be
/// told their gym is marked in pounds — and the plate line under the bar would
/// name plates that aren't on the rack.
@Observable
@MainActor
final class GymSettings {
    static let shared = GymSettings()

    private(set) var config: GymConfig = .standard

    /// What the lifter reads and types in.
    var unit: MassUnit { config.unit }

    private init() {}

    /// Pulls the gym in from the store. Called at launch and after a sync
    /// import, alongside the reconcile that re-racks the lifts themselves.
    func refresh(from store: TrainingStore) {
        config = (try? store.gymConfig()) ?? .standard
    }

    /// Records a new gym and re-racks everything that follows it.
    /// - Returns: how many lifts changed, so the settings screen can say so.
    @discardableResult
    func save(_ new: GymConfig, to store: TrainingStore) throws -> Int {
        let changed = try store.saveGymConfig(new)
        config = new
        return changed
    }
}
