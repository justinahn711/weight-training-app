import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {

    /// Assembles a session for one day of the cycle: the day's exercises, each
    /// with its stored target and its previous performance.
    ///
    /// Reads the *stored* exercise rather than the library definition, so a
    /// corrected machine-stack increment (#20) or a rename is what shows up at
    /// the rack. The library is consulted only for which lifts make up the day,
    /// which day templates take over in #16.
    /// Anything already logged on `startedAt`'s calendar day is treated as part
    /// of this session rather than as history. Without that, force-quitting
    /// mid-day — or just coming back after the phone locked — would show an
    /// empty set list while the sets sat safely on disk, and the same work
    /// would get logged twice.
    public func startSession(
        kind: DayKind,
        startedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Session {
        let stored = try exercises()
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })

        let sessionExercises = try ExerciseLibrary.exercises(for: kind).compactMap { libraryLift -> SessionExercise? in
            // Skip anything not on disk rather than falling back to the library
            // definition: a lift the user deliberately removed shouldn't
            // reappear just because the day names it.
            guard let exercise = byID[libraryLift.id] else { return nil }

            let state = try progressState(forExercise: exercise.id)
            let history = try sets(forExercise: exercise.id)
            let today = history.filter { calendar.isDate($0.performedAt, inSameDayAs: startedAt) }
            let earlier = history.filter { !calendar.isDate($0.performedAt, inSameDayAs: startedAt) }

            return SessionExercise(
                exercise: exercise,
                prescription: Prescription(exercise: exercise, state: state),
                // "Last time" means the previous session, so today's own sets
                // are excluded from it.
                lastPerformance: LastPerformance.mostRecent(in: earlier),
                loggedSets: today
            )
        }

        return Session(kind: kind, exercises: sessionExercises, startedAt: startedAt)
    }
}
