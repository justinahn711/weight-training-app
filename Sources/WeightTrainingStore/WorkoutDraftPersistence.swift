import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {
    /// Starts or updates the one unfinished workout. The set log remains its
    /// own immediate write; this row only makes navigation intent durable.
    public func saveWorkoutDraft(_ draft: WorkoutDraft) throws {
        let rows = try modelContext.fetch(FetchDescriptor<StoredWorkoutDraft>())
        if let existing = rows.max(by: { $0.updatedAt < $1.updatedAt }) {
            existing.update(from: draft)
            for duplicate in rows where duplicate.persistentModelID != existing.persistentModelID {
                modelContext.delete(duplicate)
            }
        } else {
            modelContext.insert(StoredWorkoutDraft(draft))
        }
        try saveChanges()
    }

    /// The latest unfinished intent after sync reconciliation.
    public func workoutDraft() throws -> WorkoutDraft? {
        let rows = try modelContext.fetch(FetchDescriptor<StoredWorkoutDraft>())
        return try rows.max(by: { $0.updatedAt < $1.updatedAt })?.toDomain()
    }

    /// Rebuilds the exact lineup represented by a draft, rehydrating its sets
    /// from the durable log and returning to the intended exercise.
    public func resumeSession(_ draft: WorkoutDraft) throws -> Session {
        let templates = try dayTemplates()
        let template = templates.first { $0.kind == draft.kind }
            ?? DayTemplateLibrary.template(for: draft.kind)
        let exercisesByID = Dictionary(uniqueKeysWithValues: try exercises().map { ($0.id, $0) })

        let rebuilt = try draft.exerciseIDs.enumerated().compactMap { index, id -> SessionExercise? in
            guard let exercise = exercisesByID[id] else { return nil }
            // New drafts preserve the slot attached to each exact roster row.
            // The index fallback reads drafts written before #137.
            let slot = draft.slots.indices.contains(index)
                ? draft.slots[index]
                : (template.slots.indices.contains(index) ? template.slots[index] : nil)
            return try sessionExercise(for: exercise, slot: slot, startedAt: draft.startedAt, workoutID: draft.id)
        }

        var session = Session(kind: draft.kind, exercises: rebuilt, startedAt: draft.startedAt)
        if let currentExerciseID = draft.currentExerciseID {
            session.select(exerciseID: currentExerciseID)
        }
        return session
    }

    /// Clears only the transient intent. Logged sets remain untouched.
    public func clearWorkoutDraft(id: UUID) throws {
        let rows = try modelContext.fetch(FetchDescriptor<StoredWorkoutDraft>())
        for row in rows where row.draftID == id {
            modelContext.delete(row)
        }
        try saveChanges()
    }
}
