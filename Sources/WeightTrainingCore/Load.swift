import Foundation

/// A weight, canonically in pounds, as it would be said out loud.
///
/// The unit is deliberately *not* uniform across equipment, because lifters
/// aren't either:
///
/// - Barbells and plate-loaded machines: the whole load, bar included. "225"
///   is a bar with two plates a side.
/// - Dumbbells: the weight **in one hand**. "70" is a pair of 70s, not 35s.
/// - Stacks and cables: whatever the pin says.
///
/// Making this uniform would mean logging a pair of 70s as 140, which nobody
/// does and everybody would misread. The cost is that a dumbbell load is not
/// comparable to a barbell load, which is correct — they aren't.
///
/// Wrapped rather than passed around as a bare `Double` so that plate math and
/// increment snapping have one place to live, and so a rep count can never be
/// mistaken for a load at a call site.
public struct Load: Hashable, Codable, Comparable, Sendable {
    public var pounds: Double

    public init(_ pounds: Double) {
        self.pounds = pounds
    }

    /// A weight given in whatever unit the lifter is working in (#67).
    ///
    /// Pounds stay canonical on the way in, so a load means the same thing
    /// forever regardless of which unit was selected when it was logged.
    public init(_ value: Double, _ unit: MassUnit) {
        self.pounds = unit.pounds(from: value)
    }

    /// This weight, in the given unit.
    public func value(in unit: MassUnit) -> Double {
        unit.value(fromPounds: pounds)
    }

    /// `225 lb`, `102.5 kg`.
    public func formatted(in unit: MassUnit) -> String {
        unit.format(pounds: pounds)
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
    /// Renders in pounds, without a trailing `.0`.
    ///
    /// Anything a lifter reads should go through `formatted(in:)` with the
    /// unit they chose. This stays pound-only and is for debugging and tests,
    /// where a fixed unit is the point — a description that shifted with a
    /// setting would make failures read differently depending on state.
    public var description: String {
        MassUnit.pounds.format(pounds: pounds)
    }
}

/// The smallest load change an exercise can actually make, in the same units
/// the load is expressed in.
///
/// This is the single most consequential number in the app: it's what forces
/// double progression almost everywhere. The next dumbbell up is 5 lb heavier
/// per hand, so moving off the 70s is a 7% jump — and on a machine stack it's
/// often 10 or 15 lb on a 100 lb setting. Both are far too coarse for "add
/// weight when you hit your reps" to be a workable rule on its own.
public struct LoadIncrement: Hashable, Codable, Sendable {
    /// Smallest change in pounds, in the exercise's own terms — the whole bar
    /// for a barbell, one hand for dumbbells.
    public var pounds: Double

    /// The unit this increment is really expressed in (#67).
    ///
    /// Carried rather than derived because increments don't convert: a rack
    /// that steps by 2.5 kg steps by 2.5 kg, and rendering that as the 5.51 lb
    /// it converts to would describe a rack nobody has. The canonical value
    /// stays in pounds so the arithmetic is uniform; this is what it gets
    /// rendered and snapped in.
    public var unit: MassUnit

    public init(pounds: Double) {
        self.init(pounds: pounds, unit: .pounds)
    }

    /// An increment in the unit the equipment is actually marked in.
    public init(_ value: Double, _ unit: MassUnit) {
        self.init(pounds: unit.pounds(from: value), unit: unit)
    }

    public init(pounds: Double, unit: MassUnit) {
        // A zero or negative increment turns snapping into a no-op and makes
        // every load look achievable, which silently disables the guard that
        // stops the app proposing unbuildable weights. The #20 flow lets a
        // measured stack increment be typed in, so this has to be impossible
        // rather than merely discouraged.
        precondition(pounds > 0, "load increment must be positive, got \(pounds)")
        self.pounds = pounds
        self.unit = unit
    }

    /// The step as it's marked on the equipment: `5` lb, `2.5` kg.
    public var nativeValue: Double {
        unit.value(fromPounds: pounds)
    }

    /// `5 lb`, `2.5 kg`.
    ///
    /// Rendered from `nativeValue` rather than through `format(pounds:)`. An
    /// increment is marked on the equipment, not converted to it — which is
    /// the whole reason this type carries a unit — so it takes the native
    /// rule. Through the converted one, a rack stepping by 1.25 kg read
    /// "Steps of 1.3 kg".
    public var formatted: String {
        unit.format(nativeValue)
    }

    /// Rows written before #67 carry no unit and are pounds by definition,
    /// which is also what makes this change need no migration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pounds = try container.decode(Double.self, forKey: .pounds)
        self.unit = try container.decodeIfPresent(MassUnit.self, forKey: .unit) ?? .pounds
    }

    /// Barbell with 2.5 lb plates available: 2.5 per side.
    public static let barbell = LoadIncrement(pounds: 5)

    /// Plate-loaded machine with 2.5 lb plates: 2.5 per side.
    public static let plateLoaded = LoadIncrement(pounds: 5)

    /// The next dumbbell on the rack, 5 lb heavier in each hand.
    ///
    /// Racks vary — many run 5 lb steps to 50 and 10 lb steps above — so this
    /// is a default to be corrected per exercise once measured (#20).
    public static let dumbbell = LoadIncrement(pounds: 5)

    /// Placeholder for machine stacks until each machine is measured at the gym.
    /// Tracked by issue #20.
    public static let stackDefault = LoadIncrement(pounds: 10)

    /// Rounds a load down to something the equipment can actually make.
    ///
    /// Rounds down rather than to nearest so a suggestion never proposes a
    /// weight heavier than intended.
    public func snap(_ load: Load) -> Load {
        guard pounds > 0 else { return load }
        return Load((load.pounds / pounds + Self.snapTolerance).rounded(.down) * pounds)
    }

    /// Absorbs the representation error a kilogram round-trip leaves behind.
    ///
    /// Canonical loads are pounds, and neither a kilogram load nor a kilogram
    /// increment is exactly representable there. A 100 kg working set against a
    /// 2.5 kg step divides to 15.999999999999998, which floors to 15 and drops
    /// a whole increment — a 20 kg bar's 60% warmup rung came out 57.5 kg
    /// instead of 60. The error is on the order of 1e-15 relative, so a
    /// tolerance six orders of magnitude larger still cannot round a load that
    /// is genuinely short of the next step.
    private static let snapTolerance = 1e-9

    /// Rounds to the nearest achievable load, which may be heavier.
    ///
    /// Used where the proposal is a *steer* rather than a prescription: the
    /// RPE-targeted rule computes a percentage adjustment, and rounding that
    /// down every time would bias the lift permanently downward — a 4.5%
    /// increase on 185 lb is 193.3, and taking 190 instead of 195 gives back a
    /// third of the increase before the bar is even loaded.
    public func snapToNearest(_ load: Load) -> Load {
        guard pounds > 0 else { return load }
        return Load((load.pounds / pounds).rounded() * pounds)
    }
}
