import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {

    // MARK: - Reading

    /// The gym as configured, or the standard pound gym if nobody has said.
    ///
    /// Never nil. An app that can't answer "what unit am I in" has nothing
    /// sensible to render, and "the gym you had before this feature existed" is
    /// the honest default for an install that predates it.
    public func gymConfig() throws -> GymConfig {
        guard let stored = try storedGymConfig() else { return .standard }
        return try stored.toDomain()
    }

    func storedGymConfig() throws -> StoredGymConfig? {
        let id = StoredGymConfig.singletonID
        var descriptor = FetchDescriptor<StoredGymConfig>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Writing

    /// Records the gym and re-racks every lift that follows it.
    ///
    /// The propagation is the point (#73): a lifter who switches their rack to
    /// kilograms means all of it, not "all of it and also please revisit twenty
    /// exercises". Lifts with a rack of their own are left exactly as they are.
    ///
    /// - Returns: how many exercises were re-racked, which is what lets the
    ///   settings screen say what it just did rather than changing things
    ///   silently.
    @discardableResult
    public func saveGymConfig(_ config: GymConfig, at date: Date = Date()) throws -> Int {
        if let existing = try storedGymConfig() {
            existing.update(from: config, at: date)
        } else {
            modelContext.insert(StoredGymConfig(config, updatedAt: date))
        }
        let changed = try applyGym(config)
        try saveChanges()
        return changed
    }

    /// Brings every lift that follows the gym into line with it.
    ///
    /// Safe and cheap to run on launch: on a store already in agreement it
    /// decodes each exercise's loading, finds nothing to change, and writes
    /// nothing. That matters because the gym record syncs but the propagation
    /// does not — a second device receives the new rack from CloudKit and has
    /// to re-derive its own exercises from it, exactly as `deduplicate()` has
    /// to re-run per device.
    @discardableResult
    public func reconcileGym() throws -> Int {
        let config = try gymConfig()
        let changed = try applyGym(config)
        if changed > 0 { try saveChanges() }
        return changed
    }

    /// How many lifts no longer follow the gym's rack.
    ///
    /// A lift diverges the moment its plate set stops matching the gym's, and
    /// nothing on screen said so — nor which lifts, nor that the divergence is
    /// effectively one-way, since `usesGymRack` is recomputed as "does this
    /// equal the gym's set" and rejoining means reproducing it exactly (#123).
    ///
    /// Counted rather than listed: the gym screen needs to say that exceptions
    /// exist, and the lift's own screen is where one is inspected and undone.
    /// An unreadable row is skipped for the same reason `applyGym` skips it.
    public func liftsWithOwnRack() throws -> Int {
        try modelContext.fetch(FetchDescriptor<StoredExercise>())
            .compactMap { try? $0.toDomain() }
            .filter { $0.loading?.usesGymRack == false }
            .count
    }

    /// - Returns: the number of stored exercises actually rewritten.
    private func applyGym(_ config: GymConfig) throws -> Int {
        var changed = 0
        for stored in try modelContext.fetch(FetchDescriptor<StoredExercise>()) {
            var exercise: Exercise
            do {
                exercise = try stored.toDomain()
            } catch {
                // One unreadable row must not stop the rest of the gym being
                // brought into line — it will surface on its own next read.
                continue
            }

            var updated = exercise
            if let loading = exercise.loading {
                updated.loading = config.applied(to: loading)
            }
            updated.increment = config.applied(
                to: exercise.increment, for: exercise.equipment
            )

            guard updated != exercise else { continue }
            stored.update(from: updated)
            changed += 1
        }
        return changed
    }
}
