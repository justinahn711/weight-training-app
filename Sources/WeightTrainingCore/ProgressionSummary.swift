import Foundation

/// One completed exercise as the lifter needs to read it after Finish:
/// what happened, what to aim for next time, and the engine's own reason.
///
/// This type deliberately carries the `ProgressionResult` that was persisted.
/// A completion screen must not reverse-engineer a rationale from the updated
/// target — doing that would create a second, UI-only progression engine.
public struct ProgressionSummaryEntry: Identifiable, Hashable, Sendable {
    public var id: UUID { exercise.id }

    public let exercise: Exercise
    public let performed: LastPerformance
    public let result: ProgressionResult

    /// Returns nil when an exercise has no working sets. Warmups describe how
    /// someone got ready, not how the progression decision was earned.
    public init?(
        exercise: Exercise,
        performed sets: [SetRecord],
        result: ProgressionResult
    ) {
        let working = sets.filter { !$0.isWarmup }
        guard let performedAt = working.map(\.performedAt).max() else { return nil }

        self.exercise = exercise
        self.performed = LastPerformance(performedAt: performedAt, sets: working)
        self.result = result
    }

    public func performedLine(in unit: MassUnit) -> String {
        performed.displayLine(in: unit)
    }

    /// The target is read directly from the state returned by the engine.
    /// Successful progression from working sets always has these fields; the
    /// fallback is honest if an older or imported state is incomplete.
    public func nextTargetLine(in unit: MassUnit) -> String {
        guard let load = result.state.targetLoad,
              let reps = result.state.targetReps else {
            return "No next target yet"
        }

        let base = "\(load.formatted(in: unit)) × \(reps)"
        guard let rpe = result.state.targetRPE else { return base }
        return "\(base) @ \(rpe)"
    }

    /// Compact visible line: performed result → saved next prescription.
    public func transitionLine(in unit: MassUnit) -> String {
        "\(performedLine(in: unit)) → next \(nextTargetLine(in: unit))"
    }

    /// VoiceOver gets the row as one thought instead of four disconnected
    /// labels whose reading order changes with layout and Dynamic Type.
    public func accessibilityLabel(in unit: MassUnit) -> String {
        "\(exercise.name). Performed \(performedLine(in: unit)). "
            + "Next target \(nextTargetLine(in: unit)). \(result.summary(in: unit))."
    }
}
