import Foundation

/// What the load is attached to. Determines the default increment, and whether
/// a warmup ramp makes sense.
public enum Equipment: String, Codable, CaseIterable, Sendable {
    case barbell
    case dumbbell
    case machineStack
    case plateLoaded
    case cable
    case bodyweight

    public var defaultIncrement: LoadIncrement {
        switch self {
        case .barbell:      return .barbell
        case .plateLoaded:  return .plateLoaded
        case .dumbbell:     return .dumbbell
        case .machineStack: return .stackDefault
        case .cable:        return .stackDefault
        case .bodyweight:   return LoadIncrement(pounds: 2.5)
        }
    }

    /// Whether loads are built from plates on a bar, which is what makes a
    /// plate breakdown meaningful and a warmup ramp worth generating.
    public var isPlateBuilt: Bool {
        self == .barbell || self == .plateLoaded
    }
}

/// A movement, together with everything needed to prescribe and score it.
///
/// This is a value type describing the exercise as configured. The mutable
/// per-exercise training state lives separately in `ProgressState`, so that
/// resetting progress never risks disturbing the definition.
public struct Exercise: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var muscles: [MuscleInvolvement]
    public var equipment: Equipment

    /// Defaults from `equipment`, but overridable — machine stacks vary per gym
    /// and get corrected in-app once measured (issue #20).
    public var increment: LoadIncrement

    public var progressionRule: ProgressionRule

    /// Warmup ramps are worth generating for heavy plate-built compounds and
    /// pure noise for cable laterals, so this is opt-in per exercise.
    public var needsWarmupRamp: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        muscles: [MuscleInvolvement],
        equipment: Equipment,
        increment: LoadIncrement? = nil,
        progressionRule: ProgressionRule,
        needsWarmupRamp: Bool = false
    ) {
        self.id = id
        self.name = name
        self.muscles = muscles
        self.equipment = equipment
        self.increment = increment ?? equipment.defaultIncrement
        self.progressionRule = progressionRule
        self.needsWarmupRamp = needsWarmupRamp
    }

    public var primaryMuscles: [Muscle] {
        muscles.filter { $0.role == .primary }.map(\.muscle)
    }

    /// Volume credit one hard set of this exercise gives a muscle.
    public func volumeContribution(to muscle: Muscle) -> Double {
        muscles.first { $0.muscle == muscle }?.role.volumeWeight ?? 0
    }
}
