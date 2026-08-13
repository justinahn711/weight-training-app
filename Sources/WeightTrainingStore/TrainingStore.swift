import Foundation
import SwiftData
import WeightTrainingCore

/// The app's single door to persisted training data.
///
/// Callers hand over and receive `WeightTrainingCore` value types; the stored
/// classes never escape this file's API. That keeps SwiftData out of the view
/// layer and out of the progression engine, so the rules stay unit-testable and
/// the persistence shape can change without touching them.
///
/// Main-actor bound because it's driven by the session screen and SwiftData's
/// `ModelContext` is not safe to share across actors. Nothing here does enough
/// work to be worth moving off the main thread — a session is a few dozen rows.
@MainActor
public final class TrainingStore {
    public let container: ModelContainer

    private var context: ModelContext { container.mainContext }

    /// - Parameter url: where the store file lives. Passing `nil` uses
    ///   SwiftData's default application-support location, which is what the
    ///   app ships with; tests pass a temp URL to get an isolated file.
    public init(url: URL? = nil) throws {
        let schema = Schema(TrainingSchema.models)
        let configuration = url.map {
            ModelConfiguration(schema: schema, url: $0)
        } ?? ModelConfiguration(schema: schema)
        self.container = try ModelContainer(for: schema, configurations: configuration)
    }

    /// An in-memory store, for previews and for tests that don't care about
    /// surviving a relaunch.
    public static func inMemory() throws -> TrainingStore {
        let schema = Schema(TrainingSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try TrainingStore(container: ModelContainer(for: schema, configurations: configuration))
    }

    private init(container: ModelContainer) {
        self.container = container
    }

    /// Flushes pending changes.
    ///
    /// Every mutating method below calls this rather than leaving the context
    /// dirty. A lifting app gets backgrounded mid-session constantly, and an
    /// unsaved set is a lost set.
    private func commit() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    // MARK: - Exercises

    /// Inserts the exercise, or overwrites the existing row with the same id.
    public func upsert(_ exercise: Exercise) throws {
        if let existing = try storedExercise(id: exercise.id) {
            existing.update(from: exercise)
        } else {
            context.insert(StoredExercise(exercise))
        }
        try commit()
    }

    public func upsert(_ exercises: [Exercise]) throws {
        for exercise in exercises {
            if let existing = try storedExercise(id: exercise.id) {
                existing.update(from: exercise)
            } else {
                context.insert(StoredExercise(exercise))
            }
        }
        try commit()
    }

    /// All exercises, alphabetical — the order the library picker wants.
    public func exercises() throws -> [Exercise] {
        let descriptor = FetchDescriptor<StoredExercise>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map { try $0.toDomain() }
    }

    public func exercise(id: UUID) throws -> Exercise? {
        try storedExercise(id: id)?.toDomain()
    }

    private func storedExercise(id: UUID) throws -> StoredExercise? {
        var descriptor = FetchDescriptor<StoredExercise>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Sets

    public func log(_ record: SetRecord) throws {
        context.insert(StoredSetLog(record))
        try commit()
    }

    /// Removes a set. Backs the one-gesture undo in #8, where a mislogged set
    /// has to disappear completely rather than being marked void — a voided row
    /// would still have to be filtered out of every statistic downstream.
    @discardableResult
    public func deleteSet(id: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let stored = try context.fetch(descriptor).first else { return false }
        context.delete(stored)
        try commit()
        return true
    }

    /// Every set for one exercise, oldest first.
    public func sets(forExercise exerciseID: UUID) throws -> [SetRecord] {
        let descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.exerciseID == exerciseID },
            sortBy: [SortDescriptor(\.performedAt)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    /// Sets performed at or after `date`, oldest first. The shape the volume
    /// guard (#25) and the session screen both read.
    public func sets(since date: Date) throws -> [SetRecord] {
        let descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.performedAt >= date },
            sortBy: [SortDescriptor(\.performedAt)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func allSets() throws -> [SetRecord] {
        let descriptor = FetchDescriptor<StoredSetLog>(
            sortBy: [SortDescriptor(\.performedAt)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    // MARK: - Progress state

    /// Inserts or overwrites the state for this exercise. One row per exercise
    /// is enforced by the unique `exerciseID`.
    public func save(_ state: ProgressState) throws {
        if let existing = try storedState(for: state.exerciseID) {
            existing.update(from: state)
        } else {
            context.insert(StoredProgressState(state))
        }
        try commit()
    }

    /// The exercise's state, or `nil` if it has never been performed — the cold
    /// start the session screen renders as "first time, just log it".
    public func progressState(forExercise exerciseID: UUID) throws -> ProgressState? {
        try storedState(for: exerciseID)?.toDomain()
    }

    private func storedState(for exerciseID: UUID) throws -> StoredProgressState? {
        var descriptor = FetchDescriptor<StoredProgressState>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Day templates

    public func upsert(_ template: DayTemplate) throws {
        var descriptor = FetchDescriptor<StoredDayTemplate>(
            predicate: #Predicate { $0.id == template.id }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.update(from: template)
        } else {
            context.insert(StoredDayTemplate(template))
        }
        try commit()
    }

    public func dayTemplates() throws -> [DayTemplate] {
        try context.fetch(FetchDescriptor<StoredDayTemplate>())
            .map { try $0.toDomain() }
    }

    public func dayTemplate(kind: DayKind) throws -> DayTemplate? {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<StoredDayTemplate>(
            predicate: #Predicate { $0.kindRaw == raw }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map { try $0.toDomain() }
    }
}
