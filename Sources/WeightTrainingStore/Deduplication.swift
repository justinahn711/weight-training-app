import Foundation
import SwiftData
import WeightTrainingCore

/// What a dedupe pass removed.
public struct DeduplicationReport: Hashable, Sendable {
    public var exercises: Int = 0
    public var sets: Int = 0
    public var progressStates: Int = 0
    public var dayTemplates: Int = 0
    public var gymConfigs: Int = 0
    public var workoutDrafts: Int = 0

    public var total: Int {
        exercises + sets + progressStates + dayTemplates + gymConfigs + workoutDrafts
    }
    public var isEmpty: Bool { total == 0 }
}

extension TrainingStore {

    /// Merges rows that share an identity.
    ///
    /// This is what replaces the unique constraints the schema had to give up
    /// for CloudKit (#19). A synced store cannot enforce uniqueness at the
    /// database level: two devices offline at the same gym can each create the
    /// same row, and neither is wrong until they meet. The reconciliation has
    /// to happen after the fact, here.
    ///
    /// It is safe to run on every launch — on a store with no duplicates it is
    /// a single fetch per entity and no writes.
    ///
    /// Called before reads rather than on a timer, so a duplicate can never be
    /// observed by the app even briefly.
    @discardableResult
    public func deduplicate() throws -> DeduplicationReport {
        var report = DeduplicationReport()

        report.exercises = try collapse(
            FetchDescriptor<StoredExercise>(), key: \.id
        ) { candidates in
            // Identical definitions by construction — the seeded ids mean the
            // same lift really is the same lift. Keep either.
            candidates.first
        }

        report.sets = try collapse(
            FetchDescriptor<StoredSetLog>(), key: \.id
        ) { candidates in
            // A set is immutable once logged, so duplicates are the same event
            // recorded twice.
            candidates.first
        }

        report.progressStates = try collapse(
            FetchDescriptor<StoredProgressState>(), key: \.exerciseID
        ) { candidates in
            // The only genuinely conflicting entity: two devices can both
            // advance a lift's target while offline. The most recently
            // performed one wins, because it saw the later session — and a
            // state that never recorded a session loses to one that did.
            candidates.max {
                ($0.lastPerformedAt ?? .distantPast) < ($1.lastPerformedAt ?? .distantPast)
            }
        }

        report.dayTemplates = try collapse(
            FetchDescriptor<StoredDayTemplate>(), key: \.id
        ) { candidates in
            candidates.first
        }

        report.gymConfigs = try collapse(
            FetchDescriptor<StoredGymConfig>(), key: \.id
        ) { candidates in
            // The one entity where duplicates hold genuinely different
            // opinions: two devices can each describe the rack while offline,
            // and both descriptions are real. The later edit wins, because it
            // is the one made with the other already known about — or, if they
            // truly crossed, the one the lifter touched most recently.
            candidates.max { $0.updatedAt < $1.updatedAt }
        }

        report.workoutDrafts = try collapse(
            FetchDescriptor<StoredWorkoutDraft>(), key: \.id
        ) { candidates in
            candidates.max { $0.updatedAt < $1.updatedAt }
        }

        if !report.isEmpty {
            try saveChanges()
        }
        return report
    }

    /// Groups rows by `key`, keeps whichever `winner` picks, deletes the rest.
    private func collapse<Model: PersistentModel, Key: Hashable>(
        _ descriptor: FetchDescriptor<Model>,
        key: KeyPath<Model, Key>,
        winner: ([Model]) -> Model?
    ) throws -> Int {
        let rows = try modelContext.fetch(descriptor)
        let grouped = Dictionary(grouping: rows) { $0[keyPath: key] }

        var removed = 0
        for (_, candidates) in grouped where candidates.count > 1 {
            guard let keep = winner(candidates) else { continue }
            for row in candidates where row.persistentModelID != keep.persistentModelID {
                modelContext.delete(row)
                removed += 1
            }
        }
        return removed
    }
}
