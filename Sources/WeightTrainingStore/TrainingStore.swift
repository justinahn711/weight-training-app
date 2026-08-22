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

    var modelContext: ModelContext { container.mainContext }
    private var context: ModelContext { container.mainContext }

    /// Whether the store was configured to mirror to iCloud.
    ///
    /// Intent, not confirmation. SwiftData accepts a CloudKit configuration
    /// without checking that the app carries the entitlement or that anyone is
    /// signed in — it fails later and quietly, at sync time. So this being true
    /// means "sync was asked for and the container was built", and answering
    /// "is my data actually reaching iCloud" needs a real device with a real
    /// account.
    ///
    /// It goes false only when building the CloudKit container throws outright,
    /// which is the case worth falling back from: a schema CloudKit refuses.
    public private(set) var isCloudKitEnabled = false

    /// Why CloudKit was declined, when it was.
    ///
    /// Kept rather than swallowed: a silent fallback to local storage is
    /// indistinguishable from working sync until someone goes looking for their
    /// data on another device.
    public private(set) var cloudKitFailure: String?

    /// - Parameters:
    ///   - url: where the store file lives. Passing `nil` uses SwiftData's
    ///     default application-support location, which is what the app ships
    ///     with; tests pass a temp URL to get an isolated file.
    ///   - syncsWithCloudKit: mirror to the app's private CloudKit database
    ///     (#19). Off for tests, which must never talk to iCloud — a test suite
    ///     that depends on a network account isn't a test suite.
    public init(url: URL? = nil, syncsWithCloudKit: Bool = false) throws {
        let schema = Schema(TrainingSchema.models)

        func configuration(cloudKit: Bool) -> ModelConfiguration {
            // `.automatic` reads the container from the app's entitlement, so
            // the identifier lives in one place rather than being duplicated
            // here where it could drift.
            let database: ModelConfiguration.CloudKitDatabase = cloudKit ? .automatic : .none
            if let url {
                return ModelConfiguration(schema: schema, url: url, cloudKitDatabase: database)
            }
            return ModelConfiguration(schema: schema, cloudKitDatabase: database)
        }

        if syncsWithCloudKit {
            do {
                self.container = try ModelContainer(
                    for: schema, configurations: configuration(cloudKit: true)
                )
                self.isCloudKitEnabled = true
                return
            } catch {
                // Fall through to a local store. Losing sync is a degraded
                // app; failing to open is a broken one — but the reason has to
                // survive, or the failure is invisible.
                self.isCloudKitEnabled = false
                self.cloudKitFailure = String(describing: error)
            }
        }

        self.container = try ModelContainer(
            for: schema, configurations: configuration(cloudKit: false)
        )
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
        try saveChanges()
    }

    func saveChanges() throws {
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

    /// Adds a lift the person invented (#76).
    ///
    /// Validated rather than trusted, because the two fields that matter are
    /// the two a form makes easy to leave empty. A nameless lift is unusable in
    /// the picker, and an untagged one is invisible to the volume report — the
    /// insight that's meant to work whatever someone trains.
    public func create(_ exercise: Exercise) throws {
        let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.invalidExercise(reason: "needs a name") }
        guard exercise.muscles.contains(where: { $0.role == .primary }) else {
            throw StoreError.invalidExercise(reason: "needs at least one primary muscle")
        }
        guard ExerciseLibrary.isSeeded(exercise.id) == false else {
            throw StoreError.invalidExercise(reason: "that id belongs to the catalogue")
        }

        var trimmed = exercise
        trimmed.name = name
        try upsert(trimmed)
    }

    /// Removes a lift someone created.
    ///
    /// Catalogue lifts are refused. They're shared, seeding would reinstate one
    /// on the next launch anyway, and "I don't do this" is a preference about a
    /// person rather than a fact about the exercise.
    ///
    /// Logged sets are left on disk. The training happened, and deleting the
    /// lift is not a claim that it didn't — though with no exercise to name
    /// them, those sets stop appearing in history and volume until the lift
    /// comes back.
    @discardableResult
    public func deleteExercise(id: UUID) throws -> Bool {
        guard !ExerciseLibrary.isSeeded(id) else { return false }
        guard let stored = try storedExercise(id: id) else { return false }
        context.delete(stored)
        try commit()
        return true
    }

    /// All exercises, alphabetical — the order the library picker wants.
    ///
    /// Uniqued by id on the way out. The schema can't enforce that any more
    /// (see `deduplicate()`), and a duplicate must never reach the UI even in
    /// the window before a dedupe pass runs.
    public func exercises() throws -> [Exercise] {
        let descriptor = FetchDescriptor<StoredExercise>(
            sortBy: [SortDescriptor(\.name)]
        )
        var seen: Set<UUID> = []
        return try context.fetch(descriptor)
            .filter { seen.insert($0.id).inserted }
            .map { try $0.toDomain() }
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

    /// Corrects a previously logged set (#61).
    ///
    /// Until this existed, `undoLastSet` was the only way to take a set back
    /// and it reached exactly one — the newest. Anything mislogged before that
    /// was permanent, which matters more here than in a tap-only app: sets are
    /// logged by voice mid-session, and a misheard "eight" as "eighty" writes a
    /// set that silently inflates volume, e1RM and every target downstream.
    ///
    /// Nothing derived is rewritten. Volume, trends and the next target are all
    /// computed from history when they're next read, so correcting the history
    /// is the whole fix. Stored progress state is deliberately left alone: it
    /// records what was actually trained against at the time, and rewriting it
    /// would revise a session you already performed.
    ///
    /// - Returns: false when no set has that id — an edit racing a delete from
    ///   another device, which is a no-op rather than an error.
    @discardableResult
    public func updateSet(_ record: SetRecord) throws -> Bool {
        let id = record.id
        var descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let stored = try context.fetch(descriptor).first else { return false }
        stored.update(from: record)
        try commit()
        return true
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
        return unique(try context.fetch(descriptor))
    }

    /// Sets performed at or after `date`, oldest first. The shape the volume
    /// guard (#25) and the session screen both read.
    public func sets(since date: Date) throws -> [SetRecord] {
        let descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.performedAt >= date },
            sortBy: [SortDescriptor(\.performedAt)]
        )
        return unique(try context.fetch(descriptor))
    }

    public func allSets() throws -> [SetRecord] {
        let descriptor = FetchDescriptor<StoredSetLog>(
            sortBy: [SortDescriptor(\.performedAt)]
        )
        return unique(try context.fetch(descriptor))
    }

    /// Drops duplicate set rows by id.
    ///
    /// A duplicated set is not a cosmetic problem: it inflates volume, e1RM,
    /// and every progression decision that reads the session.
    private func unique(_ rows: [StoredSetLog]) -> [SetRecord] {
        var seen: Set<UUID> = []
        return rows.filter { seen.insert($0.id).inserted }.map { $0.toDomain() }
    }

    // MARK: - Bodyweight

    /// Records a weigh-in (#71).
    ///
    /// One reading per day, replaced rather than accumulated: a scale stepped
    /// on three times in a morning is one measurement, and keeping all three
    /// would weight the series towards whichever day someone fidgeted.
    public func record(_ reading: BodyweightReading, calendar: Calendar = .current) throws {
        let existing = try context.fetch(FetchDescriptor<StoredBodyweight>())
            .filter { calendar.isDate($0.recordedAt, inSameDayAs: reading.recordedAt) }
        for row in existing { context.delete(row) }

        context.insert(StoredBodyweight(reading))
        try commit()
    }

    /// Every weigh-in, oldest first.
    public func bodyweights() throws -> [BodyweightReading] {
        try context.fetch(FetchDescriptor<StoredBodyweight>(
            sortBy: [SortDescriptor(\.recordedAt)]
        )).map { $0.toDomain() }
    }

    /// What the lifter weighed on a given day, as far as anything recorded
    /// knows. Nil before the first weigh-in.
    public func bodyweight(on date: Date) throws -> Double? {
        try bodyweights().weight(on: date)
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

    /// The freshest state for an exercise.
    ///
    /// Picks the most recently performed rather than simply the first, so a
    /// duplicate arriving from another device can't hand back a stale target
    /// before `deduplicate()` has merged it.
    private func storedState(for exerciseID: UUID) throws -> StoredProgressState? {
        let descriptor = FetchDescriptor<StoredProgressState>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        )
        return try context.fetch(descriptor).max {
            ($0.lastPerformedAt ?? .distantPast) < ($1.lastPerformedAt ?? .distantPast)
        }
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

    /// Every template, uniqued by id — the same guarantee `exercises()` and the
    /// set reads make.
    ///
    /// This was the one read path that could hand back duplicates, and a fresh
    /// install is where it shows: `deduplicate()` and the seeds both run at
    /// launch, before CloudKit's first import lands, so seeding inserts the
    /// library into what looks like an empty store and the import then delivers
    /// a second copy of every row. The next launch merges them, but the whole
    /// first launch runs on doubled templates.
    public func dayTemplates() throws -> [DayTemplate] {
        var seen: Set<UUID> = []
        return try context.fetch(FetchDescriptor<StoredDayTemplate>())
            .filter { seen.insert($0.id).inserted }
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
