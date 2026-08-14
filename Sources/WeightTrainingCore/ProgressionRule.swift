import Foundation

/// An inclusive rep range, e.g. 8–12.
public struct RepRange: Hashable, Codable, Sendable {
    public let bottom: Int
    public let top: Int

    public init(_ bottom: Int, _ top: Int) {
        precondition(bottom > 0 && top >= bottom, "invalid rep range \(bottom)-\(top)")
        self.bottom = bottom
        self.top = top
    }

    public func contains(_ reps: Int) -> Bool {
        (bottom...top).contains(reps)
    }

    /// How large a load jump the range can absorb before difficulty spikes.
    ///
    /// A wider range tolerates a coarser increment: moving from the 70s to the
    /// 75s only works if you can drop from 10 reps back to 6.
    public var span: Int { top - bottom }
}

/// How an exercise advances between sessions.
///
/// The choice is dictated by equipment, not preference. See `LoadIncrement` —
/// with 5 lb-per-hand dumbbell jumps and 10–15 lb machine stacks, load
/// progression on its own is only viable on the handful of lifts where a 5 lb
/// step is a small fraction of the working weight.
public enum ProgressionRule: Hashable, Codable, Sendable {
    /// Add reps toward the top of the range, then add one increment and reset
    /// to the bottom. The default for nearly everything.
    ///
    /// `consecutiveTopHitsRequired` guards against a single fluke session
    /// triggering a load jump that the lift can't sustain.
    case doubleProgression(range: RepRange, consecutiveTopHitsRequired: Int = 2)

    /// Hold reps fixed and steer load by how the set actually felt. Reserved
    /// for flat bench, RDL, and hack squat — the only lifts with 5 lb steps.
    case rpeTargetedLoad(reps: Int, targetRPE: RPE)

    /// The rep target to display before the set is performed.
    public var displayRepTarget: Int {
        switch self {
        case .doubleProgression(let range, _): return range.bottom
        case .rpeTargetedLoad(let reps, _):    return reps
        }
    }

    /// The RPE chip pre-selected on the session screen, so the common case
    /// stays a single tap.
    public var displayRPETarget: RPE {
        switch self {
        case .doubleProgression:              return .eight
        case .rpeTargetedLoad(_, let target): return target
        }
    }
}
