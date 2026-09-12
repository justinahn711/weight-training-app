import Foundation

/// One exercise as it appears in a running session: what to do, what happened
/// last time, and what has been logged so far today.
public struct SessionExercise: Identifiable, Hashable, Sendable {
    public var id: UUID { exercise.id }
    public let exercise: Exercise

    /// The slot this lift is filling, when the day came from a template.
    ///
    /// Carried so a swap can replace the exercise while keeping the slot (#18)
    /// — the job stays, only the lift doing it changes.
    public let slot: Slot?

    public let prescription: Prescription
    public let lastPerformance: LastPerformance?

    /// Sets logged in *this* session, in the order performed.
    public var loggedSets: [SetRecord]

    public init(
        exercise: Exercise,
        slot: Slot? = nil,
        prescription: Prescription,
        lastPerformance: LastPerformance? = nil,
        loggedSets: [SetRecord] = []
    ) {
        self.exercise = exercise
        self.slot = slot
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

    // MARK: - Pre-workout roster

    /// Reorders today's plan. Once any set exists, roster editing is no longer
    /// a planning action; the running-session swap/skip controls take over.
    public mutating func movePlannedExercises(fromOffsets: IndexSet, toOffset: Int) {
        guard allLoggedSets.isEmpty,
              fromOffsets.allSatisfy(exercises.indices.contains) else { return }
        let moving = fromOffsets.map { exercises[$0] }
        for index in fromOffsets.sorted(by: >) { exercises.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(0, toOffset - removedBeforeDestination), exercises.count)
        exercises.insert(contentsOf: moving, at: destination)
        currentIndex = 0
    }

    public mutating func removePlannedExercises(atOffsets offsets: IndexSet) {
        guard allLoggedSets.isEmpty,
              offsets.allSatisfy(exercises.indices.contains) else { return }
        for index in offsets.sorted(by: >) { exercises.remove(at: index) }
        currentIndex = 0
    }

    public mutating func appendPlannedExercise(_ exercise: SessionExercise) {
        guard allLoggedSets.isEmpty,
              !exercises.contains(where: { $0.id == exercise.id }) else { return }
        exercises.append(exercise)
        currentIndex = 0
    }

    /// Gives an edited preview its deliberate start instant without changing
    /// its exact order, choices, or slot associations.
    public func starting(at date: Date = Date()) -> Session {
        Session(kind: kind, exercises: exercises, startedAt: date)
    }

    // MARK: - Mid-session addition (#175)

    /// Where a mid-session addition lands. The roster's "add" from #137 only
    /// ever appends, because nothing is running yet to be "next" relative to;
    /// once a session is under way there are two things "add an exercise"
    /// plainly means — do it now, or do it after what's in front of me — so
    /// this is a choice rather than a single fixed slot.
    public enum ExercisePlacement: Hashable, Sendable {
        /// Right after the exercise on screen — for "the rack is free, I'll
        /// do one more" right now, without shuffling past whatever else is
        /// left in the day.
        case next
        /// After everything already in the day.
        case end
    }

    /// Adds an exercise to a session already in progress.
    ///
    /// `appendPlannedExercise` is the pre-session counterpart and refuses once
    /// any set exists, because at that point editing the roster stops being a
    /// planning action. This is the other side of that line: it exists
    /// *because* sets are already logged, and it never touches `currentIndex`,
    /// because inserting a row elsewhere in the list must not change which
    /// exercise the screen is showing — that would silently do what
    /// `select(exerciseID:)` is for.
    ///
    /// `slot` is forced to nil no matter what the caller passes in. A slot is
    /// a job the day's template assigned; a lift added because a rack freed up
    /// mid-session was never one of those jobs, so it can't carry one — the
    /// same reasoning `appendPlannedExercise` already applies before the
    /// session starts. Enforced here rather than left to callers to remember,
    /// since a slot is what lets a swap treat a lift as filling a job in the
    /// day's shape; an added extra has no job to be substituted out of.
    ///
    /// Today only: this changes `exercises`, which `WorkoutDraft` mirrors, but
    /// never touches a `DayTemplate`. Nothing about the recurring plan
    /// changes, so tomorrow's version of this day is exactly what it was
    /// before this exercise was added. #137 left the same question open for
    /// removal; this answers it the same way — "not today" rather than "not
    /// ever" is the default either direction, and applying it to the plan is a
    /// separate, explicit action this method doesn't take.
    public mutating func addExercise(_ exercise: SessionExercise, placement: ExercisePlacement) {
        guard !exercises.contains(where: { $0.id == exercise.id }) else { return }
        let unslotted = SessionExercise(
            exercise: exercise.exercise,
            slot: nil,
            prescription: exercise.prescription,
            lastPerformance: exercise.lastPerformance,
            loggedSets: exercise.loggedSets
        )
        switch placement {
        case .next:
            exercises.insert(unslotted, at: min(currentIndex + 1, exercises.count))
        case .end:
            exercises.append(unslotted)
        }
    }

    // MARK: - Logging

    /// Records a set against the current exercise.
    public mutating func log(_ record: SetRecord) {
        guard let index = exercises.firstIndex(where: { $0.id == record.exerciseID }) else { return }
        exercises[index].loggedSets.append(record)
    }

    /// Replaces one set already present in this running session.
    ///
    /// Identity locates the row; exercise identity must still agree with the
    /// exercise that owns it. A correction can change what was performed, but
    /// moving a set to another lift is a delete-and-log operation with very
    /// different consequences for progression and history.
    @discardableResult
    public mutating func correctSet(_ record: SetRecord) -> Bool {
        for exerciseIndex in exercises.indices {
            guard let setIndex = exercises[exerciseIndex].loggedSets.firstIndex(
                where: { $0.id == record.id }
            ) else { continue }
            guard exercises[exerciseIndex].id == record.exerciseID else { return false }
            exercises[exerciseIndex].loggedSets[setIndex] = record
            return true
        }
        return false
    }

    // MARK: - Swapping

    /// Replaces the exercise at `index`, keeping the slot it was filling.
    ///
    /// The slot is the job; the exercise is only who's doing it. Preserving it
    /// means a swap is a substitution within the day's shape rather than a
    /// deletion and an unrelated addition — which is what lets the rotating
    /// pair and the day's structure survive a busy rack.
    ///
    /// Sets already logged against the old exercise stay exactly where they
    /// are. They happened, and they belong to that lift.
    public mutating func replace(at index: Int, with replacement: SessionExercise) {
        guard exercises.indices.contains(index) else { return }
        // Nothing to do if it's already there, and re-inserting would discard
        // sets logged against it this session.
        guard exercises[index].id != replacement.id else { return }
        exercises[index] = replacement
    }

    /// Replaces a named lift, wherever it sits in the day.
    ///
    /// Not `replaceCurrent`, because a swap is decided in a sheet and the day
    /// can move underneath it: `SessionView` stays alive beneath the swap
    /// sheet and the mic keeps listening, so a spoken "next exercise" advances
    /// the session between choosing a replacement and picking it. Targeting
    /// the current index then swapped whichever lift had become current and
    /// left the one being looked at alone (#120).
    ///
    /// Inherits the identity guard: replacing a lift with itself is still a
    /// no-op, which is what a swap onto the same exercise should be.
    public mutating func replace(exerciseWithID id: UUID, with replacement: SessionExercise) {
        guard let index = exercises.firstIndex(where: { $0.id == id }) else { return }
        replace(at: index, with: replacement)
    }

    /// Replaces whatever is on screen now — with a *different* lift.
    ///
    /// Swap-shaped, and inherits the identity guard above: replacing a lift
    /// with itself is a no-op here on purpose. To install a rebuilt version of
    /// the same lift, use `reconfigureCurrent`.
    public mutating func replaceCurrent(with replacement: SessionExercise) {
        replace(at: currentIndex, with: replacement)
    }

    /// Installs a rebuilt version of the lift already on screen — same lift,
    /// changed configuration.
    ///
    /// The opposite intent to `replaceCurrent`, and it needs its own method
    /// rather than the same one: there the matching id means "nothing to do",
    /// here it is the whole point. Correcting a machine's increment or empty
    /// weight (#20, #39) produces a `SessionExercise` with the same id by
    /// definition, so routing it through the swap path silently discarded it —
    /// the correction reached the store and the screen kept showing the old
    /// configuration until the app was relaunched (#98).
    ///
    /// Safe with respect to the concern that motivates the guard: the caller
    /// rebuilds through `sessionExercise(for:slot:startedAt:)`, which reloads
    /// today's logged sets, so nothing logged this session is lost.
    public mutating func reconfigureCurrent(with replacement: SessionExercise) {
        guard exercises.indices.contains(currentIndex) else { return }
        exercises[currentIndex] = replacement
    }

    /// Removes the most recently logged set anywhere in the session and returns
    /// it, so the caller can undo the same set on disk.
    ///
    /// Session-wide rather than per-exercise: a mistap is often noticed just
    /// after moving on, and an undo that only reaches the current exercise
    /// would be useless exactly then. Backs #8.
    ///
    /// Removes the most recently performed set, optionally only when it is the
    /// set the caller is still offering to undo. The identity check and the
    /// mutation belong together: a contextual Undo must never remove a newer
    /// set that arrived after its banner was rendered.
    @discardableResult
    public mutating func undoLastSet(ifID expectedID: UUID? = nil) -> SetRecord? {
        let latest = exercises.indices
            .compactMap { index -> (Int, SetRecord)? in
                guard let last = exercises[index].loggedSets.last else { return nil }
                return (index, last)
            }
            .max { $0.1.performedAt < $1.1.performedAt }

        guard let (index, record) = latest,
              expectedID == nil || record.id == expectedID else { return nil }
        exercises[index].loggedSets.removeLast()
        return record
    }
}
