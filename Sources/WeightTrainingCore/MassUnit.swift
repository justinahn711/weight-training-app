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
    /// Rounded to one decimal, which is finer than any plate in either world
    /// and coarse enough to hide the float noise a conversion leaves behind:
    /// 100 kg stored as pounds and read back is 99.99999999999999, and showing
    /// that would be an unforced insult.
    public func format(pounds: Double) -> String {
        let value = self.value(fromPounds: pounds)
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f %@", rounded, symbol)
            : String(format: "%.1f %@", rounded, symbol)
    }
}
