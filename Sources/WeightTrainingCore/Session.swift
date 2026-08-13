import Foundation

/// One exercise as it appears in a running session: what to do, what happened
/// last time, and what has been logged so far today.
public struct SessionExercise: Identifiable, Hashable, Sendable {
    public var id: UUID { exercise.id }
    public let exercise: Exercise
    public let prescription: Prescription
    public let lastPerformance: LastPerformance?

    /// Sets logged in *this* session, in the order performed.
    public var loggedSets: [SetRecord]

    public init(
        exercise: Exercise,
        prescription: Prescription,
        lastPerformance: LastPerformance? = nil,
        loggedSets: [SetRecord] = []
    ) {
        self.exercise = exercise
        self.prescription = prescription
        self.lastPerformance = lastPerformance
        self.loggedSets = loggedSets
    }

    public var workingSets: [SetRecord] { loggedSets.filter { !$0.isWarmup } }

    public var hasBeenStarted: Bool { !loggedSets.isEmpty }
}

/// A training day in progress.
///
/// There is deliberately no planned set count. Straight sets are open-ended —
/// you stop when the lift stops moving, not when a counter says four — so the
/// screen offers "log another" and "next exercise" rather than a progress bar
/// that turns an honest session into a form to complete.
public struct Session: Hashable, Sendable {
    public let kind: DayKind
    public let startedAt: Date
    public private(set) var exercises: [SessionExercise]

    /// Which exercise is on screen. Movement through the day is explicit —
    /// the app never advances on its own, because an accidental advance
    /// mid-exercise is far more disruptive than an extra tap.
    public private(set) var currentIndex: Int

    public init(kind: DayKind, exercises: [SessionExercise], startedAt: Date = Date()) {
        self.kind = kind
        self.exercises = exercises
        self.startedAt = startedAt
        self.currentIndex = 0
    }

    public var current: SessionExercise? {
        exercises.indices.contains(currentIndex) ? exercises[currentIndex] : nil
    }

    public var isEmpty: Bool { exercises.isEmpty }

    public var isOnLastExercise: Bool { currentIndex >= exercises.count - 1 }

    /// Every set logged today, across all exercises, in performed order.
    public var allLoggedSets: [SetRecord] {
        exercises.flatMap(\.loggedSets).sorted { $0.performedAt < $1.performedAt }
    }

    /// Exercises with at least one set logged. What "how far in am I" actually
    /// means when the set count is open-ended.
    public var startedCount: Int {
        exercises.filter(\.hasBeenStarted).count
    }

    // MARK: - Navigation

    public mutating func advance() {
        guard !isOnLastExercise else { return }
        currentIndex += 1
    }

    public mutating func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    public mutating func select(exerciseID: UUID) {
        guard let index = exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        currentIndex = index
    }

    // MARK: - Logging

    /// Records a set against the current exercise.
    public mutating func log(_ record: SetRecord) {
        guard let index = exercises.firstIndex(where: { $0.id == record.exerciseID }) else { return }
        exercises[index].loggedSets.append(record)
    }

    /// Removes the most recently logged set anywhere in the session and returns
    /// it, so the caller can undo the same set on disk.
    ///
    /// Session-wide rather than per-exercise: a mistap is often noticed just
    /// after moving on, and an undo that only reaches the current exercise
    /// would be useless exactly then. Backs #8.
    @discardableResult
    public mutating func undoLastSet() -> SetRecord? {
        let latest = exercises.indices
            .compactMap { index -> (Int, SetRecord)? in
                guard let last = exercises[index].loggedSets.last else { return nil }
                return (index, last)
            }
            .max { $0.1.performedAt < $1.1.performedAt }

        guard let (index, record) = latest else { return nil }
        exercises[index].loggedSets.removeLast()
        return record
    }
}
