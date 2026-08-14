import Foundation

/// One suggested warmup set.
///
/// A suggestion, not a record. Nothing here is logged until it's performed and
/// tapped — the ramp is a plan for the next four minutes, and plans change when
/// the rack is busy.
public struct WarmupSet: Hashable, Identifiable, Sendable {
    public let load: Load
    public let reps: Int

    /// Derived from the weight rather than generated.
    ///
    /// A ramp is regenerated on every read, so a fresh `UUID` would hand
    /// SwiftUI new identities each render — tearing down and re-inserting every
    /// row instead of updating it, and taking the expand animation and any
    /// press state with it. Rungs are unique by load within a ramp, which makes
    /// the load a stable identity.
    public var id: Double { load.pounds }

    public init(load: Load, reps: Int) {
        self.load = load
        self.reps = reps
    }
}

/// Builds the ramp up to a working weight.
///
/// Generated rather than stored: a ramp derived from today's working load is
/// always right, where a saved ramp goes stale the moment the lift progresses.
public enum WarmupRamp {

    /// Fractions of the working load, with reps falling as the weight rises.
    ///
    /// Reps drop off deliberately — the job of a warmup is to rehearse the
    /// movement and prime the nervous system, and doing eight at 80% just
    /// spends the working sets before they start.
    static let steps: [(fraction: Double, reps: Int)] = [
        (0.40, 5),
        (0.60, 4),
        (0.80, 2),
    ]

    /// The ramp for an exercise, or empty when one isn't wanted.
    ///
    /// Returns nothing at all when:
    /// - the lift isn't flagged for ramps (`needsWarmupRamp`), which is what
    ///   keeps cable laterals from sprouting a warmup block
    /// - there's no working load yet, on a cold start
    /// - the working load is so light that every rung collapses onto it
    public static func generate(
        for exercise: Exercise,
        workingLoad: Load?,
        bar: Load = PlateMath.standardBar
    ) -> [WarmupSet] {
        guard exercise.needsWarmupRamp, let working = workingLoad, working.pounds > 0 else {
            return []
        }

        var rungs: [WarmupSet] = []

        // Start with the empty apparatus, which is both the lightest buildable
        // load and the one everybody actually starts with — but only where its
        // weight is known. Inventing a "45 lb" first rung on an unmeasured
        // T-bar would be fiction.
        let base = exercise.loading?.baseWeight
        if let base, working > base {
            rungs.append(WarmupSet(load: base, reps: 5))
        }

        for step in steps {
            let raw = Load(working.pounds * step.fraction)
            let snapped = snap(raw, for: exercise, bar: bar)

            // Skip rungs that can't be built lighter than the working set, or
            // that duplicate one already on the ladder. Two identical warmup
            // sets is a UI bug, not a plan.
            guard snapped < working, snapped.pounds > 0 else { continue }
            guard !rungs.contains(where: { $0.load == snapped }) else { continue }
            rungs.append(WarmupSet(load: snapped, reps: step.reps))
        }

        return rungs.sorted { $0.load < $1.load }
    }

    /// Rounds a rung down to something the equipment can build.
    ///
    /// Down, so a warmup is never accidentally heavier than intended — the one
    /// direction of error that costs working sets.
    private static func snap(_ load: Load, for exercise: Exercise, bar: Load) -> Load {
        guard let base = exercise.loading?.baseWeight else {
            return exercise.increment.snap(load)
        }
        guard load > base else { return base }
        // Rungs move in whole increments above the empty apparatus, so the
        // result is always loadable with real plates.
        let aboveBase = exercise.increment.snap(Load(load.pounds - base.pounds))
        return Load(base.pounds + aboveBase.pounds)
    }
}
