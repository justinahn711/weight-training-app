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
    /// - the equipment isn't plate-built (#157), which is what keeps a cable
    ///   lateral or a dumbbell curl from sprouting a warmup block
    /// - there's no working load yet, on a cold start
    /// - the working load is so light that every rung collapses onto it
    ///
    /// Eligibility used to be `Exercise.needsWarmupRamp`, a flag set by hand
    /// per lift. Only 4 of the library's 19 exercises ever had it set, so 15
    /// offered nothing — which read as "no warmup feature" rather than
    /// "no ramp for this equipment", and was the actual bug in #157: the
    /// ramp worked, nobody ever saw it. `equipment.isPlateBuilt` is the same
    /// judgement the flag was trying to encode — a bar or a plate-loaded sled
    /// takes a real sequence of loading changes to reach a working weight,
    /// where a dumbbell pair or a stack pin is one motion regardless of the
    /// number on it — except it is derived from data every exercise already
    /// carries, so it applies uniformly and is exercised by
    /// `WarmupRampTests` instead of depending on whoever adds the next lift
    /// remembering to flip a flag. `needsWarmupRamp` itself is untouched: it
    /// is stored and decoded outside this module and removing it is a
    /// separate, cross-module change.
    public static func generate(
        for exercise: Exercise,
        workingLoad: Load?,
        bar: Load = PlateMath.standardBar
    ) -> [WarmupSet] {
        guard exercise.equipment.isPlateBuilt, let working = workingLoad, working.pounds > 0 else {
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

    /// The rung nobody has logged yet, in ramp order — nil once every rung
    /// has a matching entry in `loggedWarmupLoads`, or when `ramp` is empty.
    ///
    /// This is deliberately how "where am I in the ramp" is answered instead
    /// of a stored index (#206). `generate` is regenerated fresh on every
    /// read rather than saved, so there is no persisted position for an
    /// index to describe, and nowhere for it to survive a relaunch, a swap
    /// away from the lift and back, or a session resumed from disk. Deriving
    /// the answer from what is already durable — today's logged warmup sets
    /// — needs nothing extra to restore, the same way `RestTimer.reconciled`
    /// rebuilds a running rest from a timestamp instead of a live clock.
    ///
    /// Matched by load, which is already this type's identity (`WarmupSet.
    /// id`): a warmup logged at a rung's exact weight counts as that rung
    /// done whether it arrived by tapping the rung or by logging an
    /// unplanned extra warmup at the same number, and a load elsewhere in
    /// `loggedWarmupLoads` that doesn't match any rung is simply ignored.
    public static func nextRung(in ramp: [WarmupSet], loggedWarmupLoads: Set<Load>) -> WarmupSet? {
        ramp.first { !loggedWarmupLoads.contains($0.load) }
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
