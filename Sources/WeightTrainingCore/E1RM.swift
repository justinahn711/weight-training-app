import Foundation

extension SetRecord {

    /// Estimated one-rep max, adjusted for how much was left in the tank.
    ///
    /// Plain Epley reads only what happened: 185 × 5 is 216 regardless of
    /// whether it was a grind or a warm-up-feeling triple-plus-two. Feeding
    /// reps-in-reserve back in fixes that — 185 × 5 at RPE 6.5 has 3.5 reps
    /// left, so it's really an 8.5-rep effort and implies about 237.
    ///
    /// Without the adjustment a genuine PR logs as a flat week, which is the
    /// one thing a training log must never do.
    ///
    /// Nil on warmups, which are never scored.
    public var e1RM: Load? {
        guard !isWarmup else { return nil }
        return Load(load.pounds * (1 + effectiveReps / 30))
    }

    /// Reps performed plus reps left in reserve.
    ///
    /// A set logged without an RPE contributes no reserve at all. That
    /// understates the set, and understating is the right direction to be
    /// wrong: inventing a plausible RPE would inflate e1RM with a number
    /// nobody reported, and inflation here shows up later as a phantom PR.
    public var effectiveReps: Double {
        Double(reps) + (rpe?.repsInReserve ?? 0)
    }
}

extension Collection where Element == SetRecord {

    /// The best estimated max in the collection, ignoring warmups.
    ///
    /// The top of a session rather than the last set, since a back-off set says
    /// nothing about the ceiling reached that day.
    public var bestE1RM: Load? {
        compactMap(\.e1RM).max()
    }
}
