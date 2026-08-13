import Foundation

/// A muscle group tracked for weekly volume.
///
/// Every exercise carries these tags so volume-by-muscle works on day one
/// without any manual tagging. The set is deliberately coarse — finer
/// granularity than this can't be trained independently anyway.
public enum Muscle: String, Codable, CaseIterable, Sendable {
    case chest
    case frontDelts
    case sideDelts
    case rearDelts
    case lats
    case traps
    case biceps
    case triceps
    case quads
    case hamstrings
    case glutes
    case calves
    case forearms
    case abs

    /// Weekly hard-set target band used by the volume guard.
    ///
    /// Ranges are the conventional hypertrophy targets. Smaller muscles that get
    /// substantial indirect work from compounds sit at the lower end.
    public var weeklySetTarget: ClosedRange<Int> {
        switch self {
        case .chest, .lats, .quads, .hamstrings:   return 10...20
        case .frontDelts, .sideDelts, .rearDelts:  return 8...16
        case .biceps, .triceps, .glutes, .calves:  return 8...16
        case .traps:                               return 6...12
        case .forearms, .abs:                      return 4...12
        }
    }
}

/// How directly an exercise loads a muscle.
///
/// Only primary movers count as full hard sets in the volume guard; secondary
/// involvement counts as a half set. Without this split, a push day full of
/// pressing would report triceps volume that vastly overstates direct work.
public enum MuscleRole: String, Codable, Sendable {
    case primary
    case secondary

    /// Contribution of one hard set toward the weekly volume target.
    public var volumeWeight: Double {
        switch self {
        case .primary:   return 1.0
        case .secondary: return 0.5
        }
    }
}

/// A muscle tag on an exercise.
public struct MuscleInvolvement: Hashable, Codable, Sendable {
    public let muscle: Muscle
    public let role: MuscleRole

    public init(_ muscle: Muscle, _ role: MuscleRole) {
        self.muscle = muscle
        self.role = role
    }

    public static func primary(_ muscle: Muscle) -> MuscleInvolvement {
        MuscleInvolvement(muscle, .primary)
    }

    public static func secondary(_ muscle: Muscle) -> MuscleInvolvement {
        MuscleInvolvement(muscle, .secondary)
    }
}
