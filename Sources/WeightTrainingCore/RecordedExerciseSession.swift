import Foundation

/// Historical intent and completion, without a second copy of the performed
/// sets. The store rebuilds an ExerciseExposure from these values and live logs.
public struct RecordedExerciseSession: Hashable, Codable, Sendable, Identifiable {
    public var id: String { "\(workoutID.uuidString)/\(exerciseID.uuidString)" }
    public let workoutID: UUID
    public let exerciseID: UUID
    public let startedAt: Date
    public var plan: ExercisePlan?
    public var completion: ExerciseExposure.Completion
    public var completedAt: Date?
    public var updatedAt: Date

    public init(
        workoutID: UUID, exerciseID: UUID, startedAt: Date, plan: ExercisePlan? = nil,
        completion: ExerciseExposure.Completion = .unknown,
        completedAt: Date? = nil, updatedAt: Date
    ) {
        self.workoutID = workoutID
        self.exerciseID = exerciseID
        self.startedAt = startedAt
        self.plan = plan
        self.completion = completion
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

public extension Exercise {
    var supportsPlannedProgression: Bool {
        equipment != .bodyweight && (!equipment.isPlateBuilt || loading?.isMeasured == true)
    }

    var recommendationPolicy: RecommendationPolicy {
        switch progressionRule {
        case .doubleProgression(let range, let required):
            return RecommendationPolicy(repRange: range, easyExposuresRequired: max(2, min(6, required)))
        case .rpeTargetedLoad(let reps, _):
            return RecommendationPolicy(repRange: RepRange(reps, reps))
        }
    }
}
