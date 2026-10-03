import Foundation
import WeightTrainingCore

/// A value snapshot for one read operation, never a cache across calls. Pair
/// indexing avoids rescanning an exercise's full history for each workout.
/// Corrected/deleted rows are therefore visible on the very next request.
struct RecommendationHistory {
    private struct SessionKey: Hashable {
        let exerciseID: UUID
        let workoutID: UUID
    }

    let sets: [SetRecord]
    let sessions: [RecordedExerciseSession]
    let setsByExercise: [UUID: [SetRecord]]
    let sessionsByExercise: [UUID: [RecordedExerciseSession]]
    private let setsBySession: [SessionKey: [SetRecord]]

    init(sets: [SetRecord], sessions: [RecordedExerciseSession]) {
        self.sets = sets
        self.sessions = sessions
        setsByExercise = Dictionary(grouping: sets, by: \.exerciseID)
        sessionsByExercise = Dictionary(grouping: sessions, by: \.exerciseID)
        var grouped: [SessionKey: [SetRecord]] = [:]
        for record in sets {
            guard let workoutID = record.workoutID else { continue }
            grouped[SessionKey(exerciseID: record.exerciseID, workoutID: workoutID), default: []].append(record)
        }
        setsBySession = grouped.mapValues { records in
            records.sorted {
                if $0.performedAt != $1.performedAt { return $0.performedAt < $1.performedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    func records(exerciseID: UUID, workoutID: UUID) -> [SetRecord] {
        setsBySession[SessionKey(exerciseID: exerciseID, workoutID: workoutID)] ?? []
    }

    func exposures(excluding workoutID: UUID? = nil) -> [ExerciseExposure] {
        sessions.filter { $0.workoutID != workoutID }.map { intent in
            let records = records(exerciseID: intent.exerciseID, workoutID: intent.workoutID)
            return ExerciseExposure(
                id: intent.workoutID, exerciseID: intent.exerciseID, plan: intent.plan,
                sets: records.map {
                    ExposureSet(record: $0, effortSource:
                        $0.effortWasReported == true && $0.acceptedPlanID == intent.plan?.id ? .reported : .unknown)
                },
                completion: intent.completedAt == nil ? .unknown : intent.completion,
                completedAt: intent.completedAt ?? max(intent.updatedAt, records.map(\.performedAt).max() ?? intent.updatedAt))
        }
    }

    /// Preserve library ordering and omit removed exercises, matching the
    /// previous per-exercise fetch API used by reports and block summaries.
    func exposures(for library: [Exercise], excluding workoutID: UUID? = nil) -> [ExerciseExposure] {
        let grouped = Dictionary(grouping: exposures(excluding: workoutID), by: \.exerciseID)
        return library.flatMap { grouped[$0.id] ?? [] }
    }
}
