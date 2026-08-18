import Foundation
import SwiftData
import WeightTrainingCore

/// SwiftData persistence for the domain types in `WeightTrainingCore`.
///
/// The stored classes deliberately mirror the pure value types rather than
/// replacing them. Everything the app reasons about — progression, e1RM, volume
/// — is computed on the `Core` structs, which import nothing but Foundation and
/// so stay testable without a `ModelContainer`. These classes exist only to put
/// those values on disk and hand them back.
///
/// No attribute carries a unique constraint, and every one has a default. Both
/// are requirements of SwiftData's CloudKit mirroring (#19): a synced store
/// cannot enforce uniqueness, because two offline devices can each create the
/// "same" row and neither is wrong until they meet. Uniqueness is enforced by
/// `TrainingStore` instead — `upsert` fetches before inserting, and duplicates
/// that arrive anyway are merged by `deduplicate()`.
///
/// Fields that get queried or sorted (`exerciseID`, `performedAt`, `isWarmup`)
/// are stored as columns. Compound values with no query use — muscle tags, the
/// progression rule, a template's slots — are stored as encoded JSON, which
/// sidesteps SwiftData's uneven handling of enums with associated values and
/// keeps the schema flat enough to migrate by hand later.

// MARK: - JSON helpers

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

private func encoded<T: Encodable>(_ value: T) -> Data {
    // Domain types are plain Codable values with no failable paths, so an error
    // here is a programmer error rather than a runtime condition worth
    // propagating through every call site.
    do { return try jsonEncoder.encode(value) }
    catch { preconditionFailure("failed to encode \(T.self): \(error)") }
}

private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try jsonDecoder.decode(type, from: data)
}

/// Thrown when a row on disk can't be turned back into a domain value.
public enum StoreError: Error {
    /// A stored blob failed to decode — a schema change landed without a
    /// migration, or the file was written by a newer build.
    case corruptRecord(entity: String, id: UUID, underlying: Error)
}

/// Rebuilds an RPE from a stored double.
///
/// Snapping on the way out rather than force-unwrapping means a value written
/// by an older build with a different chip grid degrades to the nearest legal
/// chip instead of trapping mid-session.
private func rpe(fromStored value: Double?) -> RPE? {
    guard let value else { return nil }
    return RPE(value) ?? RPE(snapping: value)
}

// MARK: - Exercise

@Model
public final class StoredExercise {
    public var id: UUID = UUID()
    public var name: String = ""
    public var equipmentRaw: String = Equipment.barbell.rawValue
    public var incrementPounds: Double = LoadIncrement.barbell.pounds
    public var needsWarmupRamp: Bool = false

    /// JSON `[MuscleInvolvement]`.
    public var musclesData: Data = Data()
    /// JSON `ProgressionRule`.
    public var progressionRuleData: Data = Data()
    /// JSON `LoadingStyle`, empty when the exercise isn't plate-loaded.
    ///
    /// Persisted rather than re-derived from equipment, because the whole point
    /// of the config (#39) is that a measured base weight survives — a T-bar
    /// weighed once should not go back to "unknown" on the next launch.
    public var loadingData: Data = Data()

    public init(_ exercise: Exercise) {
        self.id = exercise.id
        self.name = exercise.name
        self.equipmentRaw = exercise.equipment.rawValue
        self.incrementPounds = exercise.increment.pounds
        self.needsWarmupRamp = exercise.needsWarmupRamp
        self.musclesData = encoded(exercise.muscles)
        self.progressionRuleData = encoded(exercise.progressionRule)
        self.loadingData = exercise.loading.map(encoded) ?? Data()
    }

    /// Overwrites this row in place, preserving identity so relationships and
    /// any outstanding references survive an edit.
    public func update(from exercise: Exercise) {
        name = exercise.name
        equipmentRaw = exercise.equipment.rawValue
        incrementPounds = exercise.increment.pounds
        needsWarmupRamp = exercise.needsWarmupRamp
        musclesData = encoded(exercise.muscles)
        progressionRuleData = encoded(exercise.progressionRule)
        loadingData = exercise.loading.map(encoded) ?? Data()
    }

    public func toDomain() throws -> Exercise {
        do {
            return Exercise(
                id: id,
                name: name,
                muscles: try decoded([MuscleInvolvement].self, from: musclesData),
                equipment: Equipment(rawValue: equipmentRaw) ?? .barbell,
                increment: LoadIncrement(pounds: incrementPounds),
                progressionRule: try decoded(ProgressionRule.self, from: progressionRuleData),
                needsWarmupRamp: needsWarmupRamp,
                // Empty means "not plate-loaded", which is different from
                // "never stored" — rows written before #39 fall back to the
                // equipment default via Exercise's initialiser.
                loading: loadingData.isEmpty
                    ? nil
                    : try decoded(LoadingStyle.self, from: loadingData)
            )
        } catch {
            throw StoreError.corruptRecord(entity: "Exercise", id: id, underlying: error)
        }
    }
}

// MARK: - Set log

/// One performed set. Named `SetLog` to match issue #1; the domain value it
/// carries is `SetRecord`.
@Model
public final class StoredSetLog {
    public var id: UUID = UUID()
    public var exerciseID: UUID = UUID()
    public var pounds: Double = 0
    public var reps: Int = 0
    public var rpeValue: Double?
    public var isWarmup: Bool = false
    public var performedAt: Date = Date()

    public init(_ record: SetRecord) {
        self.id = record.id
        self.exerciseID = record.exerciseID
        self.pounds = record.load.pounds
        self.reps = record.reps
        self.rpeValue = record.rpe?.value
        self.isWarmup = record.isWarmup
        self.performedAt = record.performedAt
    }

    /// Corrects a logged set in place (#61).
    ///
    /// Identity and the moment performed are deliberately not touched: a
    /// correction fixes what was recorded about a set, and changing when it
    /// happened would move it to another day rather than correct it. The lift
    /// is fixed for the same reason — a set on the wrong exercise is a
    /// different set, and deleting it is the honest fix.
    public func update(from record: SetRecord) {
        pounds = record.load.pounds
        reps = record.reps
        rpeValue = record.rpe?.value
        isWarmup = record.isWarmup
    }

    public func toDomain() -> SetRecord {
        SetRecord(
            id: id,
            exerciseID: exerciseID,
            load: Load(pounds),
            reps: reps,
            rpe: rpe(fromStored: rpeValue),
            isWarmup: isWarmup,
            performedAt: performedAt
        )
    }
}

// MARK: - Progress state

@Model
public final class StoredProgressState {
    /// One row per exercise, which is what makes this the per-exercise brain
    /// rather than a per-session snapshot.
    public var exerciseID: UUID = UUID()
    public var targetPounds: Double?
    public var targetReps: Int?
    public var targetRPEValue: Double?
    public var stallCount: Int = 0
    public var consecutiveTopHits: Int = 0
    public var lastE1RMPounds: Double?
    public var lastPerformedAt: Date?

    public init(_ state: ProgressState) {
        self.exerciseID = state.exerciseID
        self.targetPounds = state.targetLoad?.pounds
        self.targetReps = state.targetReps
        self.targetRPEValue = state.targetRPE?.value
        self.stallCount = state.stallCount
        self.consecutiveTopHits = state.consecutiveTopHits
        self.lastE1RMPounds = state.lastE1RM?.pounds
        self.lastPerformedAt = state.lastPerformedAt
    }

    public func update(from state: ProgressState) {
        targetPounds = state.targetLoad?.pounds
        targetReps = state.targetReps
        targetRPEValue = state.targetRPE?.value
        stallCount = state.stallCount
        consecutiveTopHits = state.consecutiveTopHits
        lastE1RMPounds = state.lastE1RM?.pounds
        lastPerformedAt = state.lastPerformedAt
    }

    public func toDomain() -> ProgressState {
        ProgressState(
            exerciseID: exerciseID,
            targetLoad: targetPounds.map { Load($0) },
            targetReps: targetReps,
            targetRPE: rpe(fromStored: targetRPEValue),
            stallCount: stallCount,
            consecutiveTopHits: consecutiveTopHits,
            lastE1RM: lastE1RMPounds.map { Load($0) },
            lastPerformedAt: lastPerformedAt
        )
    }
}

// MARK: - Day template

@Model
public final class StoredDayTemplate {
    public var id: UUID = UUID()
    public var kindRaw: String = DayKind.push.rawValue
    /// JSON `[Slot]`. Slots are only ever read as a whole day, never queried
    /// individually, so they don't earn their own entity.
    ///
    /// The default is not decoration: CloudKit refuses a schema containing any
    /// non-optional attribute without one, and refuses it wholesale — this one
    /// property missing a default is enough to make the entire store fall back
    /// to local-only, silently.
    public var slotsData: Data = Data()

    public init(_ template: DayTemplate) {
        self.id = template.id
        self.kindRaw = template.kind.rawValue
        self.slotsData = encoded(template.slots)
    }

    public func update(from template: DayTemplate) {
        kindRaw = template.kind.rawValue
        slotsData = encoded(template.slots)
    }

    public func toDomain() throws -> DayTemplate {
        do {
            return DayTemplate(
                id: id,
                kind: DayKind(rawValue: kindRaw) ?? .push,
                // Empty means the row is still at its default — a template
                // CloudKit has materialised but not yet filled in. Reading that
                // as a dayless day is degraded; throwing would take the whole
                // launch down, since `openStore()` turns any error here into a
                // startup failure.
                slots: slotsData.isEmpty ? [] : try decoded([Slot].self, from: slotsData)
            )
        } catch {
            throw StoreError.corruptRecord(entity: "DayTemplate", id: id, underlying: error)
        }
    }
}

/// Every entity the app persists. Kept in one place so the container and any
/// future migration plan can't drift apart.
public enum TrainingSchema {
    public static let models: [any PersistentModel.Type] = [
        StoredExercise.self,
        StoredSetLog.self,
        StoredProgressState.self,
        StoredDayTemplate.self,
    ]
}
