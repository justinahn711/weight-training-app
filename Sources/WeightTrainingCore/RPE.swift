import Foundation

/// Rate of perceived exertion, 6.0–10.0 in half-point steps.
///
/// Captured on every working set at a cost of one tap. It powers two things
/// nothing else can provide: an honest e1RM (a set taken to RPE 6.5 implies far
/// more strength than the raw reps suggest) and RPE-creep stall detection,
/// which fires weeks before an actual missed rep.
public struct RPE: Hashable, Codable, Comparable, Sendable {
    /// Valid values, and exactly the chips shown on the session screen.
    public static let allowedValues: [Double] = [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10]

    public let value: Double

    /// Fails rather than clamping — an out-of-range RPE means a parsing or UI
    /// bug, and silently coercing it would corrupt e1RM downstream.
    public init?(_ value: Double) {
        guard RPE.allowedValues.contains(value) else { return nil }
        self.value = value
    }

    /// Rounds to the nearest legal chip. Used by the voice parser, where "eight
    /// point three" should land on 8.5 rather than being rejected outright.
    public init(snapping value: Double) {
        let clamped = min(max(value, 6), 10)
        let nearest = RPE.allowedValues.min {
            abs($0 - clamped) < abs($1 - clamped)
        }!
        self.value = nearest
    }

    /// Reps left in the tank. The bridge from perceived effort to e1RM.
    public var repsInReserve: Double { 10 - value }

    public static func < (lhs: RPE, rhs: RPE) -> Bool {
        lhs.value < rhs.value
    }

    public static let six      = RPE(6)!
    public static let seven    = RPE(7)!
    public static let eight    = RPE(8)!
    public static let nine     = RPE(9)!
    public static let ten      = RPE(10)!
}

extension RPE: CustomStringConvertible {
    public var description: String {
        value == value.rounded()
            ? String(format: "RPE %.0f", value)
            : String(format: "RPE %.1f", value)
    }
}
