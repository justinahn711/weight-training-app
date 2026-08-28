import Foundation
@testable import WeightTrainingCore

/// Bodies, as response patterns.
///
/// Each one is a way a real training block goes wrong or right. They take the
/// prescribed load and reps because the interesting behaviour is conditional
/// on what the engine arrived at — a lifter who fails "above 65 lb" can only
/// be described this way.
public extension Lifter {

    /// Three straight sets, exactly what was asked, at the effort given.
    ///
    /// The best case, and the one that proves the ladder works end to end:
    /// reps climb through the range, the top gets banked twice, the load goes
    /// up, reps reset. Anything that stops this progressing is a bug.
    static func consistent(at rpe: Double = 8, sets: Int = 3) -> Lifter {
        Lifter("consistent at RPE \(rpe)") { _, _, reps, _ in
            Array(repeating: Attempt(reps, rpe), count: sets)
        }
    }

    /// Hits everything up to a ceiling, then falls short of the range.
    ///
    /// The ordinary plateau: the lift keeps being asked for a weight the body
    /// can't yet make, twice, which is what a deload exists to answer.
    static func stallsAbove(_ ceiling: Load, sets: Int = 3) -> Lifter {
        Lifter("stalls above \(ceiling)") { _, load, reps, exercise in
            guard load > ceiling else {
                return Array(repeating: Attempt(reps, 8), count: sets)
            }
            let missed = max(1, repRange(exercise).bottom - 2)
            return Array(repeating: Attempt(missed, 9.5), count: sets)
        }
    }

    /// Same weight, same reps, costing more every session.
    ///
    /// The signal that fires weeks before a rep is actually missed, and the
    /// whole reason RPE is captured on every working set. Nothing about the
    /// reps looks wrong here — only the price does.
    static func creeping(from start: Double = 7, sets: Int = 3) -> Lifter {
        Lifter("effort creeping from RPE \(start)") { session, _, reps, _ in
            let rpe = min(10, start + 0.5 * Double(session))
            return Array(repeating: Attempt(reps, rpe), count: sets)
        }
    }

    /// Clears the range every time, but always at a grinding effort.
    ///
    /// A lifter who is technically hitting their numbers and shouldn't be
    /// given more weight for it. The engine is supposed to hold rather than
    /// bank the hit.
    static func grinding(sets: Int = 3) -> Lifter {
        Lifter("grinding at the top") { _, _, _, exercise in
            Array(repeating: Attempt(repRange(exercise).top, 9.5), count: sets)
        }
    }

    /// Reports the same sub-target effort every session — the input the
    /// RPE-targeted rule is built to steer on.
    static func reportsEffort(_ rpe: Double, sets: Int = 3) -> Lifter {
        Lifter("always reports RPE \(rpe)") { _, _, reps, _ in
            Array(repeating: Attempt(reps, rpe), count: sets)
        }
    }

    private static func repRange(_ exercise: Exercise) -> RepRange {
        if case .doubleProgression(let range, _) = exercise.progressionRule { return range }
        // The RPE rule holds reps fixed, so treat the prescribed number as both
        // ends of the range.
        let reps = exercise.progressionRule.displayRepTarget
        return RepRange(reps, reps)
    }
}
