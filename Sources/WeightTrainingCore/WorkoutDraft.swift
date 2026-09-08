import Foundation

/// The small piece of user intent that makes an interrupted workout resumable.
///
/// Logged sets remain the record of what happened. This value only records
/// which in-progress workout the lifter meant to return to, including swaps and
/// the exercise they were looking at. It is deleted when Finish is explicit.
public struct WorkoutDraft: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: DayKind
    public let startedAt: Date
    public let exerciseIDs: [UUID]
    public let currentExerciseID: UUID?
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: DayKind,
        startedAt: Date,
        exerciseIDs: [UUID],
        currentExerciseID: UUID?,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.exerciseIDs = exerciseIDs
        self.currentExerciseID = currentExerciseID
        self.updatedAt = updatedAt
    }

    public init(session: Session, id: UUID = UUID(), updatedAt: Date = Date()) {
        self.init(
            id: id,
            kind: session.kind,
            startedAt: session.startedAt,
            exerciseIDs: session.exercises.map(\.id),
            currentExerciseID: session.current?.id,
            updatedAt: updatedAt
        )
    }
}
