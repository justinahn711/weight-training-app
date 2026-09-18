import Foundation

/// One advisory working-set target. Warmups never belong in a plan.
public struct PlannedWorkingSet: Hashable, Codable, Sendable {
    public var load: Load
    public var reps: Int
    public var rpe: RPE

    public init(load: Load, reps: Int, rpe: RPE = .eight) {
        self.load = load
        self.reps = reps
        self.rpe = rpe
    }
}

/// A prescription the lifter accepted, rather than a reconstruction of what
/// they happened to finish. Reuse its ID while repeating the prescription;
/// give it a new ID when accepting a change, including after a deload.
///
/// The exercise snapshot and comparison context prevent old success on a
/// different apparatus, rest protocol, or technique from earning a load jump.
public struct ExercisePlan: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var exercise: Exercise
    public var sets: [PlannedWorkingSet]
    public var restSeconds: Int?
    public var techniqueRevision: String?
    public var isDeload: Bool

    public init(
        id: UUID = UUID(), exercise: Exercise, sets: [PlannedWorkingSet],
        restSeconds: Int? = nil, techniqueRevision: String? = nil,
        isDeload: Bool = false
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.restSeconds = restSeconds
        self.techniqueRevision = techniqueRevision
        self.isDeload = isDeload
    }
}

/// Effort must be explicitly reported before it can earn progression.
/// Legacy or prefilled RPE values are still useful history, but not proof
/// that the user said a set was easy.
public struct ExposureSet: Hashable, Codable, Sendable {
    public enum EffortSource: String, Codable, Sendable {
        case reported
        case unknown
    }

    public var record: SetRecord
    public var effortSource: EffortSource

    public init(record: SetRecord, effortSource: EffortSource = .unknown) {
        self.record = record
        self.effortSource = effortSource
    }
}

/// One exercise in one explicitly identified workout. Two workouts on one
/// day remain distinct and a workout crossing midnight remains one exposure.
/// Build these values from current logs so corrections and deletions reflow.
public struct ExerciseExposure: Identifiable, Hashable, Codable, Sendable {
    public enum Completion: String, Codable, Sendable {
        case completed
        case shortenedForTime
        case stoppedForFatigue
        case stoppedForPain
        case unknown
    }

    /// Session identity; there is at most one exposure per exercise/session.
    public let id: UUID
    public let exerciseID: UUID
    public var plan: ExercisePlan?
    /// Explicit performance order, including any warmups.
    public var sets: [ExposureSet]
    public var completion: Completion
    public var completedAt: Date
    public var techniqueChanged: Bool?

    public init(
        id: UUID, exerciseID: UUID, plan: ExercisePlan?, sets: [ExposureSet],
        completion: Completion, completedAt: Date, techniqueChanged: Bool? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.plan = plan
        self.sets = sets
        self.completion = completion
        self.completedAt = completedAt
        self.techniqueChanged = techniqueChanged
    }

    public var workingSets: [ExposureSet] { sets.filter { !$0.record.isWarmup } }
}
