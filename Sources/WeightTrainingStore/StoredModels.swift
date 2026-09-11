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

    /// A created lift is missing something it can't work without (#76).
    case invalidExercise(reason: String)
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

    /// What unit the increment is really marked in (#67).
    ///
    /// The magnitude stays in pounds like every other stored weight; this is
    /// only how it gets rendered and stepped. Without it a 2.5 kg stack comes
    /// back from disk as 5.51 lb and the app starts proposing weights the pin
    /// cannot make. Rows written before #67 have no value here and default to
    /// pounds, which is what they were.
    public var incrementUnitRaw: String = MassUnit.pounds.rawValue
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

    /// The person's own rest target for this lift, in seconds (#174). Nil
    /// means no override — every row written before this landed reads that
    /// way automatically, since SwiftData hands back `nil` for a column it
    /// has never seen, and `Exercise.restTarget` treats a nil override as
    /// "keep using the heuristic", exactly what those rows have always meant.
    public var restOverrideSeconds: Double?

    public init(_ exercise: Exercise) {
        self.id = exercise.id
        self.name = exercise.name
        self.equipmentRaw = exercise.equipment.rawValue
        self.incrementPounds = exercise.increment.pounds
        self.incrementUnitRaw = exercise.increment.unit.rawValue
        self.needsWarmupRamp = exercise.needsWarmupRamp
        self.musclesData = encoded(exercise.muscles)
        self.progressionRuleData = encoded(exercise.progressionRule)
        self.loadingData = exercise.loading.map(encoded) ?? Data()
        self.restOverrideSeconds = exercise.restOverride
    }

    /// Overwrites this row in place, preserving identity so relationships and
    /// any outstanding references survive an edit.
    public func update(from exercise: Exercise) {
        name = exercise.name
        equipmentRaw = exercise.equipment.rawValue
        incrementPounds = exercise.increment.pounds
        incrementUnitRaw = exercise.increment.unit.rawValue
        needsWarmupRamp = exercise.needsWarmupRamp
        musclesData = encoded(exercise.muscles)
        progressionRuleData = encoded(exercise.progressionRule)
        loadingData = exercise.loading.map(encoded) ?? Data()
        restOverrideSeconds = exercise.restOverride
    }

    public func toDomain() throws -> Exercise {
        do {
            return Exercise(
                id: id,
                name: name,
                muscles: try decoded([MuscleInvolvement].self, from: musclesData),
                equipment: Equipment(rawValue: equipmentRaw) ?? .barbell,
                increment: LoadIncrement(
                    pounds: incrementPounds,
                    unit: MassUnit(rawValue: incrementUnitRaw) ?? .pounds
                ),
                progressionRule: try decoded(ProgressionRule.self, from: progressionRuleData),
                needsWarmupRamp: needsWarmupRamp,
                // Empty means "not plate-loaded", which is different from
                // "never stored" — rows written before #39 fall back to the
                // equipment default via Exercise's initialiser.
                loading: loadingData.isEmpty
                    ? nil
                    : try decoded(LoadingStyle.self, from: loadingData),
                restOverride: restOverrideSeconds
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

// MARK: - Bodyweight

/// One weigh-in (#71).
///
/// Stored as a series rather than a single current weight, so a set is always
/// judged against what the lifter weighed at the time. Overwriting one number
/// would rewrite the history of every bodyweight lift each time the scale moved.
@Model
public final class StoredBodyweight {
    public var id: UUID = UUID()
    public var pounds: Double = 0
    public var recordedAt: Date = Date()

    public init(_ reading: BodyweightReading) {
        self.id = UUID()
        self.pounds = reading.pounds
        self.recordedAt = reading.recordedAt
    }

    public func toDomain() -> BodyweightReading {
        BodyweightReading(pounds: pounds, recordedAt: recordedAt)
    }
}

// MARK: - Gym

/// The lifter's gym: unit, plate rack, bar (#73, #67) — and, since #136, which
/// split they're running. The split isn't a fact about the room, but it rides
/// along on the same row rather than a new one of its own; see `GymConfig`'s
/// doc comment for why.
///
/// A single row, kept at a fixed id rather than "whichever one exists", so two
/// devices that both write one before ever syncing produce the same identity
/// and collapse into one in `deduplicate()` instead of leaving the app with two
/// gyms and no way to choose. Unlike every other entity here, the duplicates
/// genuinely conflict — each device has a different opinion about the rack (or
/// now, the split) — so the merge needs `updatedAt` to break the tie, one row
/// at a time: whichever device wrote last wins the whole row, split included.
@Model
public final class StoredGymConfig {
    /// The one row. There is exactly one gym until a gym picker exists (#73),
    /// and pinning the id is what makes "exactly one" survive sync.
    public static let singletonID = UUID(uuidString: "60F1D1E9-4E7C-4E3E-9D6C-2C1B7A9E5A01")!

    public var id: UUID = StoredGymConfig.singletonID
    public var unitRaw: String = MassUnit.pounds.rawValue
    /// JSON `[Double]`, plate sizes in `unitRaw`.
    public var platesData: Data = Data()
    public var barPounds: Double = MassUnit.pounds.standardBar.pounds
    /// JSON `TrainingSplit?` (#136). Empty is a row CloudKit has materialised
    /// but this device hasn't written yet, which reads the same as an
    /// explicit `null` — both mean "nobody has picked a split here".
    public var trainingSplitData: Data = Data()
    /// Distinct training days needed for one consistent week (#65).
    /// A default keeps the CloudKit schema compatible with existing rows.
    public var weeklySessionTarget: Int = 3

    /// When this was last written, used to settle a sync conflict.
    public var updatedAt: Date = Date()

    public init(_ config: GymConfig, updatedAt: Date = Date()) {
        self.id = StoredGymConfig.singletonID
        self.unitRaw = config.unit.rawValue
        self.platesData = encoded(config.availablePlates)
        self.barPounds = config.barWeight.pounds
        self.trainingSplitData = encoded(config.trainingSplit)
        self.weeklySessionTarget = config.weeklySessionTarget
        self.updatedAt = updatedAt
    }

    public func update(from config: GymConfig, at date: Date = Date()) {
        unitRaw = config.unit.rawValue
        platesData = encoded(config.availablePlates)
        barPounds = config.barWeight.pounds
        trainingSplitData = encoded(config.trainingSplit)
        weeklySessionTarget = config.weeklySessionTarget
        updatedAt = date
    }

    public func toDomain() throws -> GymConfig {
        let unit = MassUnit(rawValue: unitRaw) ?? .pounds
        do {
            return GymConfig(
                unit: unit,
                // Empty means a row written without plates rather than a gym
                // with none, which is not a thing — fall back to the standard
                // rack for the unit rather than to an unloadable bar.
                availablePlates: platesData.isEmpty
                    ? unit.standardPlates
                    : try decoded([Double].self, from: platesData),
                barWeight: Load(barPounds),
                trainingSplit: trainingSplitData.isEmpty
                    ? nil
                    : try decoded(TrainingSplit?.self, from: trainingSplitData),
                weeklySessionTarget: weeklySessionTarget
            )
        } catch {
            throw StoreError.corruptRecord(entity: "GymConfig", id: id, underlying: error)
        }
    }
}

// MARK: - Unfinished workout

/// One workout the lifter explicitly left unfinished.
///
/// This is navigation intent, not a stored training result. Sets and every
/// statistic derived from them keep their existing source of truth. A fixed id
/// lets two offline copies reconcile to one row after CloudKit imports them;
/// the latest interaction wins.
@Model
public final class StoredWorkoutDraft {
    public static let singletonID = UUID(uuidString: "AA809B5C-2010-4DE9-A1E4-E988B40C8A64")!

    public var id: UUID = StoredWorkoutDraft.singletonID
    public var draftID: UUID = UUID()
    public var kindRaw: String = DayKind.push.rawValue
    /// JSON `[UUID]`, preserving the exact lineup and swaps in order.
    public var exerciseIDsData: Data = Data()
    public var slotsData: Data = Data()
    public var currentExerciseID: UUID?
    public var startedAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(_ draft: WorkoutDraft) {
        id = Self.singletonID
        update(from: draft)
    }

    public func update(from draft: WorkoutDraft) {
        draftID = draft.id
        kindRaw = draft.kind.rawValue
        exerciseIDsData = encoded(draft.exerciseIDs)
        slotsData = encoded(draft.slots)
        currentExerciseID = draft.currentExerciseID
        startedAt = draft.startedAt
        updatedAt = draft.updatedAt
    }

    public func toDomain() throws -> WorkoutDraft {
        do {
            return WorkoutDraft(
                id: draftID,
                kind: DayKind(rawValue: kindRaw) ?? .push,
                startedAt: startedAt,
                exerciseIDs: exerciseIDsData.isEmpty
                    ? []
                    : try decoded([UUID].self, from: exerciseIDsData),
                slots: slotsData.isEmpty ? [] : try decoded([Slot?].self, from: slotsData),
                currentExerciseID: currentExerciseID,
                updatedAt: updatedAt
            )
        } catch {
            throw StoreError.corruptRecord(entity: "WorkoutDraft", id: draftID, underlying: error)
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
        StoredBodyweight.self,
        StoredGymConfig.self,
        StoredWorkoutDraft.self,
    ]
}
