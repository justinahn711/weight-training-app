import Foundation

/// A weight in pounds.
///
/// Wrapped rather than passed around as a bare `Double` so that plate math and
/// increment snapping have one place to live, and so a rep count can never be
/// mistaken for a load at a call site.
public struct Load: Hashable, Codable, Comparable, Sendable {
    public var pounds: Double

    public init(_ pounds: Double) {
        self.pounds = pounds
    }

    public static let zero = Load(0)

    public static func < (lhs: Load, rhs: Load) -> Bool {
        lhs.pounds < rhs.pounds
    }

    public static func + (lhs: Load, rhs: Load) -> Load {
        Load(lhs.pounds + rhs.pounds)
    }

    public static func - (lhs: Load, rhs: Load) -> Load {
        Load(lhs.pounds - rhs.pounds)
    }

    public static func * (lhs: Load, rhs: Double) -> Load {
        Load(lhs.pounds * rhs)
    }
}

extension Load: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.pounds = Double(value) }
    public init(floatLiteral value: Double) { self.pounds = value }
}

extension Load: CustomStringConvertible {
    /// Renders without a trailing `.0`, since most loads are whole numbers and
    /// the session screen is read at arm's length.
    public var description: String {
        pounds == pounds.rounded()
            ? String(format: "%.0f lb", pounds)
            : String(format: "%.1f lb", pounds)
    }
}

/// The smallest load change an exercise can actually make.
///
/// This is the single most consequential number in the app: it's what forces
/// double progression almost everywhere. Dumbbells move 10 lb at a time, so on
/// 70 lb incline presses the smallest possible jump is +14% — far too large for
/// "add weight when you hit your reps" to be a workable rule.
public struct LoadIncrement: Hashable, Codable, Sendable {
    /// Smallest total change in pounds, counting both sides of a barbell or
    /// both hands of a dumbbell pair.
    public var pounds: Double

    public init(pounds: Double) {
        self.pounds = pounds
    }

    /// Barbell with 2.5 lb plates available: 2.5 per side.
    public static let barbell = LoadIncrement(pounds: 5)

    /// Plate-loaded machine with 2.5 lb plates: 2.5 per side.
    public static let plateLoaded = LoadIncrement(pounds: 5)

    /// Dumbbell pairs in 5 lb per-hand steps — 10 lb total.
    public static let dumbbell = LoadIncrement(pounds: 10)

    /// Placeholder for machine stacks until each machine is measured at the gym.
    /// Tracked by issue #20.
    public static let stackDefault = LoadIncrement(pounds: 10)

    /// Rounds a load down to something the equipment can actually make.
    ///
    /// Rounds down rather than to nearest so a suggestion never proposes a
    /// weight heavier than intended.
    public func snap(_ load: Load) -> Load {
        guard pounds > 0 else { return load }
        return Load((load.pounds / pounds).rounded(.down) * pounds)
    }
}
