import Foundation

/// One lift as it was actually performed on a day.
public struct PerformedExercise: Hashable, Sendable, Identifiable {
    public let exercise: Exercise

    /// Every set, warmups included, oldest first.
    ///
    /// Warmups are kept here and dropped everywhere else. Progression, volume
    /// and e1RM all exclude them because they aren't work — but this screen
    /// answers "what did I do", and the ramp is part of what you did.
    public let sets: [SetRecord]

    public var id: UUID { exercise.id }

    public var workingSets: [SetRecord] { sets.filter { !$0.isWarmup } }

    /// The heaviest working set, which is what anyone reading a past session is
    /// looking for first.
    public var topSet: SetRecord? {
        workingSets.max { $0.load < $1.load }
    }

    public init(exercise: Exercise, sets: [SetRecord]) {
        self.exercise = exercise
        self.sets = sets
    }
}

/// A day's training, reconstructed from what was logged.
public struct TrainingDay: Hashable, Sendable, Identifiable {
    /// Midnight on the day trained.
    public let date: Date

    /// Which day of the cycle this looks like, or nil when it matches no
    /// template — a one-off, or a session of lifts that aren't in the library.
    public let kind: DayKind?

    /// Lifts in the order they were first performed, which is the order they
    /// happened in.
    public let exercises: [PerformedExercise]

    public var id: Date { date }

    public var workingSetCount: Int {
        exercises.reduce(0) { $0 + $1.workingSets.count }
    }

    public init(date: Date, kind: DayKind?, exercises: [PerformedExercise]) {
        self.date = date
        self.kind = kind
        self.exercises = exercises
    }
}

/// Reads training back out of the sets that were logged (#63).
///
/// Reconstructed rather than stored, for the same reason `CycleEngine` infers a
/// day's kind rather than recording it: a stored session depends on the app
/// having been running and on the session having been "started" properly, and a
/// session logged across a restart would lose itself. The sets are the record.
public enum TrainingHistory {

    /// Training days, newest first.
    ///
    /// - Parameter exercises: the library, for naming what was performed. Sets
    ///   whose exercise no longer exists are dropped rather than shown as a
    ///   blank row — a deleted lift shouldn't leave a hole in last month.
    public static func days(
        history: [SetRecord],
        exercises: [Exercise],
        templates: [DayTemplate] = DayTemplateLibrary.all,
        calendar: Calendar = .current
    ) -> [TrainingDay] {
        guard !history.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        let byDay = Dictionary(grouping: history) { calendar.startOfDay(for: $0.performedAt) }

        return byDay
            .compactMap { day, sets -> TrainingDay? in
                let ordered = sets.sorted { $0.performedAt < $1.performedAt }

                // Grouped by lift, but ordered by when each lift was first
                // touched, so reading down the screen replays the session.
                var seen: [UUID] = []
                var setsByExercise: [UUID: [SetRecord]] = [:]
                for set in ordered {
                    if setsByExercise[set.exerciseID] == nil { seen.append(set.exerciseID) }
                    setsByExercise[set.exerciseID, default: []].append(set)
                }

                let performed = seen.compactMap { id -> PerformedExercise? in
                    guard let exercise = byID[id], let sets = setsByExercise[id] else { return nil }
                    return PerformedExercise(exercise: exercise, sets: sets)
                }
                guard !performed.isEmpty else { return nil }

                return TrainingDay(
                    date: day,
                    kind: CycleEngine.classify(session: ordered, templates: templates),
                    exercises: performed
                )
            }
            .sorted { $0.date > $1.date }
    }
}
