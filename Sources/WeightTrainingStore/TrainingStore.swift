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

    /// Saves, or discards everything staged when the save throws (#304).
    ///
    /// SwiftData does not roll back a failed save on its own. Every write
    /// stages its change and saves straight away, so whatever is pending here
    /// belongs to the write that just failed — and left pending, the next
    /// unrelated save commits it: a retried `log` lands twice, a delete the
    /// lifter was told failed happens anyway.
    func saveChanges() throws {
        guard context.hasChanges else { return }
        do {
            if let saveFault {
                self.saveFault = nil
                throw saveFault
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Test-only: the next save throws this instead of reaching SwiftData,
    /// then clears itself (#304). Internal, so only `@testable` tests can set
    /// it. A real failing save — a full disk, a store CloudKit refuses — can't
    /// be produced on demand in a unit test, and the bug is in what happens
    /// *after* the throw, which this reproduces exactly.
    var saveFault: Error?

    // MARK: - Exercises

    /// Inserts the exercise, or overwrites the existing row with the same id.
    ///
    /// Stamped as the lifter's write, which is what lets it win over a stock
    /// copy of the same lift that another device seeded (#268).
    public func upsert(_ exercise: Exercise) throws {
        try upsert([exercise])
    }

    public func upsert(_ exercises: [Exercise]) throws {
        let gym = (try? gymConfig()) ?? .standard
        let marked = try exercises.map { try markingBase(of: $0, in: gym) }
        try upsert(marked, stampedAt: EditStamp.at(Date()))
    }

    /// Settles whether a lifter-written empty weight is the gym's bar or a
    /// measurement (#270).
    ///
    /// The lift sheet builds a fresh `LoadingStyle` on every Save with no
    /// opinion on `followsGymBar`, and a caller editing a lift it read back
    /// carries the old mark along with a new number — so the mark a write
    /// arrives with is not evidence of anything. The store decides from what
    /// changed instead:
    ///
    /// - An untouched base keeps the mark it had. A Save that only changed
    ///   the rest timer must not detach the bar from the gym.
    /// - A newly typed base is a measurement, unless it is exactly the gym's
    ///   own bar. That exception is how a lift goes back to following,
    ///   including one an older build stranded on a bar the gym no longer has.
    /// - A lift with a rack of its own isn't re-racked at all, so its new base
    ///   is left unmarked; should it rejoin the gym, `applied` infers one then.
    private func markingBase(of exercise: Exercise, in gym: GymConfig) throws -> Exercise {
        guard var loading = exercise.loading, let base = loading.baseWeight else { return exercise }
        guard let stored = (try storedExercise(id: exercise.id)).flatMap({ try? $0.toDomain() })?.loading
        else { return exercise }

        if stored.baseWeight == base {
            loading.followsGymBar = loading.followsGymBar ?? stored.followsGymBar
        } else {
            loading.followsGymBar = loading.usesGymRack ? base == gym.barWeight : nil
        }
        var marked = exercise
        marked.loading = loading
        return marked
    }

    /// - Parameter stamp: what `deduplicate()` will read about who wrote these
    ///   rows — see `EditStamp`.
    func upsert(_ exercises: [Exercise], stampedAt stamp: Date) throws {
        for exercise in exercises {
            if let existing = try storedExercise(id: exercise.id) {
                existing.update(from: exercise)
                existing.updatedAt = stamp
            } else {
                context.insert(StoredExercise(exercise, updatedAt: stamp))
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

        // A lift created here belongs to the gym it was created in. `Exercise`
        // defaults to the pound world because its initialiser cannot know
        // better, and the store is the one place that does (#67, #73). Only on
        // create: an edit carries a deliberate configuration, and re-racking
        // that would undo the correction being saved.
        let gym = try gymConfig()
        trimmed.increment = gym.applied(to: trimmed.increment, for: trimmed.equipment)
        trimmed.loading = trimmed.loading.map { gym.applied(to: $0) }

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
        return try survivors(
            try context.fetch(descriptor), key: \.id, winner: DuplicateSurvivor.exercise
        ).map { try $0.toDomain() }
    }

    public func exercise(id: UUID) throws -> Exercise? {
        try storedExercise(id: id)?.toDomain()
    }

    /// The copy `deduplicate()` would keep, so an edit lands on the row that
    /// survives rather than on one about to be deleted (#268).
    func storedExercise(id: UUID) throws -> StoredExercise? {
        let descriptor = FetchDescriptor<StoredExercise>(
            predicate: #Predicate { $0.id == id }
        )
        return DuplicateSurvivor.exercise(try context.fetch(descriptor))
    }

    // MARK: - Sets

    public func log(_ record: SetRecord) throws {
        context.insert(StoredSetLog(record))
        try commit()
    }

    /// Persists a set once for a caller-supplied identity.
    ///
    /// Live Activity buttons can be delivered more than once when someone
    /// taps through a slow lock-screen refresh. The action uses its stable id
    /// as the set id, so replaying that action is a successful no-op instead
    /// of silently adding volume twice.
    @discardableResult
    public func logIfAbsent(_ record: SetRecord) throws -> Bool {
        let id = record.id
        var descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return false }
        context.insert(StoredSetLog(record))
        try commit()
        return true
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
        // A correction outranks the set as first logged when two copies meet
        // in `deduplicate()` (#268).
        stored.updatedAt = EditStamp.at(Date())
        try commit()
        return true
    }

    /// Corrects a set on disk and in a running session as one coordinated
    /// operation (#130).
    ///
    /// Both sides are checked before the write. That prevents a stale sheet
    /// from updating history while leaving the workout row unchanged, or from
    /// changing an in-memory row whose persisted copy disappeared through
    /// sync. Once the store commit succeeds the Core replacement cannot fail,
    /// because the preflight established the same identity and owner.
    @discardableResult
    public func updateSet(_ record: SetRecord, in session: inout Session) throws -> Bool {
        var preview = session
        guard preview.correctSet(record) else { return false }

        let id = record.id
        var descriptor = FetchDescriptor<StoredSetLog>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let stored = try context.fetch(descriptor).first else { return false }
        stored.update(from: record)
        // A correction outranks the set as first logged when two copies meet
        // in `deduplicate()` (#268).
        stored.updatedAt = EditStamp.at(Date())
        try commit()
        session = preview
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

    /// Removes many sets — a bad import, a duplicate workout, a whole
    /// accidental day — as one persistence operation (#168).
    ///
    /// Deleting one row at a time from `DayDetailView`'s selection would mean N
    /// separate saves, and a crash or a killed app partway through leaves a day
    /// with some sets gone and others not — a day the lifter opened precisely
    /// to make legible, now less legible than before. Every stage here (the
    /// deletes, and the progress-state correction below) is staged on the
    /// context and lands in the single `commit()` at the end, so either the
    /// whole selection disappears or none of it does.
    ///
    /// Ids that don't match anything on disk are skipped rather than failing
    /// the batch — the same idempotence `logIfAbsent` gives the write side, and
    /// what's needed for this to be safe to retry if a caller can't tell
    /// whether an earlier attempt actually reached the server before a sync
    /// merge deduplicated the row out from under it.
    ///
    /// - Returns: the ids actually found and removed.
    @discardableResult
    public func deleteSets(ids: Set<UUID>) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }

        let historyBeforeDelete = try allSets()
        let matched = historyBeforeDelete.filter { ids.contains($0.id) }
        guard !matched.isEmpty else { return [] }

        let removedIDs = Set(matched.map(\.id))
        let affectedExerciseIDs = Set(matched.map(\.exerciseID))

        for id in removedIDs {
            var descriptor = FetchDescriptor<StoredSetLog>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let stored = try context.fetch(descriptor).first {
                context.delete(stored)
            }
        }

        // What progression sees changes with the history it reads from — a
        // load jump or a stall count earned by sets that no longer exist
        // can't just be left standing. But only state the replay itself would
        // have produced is the replay's to rewrite (#269); see
        // `stageProgressStateCorrection`. Computed from the in-memory history
        // rather than a fresh fetch: the deletes above are only staged, not
        // yet saved, so re-fetching here isn't guaranteed to reflect them.
        let exercisesByID = Dictionary(uniqueKeysWithValues: try exercises().map { ($0.id, $0) })
        for exerciseID in affectedExerciseIDs {
            guard let exercise = exercisesByID[exerciseID] else {
                // The lift itself is gone too (`deleteExercise`); its progress
                // row is already meaningless and reaches no screen.
                continue
            }
            try stageProgressStateCorrection(
                exercise: exercise, historyBeforeDelete: historyBeforeDelete, removedIDs: removedIDs
            )
        }

        try commit()
        return removedIDs
    }

    /// Undoes the progression step a batch delete took the ground out from
    /// under — and nothing else. Stages the change without saving; the caller
    /// commits once for the whole batch (#168).
    ///
    /// `ProgressState` is a cumulative snapshot advanced once per session by
    /// `applyProgression`, never a live read of history the way the digest and
    /// e1RM trends are. Deleting the session that earned a load jump or ran up
    /// a stall would otherwise leave that jump standing on nothing (#168).
    ///
    /// The first version replayed the lift's whole remaining history from a
    /// cold start and overwrote whatever was stored (#269). That is only
    /// honest if the stored state *is* such a replay, and it often isn't: a
    /// deload tapped in the digest, a session finished under an older rule or
    /// increment, a same-day re-entry the live path's guard skipped. Deleting
    /// one warmup from an old day put a 165 lb deload back to 180. So the
    /// state is rewritten only when all of these hold, and left exactly as it
    /// was otherwise:
    ///
    /// 1. **A working set was deleted.** Warmups never drive progression.
    /// 2. **It belongs to the lift's latest session.** That session produced
    ///    the stored target; older ones are already superseded by it.
    /// 3. **The stored state is what replaying the pre-delete history
    ///    produces** (ignoring `lastPerformedAt`, which the live path stamps
    ///    with the session start). A match means nothing but that history
    ///    authored the state, so replaying without the deleted sets removes
    ///    exactly their contribution. A mismatch means something the replay
    ///    can't reconstruct — a deload above all — is in there, and the
    ///    lifter's decision outranks the recompute. Suggest, never change.
    ///
    /// The one exception is a delete that leaves no working sets at all: the
    /// lift is back to never performed, and a target with no history under it
    /// is the thing #168 set out to prevent, so the row is removed.
    private func stageProgressStateCorrection(
        exercise: Exercise, historyBeforeDelete: [SetRecord], removedIDs: Set<UUID>
    ) throws {
        let ownHistory = historyBeforeDelete.filter { $0.exerciseID == exercise.id }

        // 1. Warmups only: nothing progression ever read has changed.
        guard ownHistory.contains(where: { removedIDs.contains($0.id) && !$0.isWarmup }) else { return }

        let sessionsBefore = ownHistory.groupedIntoSessions()
        let sessionsAfter = ownHistory.filter { !removedIDs.contains($0.id) }.groupedIntoSessions()

        guard !sessionsAfter.isEmpty else {
            // No working sets left at all: back to the cold start the session
            // screen shows for a lift that's never been performed.
            if let existing = try storedState(for: exercise.id) {
                context.delete(existing)
            }
            return
        }

        // 2. Only the latest session's step is undoable; earlier days are
        //    already superseded by it.
        guard let latest = sessionsBefore.last,
              latest.contains(where: { removedIDs.contains($0.id) }) else { return }

        // 3. Only state the replay itself would have produced is the replay's
        //    to rewrite.
        guard let existing = try storedState(for: exercise.id) else { return }
        let stored = existing.toDomain()
        guard Self.sameProgression(stored, Self.replay(sessionsBefore, exercise: exercise)) else { return }

        var corrected = Self.replay(sessionsAfter, exercise: exercise)
        // A partial delete from the latest day leaves that day the latest, so
        // keep the stamp the live path wrote for it (the session start). A
        // whole day removed leaves only set times to go on; the day is what
        // `applyProgression`'s same-day guard reads, and that is right.
        if let storedDate = stored.lastPerformedAt,
           let replayedDate = corrected.lastPerformedAt,
           Calendar.current.isDate(storedDate, inSameDayAs: replayedDate) {
            corrected.lastPerformedAt = storedDate
        }
        existing.update(from: corrected)
    }

    /// The state a lift's working sessions produce from a cold start, each
    /// advanced once, in order — the same rule `ProgressionEngine` applies
    /// going forward.
    private static func replay(_ sessions: [[SetRecord]], exercise: Exercise) -> ProgressState {
        var state = ProgressState(exerciseID: exercise.id)
        for session in sessions {
            // `groupedIntoSessions` already drops warmups, so every set here
            // is working.
            let performedAt = session.map(\.performedAt).max() ?? state.lastPerformedAt ?? Date()
            state = ProgressionEngine.advance(
                exercise: exercise, state: state, performed: session, now: performedAt
            ).state
        }
        return state
    }

    /// Equal in everything progression decides. `lastPerformedAt` is left
    /// out: the live path stamps the session start, a replay can only see set
    /// times, and neither changes a target.
    private static func sameProgression(_ lhs: ProgressState, _ rhs: ProgressState) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.lastPerformedAt = nil
        rhs.lastPerformedAt = nil
        return lhs == rhs
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
        survivors(rows, key: \.id, winner: DuplicateSurvivor.set).map { $0.toDomain() }
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
        try upsert(template, stampedAt: EditStamp.at(Date()))
    }

    /// - Parameter stamp: see `EditStamp`; seeding passes `EditStamp.stock`.
    func upsert(_ template: DayTemplate, stampedAt stamp: Date) throws {
        let descriptor = FetchDescriptor<StoredDayTemplate>(
            predicate: #Predicate { $0.id == template.id }
        )
        if let existing = DuplicateSurvivor.template(try context.fetch(descriptor)) {
            existing.update(from: template)
            existing.updatedAt = stamp
        } else {
            context.insert(StoredDayTemplate(template, updatedAt: stamp))
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
        try survivors(
            try context.fetch(FetchDescriptor<StoredDayTemplate>()),
            key: \.id, winner: DuplicateSurvivor.template
        ).map { try $0.toDomain() }
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
