import Foundation

/// The unit a lifter thinks and talks in (#67).
///
/// Storage stays in pounds — every `Load` is canonically pounds, on disk and in
/// CloudKit — and this converts at the edges. That is not a preference for
/// imperial; it's that a stored weight has to mean the same thing forever. If
/// the number on disk meant whatever unit was selected when it was logged, the
/// same set would read differently depending on when you did it, and sync would
/// spread the ambiguity between devices. One canonical unit makes that
/// impossible, and pounds is simply the one already written down.
///
/// What is *not* converted is equipment. A kg gym has 20/15/10/5/2.5/1.25 kg
/// plates and a 20 kg bar — not the pound set run through a multiplier — so
/// plate sets, bar weights and increments are each native to a unit and get
/// chosen, never derived. `2.5 kg` is a real increment; `2.27 kg` is what you
/// get by converting 5 lb, and no gym on earth has it.
public enum MassUnit: String, Codable, CaseIterable, Sendable {
    case pounds
    case kilograms

    /// Exact by international agreement since 1959: a pound is 0.45359237 kg.
    /// Written as the division rather than a rounded 2.20462 so the round trip
    /// through storage and back lands on the same number it started from.
    public static let kilogramsPerPound = 0.453_592_37

    public var symbol: String {
        switch self {
        case .pounds:     return "lb"
        case .kilograms:  return "kg"
        }
    }

    /// How it reads in a settings list.
    public var displayName: String {
        switch self {
        case .pounds:     return "Pounds"
        case .kilograms:  return "Kilograms"
        }
    }

    /// This unit's value, in pounds.
    public func pounds(from value: Double) -> Double {
        switch self {
        case .pounds:     return value
        case .kilograms:  return value / Self.kilogramsPerPound
        }
    }

    /// Pounds, in this unit.
    public func value(fromPounds pounds: Double) -> Double {
        switch self {
        case .pounds:     return pounds
        case .kilograms:  return pounds * Self.kilogramsPerPound
        }
    }

    // MARK: - What the gym actually has

    /// The standard bar: 45 lb, or the 20 kg it is everywhere else.
    ///
    /// Not 20.41 kg. A kg gym's bar is a 20 kg bar, and a lifter reading a
    /// plate line off the app is going to load it as one.
    public var standardBar: Load {
        Load(self.pounds(from: self == .pounds ? 45 : 20))
    }

    /// Plate sizes, heaviest first, as they exist on a rack in this world.
    ///
    /// The kg set runs down to 1.25 for the same reason the pound set runs down
    /// to 2.5: it's what makes the smallest honest jump possible, 2.5 kg on the
    /// bar against 5 lb.
    public var standardPlates: [Double] {
        switch self {
        case .pounds:     return [45, 35, 25, 10, 5, 2.5]
        case .kilograms:  return [25, 20, 15, 10, 5, 2.5, 1.25]
        }
    }

    /// The smallest honest jump on a bar: a pair of the lightest plates.
    public var barbellStep: Double {
        self == .pounds ? 5 : 2.5
    }

    /// What a rack of dumbbells steps by at the light end.
    public var dumbbellStep: Double {
        self == .pounds ? 5 : 2.5
    }

    /// A placeholder until the machine is measured (#20). Stacks vary wildly
    /// and this is only ever a starting point.
    public var stackStep: Double {
        self == .pounds ? 10 : 5
    }

    // MARK: - Rendering

    /// `225 lb`, `102.5 kg` — no trailing `.0`, because most loads are whole
    /// and the session screen is read at arm's length.
    ///
    /// A *converted* weight as text, to one decimal.
    ///
    /// One decimal is right here and two would be a lie. 225 lb is 102.0582 kg,
    /// and rendering "102.06 kg" claims a precision the lift does not have —
    /// nobody loaded 102.06 of anything, they loaded 225 lb. One decimal is
    /// also what hides the float noise a conversion leaves behind: 100 kg
    /// stored as pounds and read back is 99.99999999999999.
    ///
    /// Native values are different and use `format(_:withSymbol:)` below.
    public func format(pounds: Double) -> String {
        let value = self.value(fromPounds: pounds)
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f %@", rounded, symbol)
            : String(format: "%.1f %@", rounded, symbol)
    }

    /// A weight that is already in this unit, at the precision the equipment
    /// actually has.
    ///
    /// Two decimals, because equipment has them: the smallest standard
    /// kilogram plate is 1.25. The previous single rule rounded to one decimal
    /// and called that "finer than any plate in either world", which was
    /// wrong — the 1.25 kg plate toggle rendered as "1.3 kg", a plate nobody
    /// owns. A typed empty weight of 45.25 came back as 45.3 the same way.
    ///
    /// The distinction from `format(pounds:)` is not stylistic. A converted
    /// weight is an approximation of a number the lifter never chose, so extra
    /// digits are noise. A native one — a plate size, a typed empty weight —
    /// is exact, and trimming it changes a fact.
    ///
    /// Trailing zeros are still trimmed: a 45 lb plate is `45`, not `45.00`.
    public func format(_ value: Double, withSymbol: Bool = true) -> String {
        let rounded = (value * 100).rounded() / 100
        let number: String
        if rounded == rounded.rounded() {
            number = String(format: "%.0f", rounded)
        } else if (rounded * 10) == (rounded * 10).rounded() {
            number = String(format: "%.1f", rounded)
        } else {
            number = String(format: "%.2f", rounded)
        }
        return withSymbol ? "\(number) \(symbol)" : number
    }
}
