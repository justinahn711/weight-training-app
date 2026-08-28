import Foundation

/// How a plate-loaded apparatus is built up to a weight.
///
/// Exists because "plate-loaded" isn't one thing. An Olympic bar weighs 45 lb
/// and takes plates on two sleeves. A chest-supported T-bar has a lever of some
/// gym-specific weight and takes plates on one. A hack squat sled weighs
/// whatever it weighs and usually loads on two. Hardcoding the barbell case
/// made the app render plate breakdowns for machines that can't produce them
/// (#39).
///
/// `baseWeight` is optional because it is genuinely unknown until somebody
/// weighs the thing. Unknown means the app declines to show a breakdown rather
/// than inventing one — a plate list that's wrong is worse than none, because
/// it gets followed.
public struct LoadingStyle: Hashable, Codable, Sendable {

    /// What the apparatus weighs empty. Nil until measured.
    public var baseWeight: Load?

    /// How many sleeves plates are loaded onto. Two for a barbell, one for a
    /// T-bar row.
    public var sleeves: Int

    /// Plate sizes available in the gym, expressed in `unit`.
    public var availablePlates: [Double]

    /// The unit this rack is marked in (#67).
    ///
    /// Plate math happens in this unit, never in the canonical pounds. A kg
    /// gym's plates converted to pounds are 55.11, 44.09, 33.07… whose only
    /// common divisor is a rounding artefact, and the reachability search
    /// solves in units of that shared step — so converting would take a 200-
    /// state problem and make it a 50,000-state one, blow the cap, and report
    /// that a loadable weight cannot be built. Staying native keeps the
    /// arithmetic exact and cheap in both worlds.
    public var unit: MassUnit

    /// Whether this lift just uses whatever the gym has, or was given a rack of
    /// its own (#73).
    ///
    /// True means the plates and unit are the gym's to change, and a new plate
    /// set propagates here without being asked. False means somebody sat down
    /// and described this apparatus specifically — a rack with no 35s, a
    /// machine that only takes 25s — and a gym-level change must not quietly
    /// undo that.
    public var usesGymRack: Bool

    public init(
        baseWeight: Load?,
        sleeves: Int,
        availablePlates: [Double]? = nil,
        unit: MassUnit = .pounds,
        usesGymRack: Bool = true
    ) {
        precondition(sleeves > 0, "an apparatus with no sleeves cannot be loaded")
        self.baseWeight = baseWeight
        self.sleeves = sleeves
        self.unit = unit
        self.availablePlates = availablePlates ?? unit.standardPlates
        self.usesGymRack = usesGymRack
    }

    /// Rows written before #67 carry no unit and are pounds by definition.
    /// This is what lets the change land without migrating anything.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseWeight = try container.decodeIfPresent(Load.self, forKey: .baseWeight)
        self.sleeves = try container.decode(Int.self, forKey: .sleeves)
        self.availablePlates = try container.decode([Double].self, forKey: .availablePlates)
        self.unit = try container.decodeIfPresent(MassUnit.self, forKey: .unit) ?? .pounds

        // Rows written before #73 recorded no opinion either, so it has to be
        // inferred — and the safe direction is to assume anything unusual was
        // deliberate. A row holding the plain pound rack is indistinguishable
        // from never having been configured and follows the gym; a row holding
        // anything else was customised by someone and is left alone.
        self.usesGymRack =
            try container.decodeIfPresent(Bool.self, forKey: .usesGymRack)
            ?? (self.availablePlates == MassUnit.pounds.standardPlates)
    }

    /// Plate sizes down to 2.5s, which are what make 5 lb barbell jumps
    /// possible at all.
    public static let standardPlates: [Double] = [45, 35, 25, 10, 5, 2.5]

    /// A 45 lb Olympic bar, plates on both sleeves.
    public static let olympicBarbell = LoadingStyle(baseWeight: Load(45), sleeves: 2)

    /// The standard bar in a given world: 45 lb here, 20 kg elsewhere.
    public static func standardBarbell(in unit: MassUnit) -> LoadingStyle {
        LoadingStyle(baseWeight: unit.standardBar, sleeves: 2, unit: unit)
    }

    /// A machine whose empty weight hasn't been measured yet.
    ///
    /// Loading still works — you can log what you lifted — but no plate
    /// breakdown is offered, because the app doesn't know what the number
    /// includes.
    public static func unmeasuredMachine(sleeves: Int, unit: MassUnit = .pounds) -> LoadingStyle {
        LoadingStyle(baseWeight: nil, sleeves: sleeves, unit: unit)
    }

    /// Whether a plate breakdown can honestly be produced.
    public var isMeasured: Bool { baseWeight != nil }

    /// The smallest load the apparatus can present: itself, empty.
    public var minimumLoad: Load { baseWeight ?? .zero }

    /// The plates for a load, one sleeve's worth, or nil when the load can't be
    /// built from the available plates.
    ///
    /// Exact rather than greedy. Greedy is correct for the standard set but
    /// wrong for the custom ones this config exists to allow: with 25s and 10s
    /// only, greedy meets 30 by taking a 25 and stranding 5, while 10+10+10
    /// builds it exactly. A gym whose plate set makes the app declare a
    /// loadable weight unbuildable is worse than no config at all.
    public func breakdown(for load: Load) -> PlateBreakdown? {
        guard let base = baseWeight, load >= base else { return nil }
        // In the rack's own unit, not the canonical pounds — see `unit`.
        let perSleeve = (load.value(in: unit) - base.value(in: unit)) / Double(sleeves)
        guard let counts = Self.plates(making: perSleeve, from: availablePlates) else {
            return nil
        }
        return PlateBreakdown(bar: base, perSide: counts, sleeves: sleeves, unit: unit)
    }

    /// Whether a load can be built exactly.
    public func canBuild(_ load: Load) -> Bool {
        breakdown(for: load) != nil
    }

    /// The closest load this apparatus can actually be set to.
    ///
    /// The plate set, not a scalar increment, is what a plate-built lift can
    /// really make — which is the disagreement #39 is about: `nearestAchievable`
    /// snapped to the increment while `breakdown` read the plates, so a lift
    /// with a 2.5 lb increment would be handed 187.5 and then told it couldn't
    /// be loaded. Both now read this.
    ///
    /// Ties round down. Between two equally distant loads the lighter one is
    /// the one you can definitely complete.
    public func nearestBuildable(_ load: Load) -> Load {
        guard let base = baseWeight else { return load }
        guard load > base else { return base }

        let baseNative = base.value(in: unit)
        let perSleeve = (load.value(in: unit) - baseNative) / Double(sleeves)
        let reachable = Self.reachable(upTo: perSleeve + (availablePlates.max() ?? 0),
                                       from: availablePlates)
        guard !reachable.isEmpty else { return base }

        let target = Self.cents(perSleeve)
        let best = reachable.min { a, b in
            let da = abs(a - target), db = abs(b - target)
            return da == db ? a < b : da < db
        }
        return Load(baseNative + Double(best ?? 0) / 100 * Double(sleeves), unit)
    }

    // MARK: - Plate reachability

    /// A plate value as hundredths of its own unit, so plate arithmetic is
    /// exact integer work rather than a pile of floating-point tolerances.
    ///
    /// Hundredths is fine enough for both worlds — the smallest plate anyone
    /// racks is 1.25 — and rounding here is also what absorbs the float dust a
    /// pounds round trip leaves on a kg value.
    private static func cents(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    /// The largest step every plate is a whole number of.
    ///
    /// Reachability is solved in these units rather than hundredths, which is
    /// what keeps it cheap: the standard sets share a 2.5 lb / 1.25 kg step, so
    /// a 500 lb sleeve is 200 states instead of 50,000. `nearestAchievable` sits on the
    /// progression engine's hot path and cannot afford the dense version.
    private static func step(of sizes: [Int]) -> Int {
        sizes.reduce(0) { gcd($0, $1) }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// Every per-sleeve total buildable from `plates`, up to a bound, in cents.
    ///
    /// Unlimited plates of each size, which matches what `availablePlates`
    /// records — sizes the gym has, not how many are on the rack.
    private static func reachable(upTo bound: Double, from plates: [Double]) -> [Int] {
        let sizes = plates.map(cents).filter { $0 > 0 }
        guard !sizes.isEmpty, bound >= 0 else { return [0] }

        let unit = step(of: sizes)
        guard unit > 0 else { return [0] }

        let limit = cents(bound) / unit
        guard limit >= 0, limit <= 20_000 else { return [0] }
        let steps = sizes.map { $0 / unit }

        var possible = [Bool](repeating: false, count: limit + 1)
        possible[0] = true
        if limit >= 1 {
            for value in 1...limit {
                for size in steps where size <= value && possible[value - size] {
                    possible[value] = true
                    break
                }
            }
        }
        return possible.enumerated().compactMap { $1 ? $0 * unit : nil }
    }

    /// An exact plate multiset for one sleeve, heaviest first, or nil if the
    /// amount can't be made.
    ///
    /// Prefers heavier plates among exact solutions — fewer plates to handle
    /// and to read off mid-set — but never at the cost of exactness.
    private static func plates(making perSleeve: Double, from plates: [Double]) -> [PlateCount]? {
        let target = cents(perSleeve)
        guard target >= 0 else { return nil }
        guard target > 0 else { return [] }

        let sizes = plates.map(cents).filter { $0 > 0 }.sorted(by: >)
        guard !sizes.isEmpty else { return nil }

        let unit = step(of: sizes)
        // Not a whole number of the shared step, so no combination reaches it.
        guard unit > 0, target % unit == 0 else { return nil }

        let goal = target / unit
        guard goal <= 20_000 else { return nil }
        let steps = sizes.map { $0 / unit }

        // Which plate to take at each remaining amount, taking the heaviest
        // that still leaves a solvable remainder.
        var choice = [Int?](repeating: nil, count: goal + 1)
        var solvable = [Bool](repeating: false, count: goal + 1)
        solvable[0] = true
        if goal >= 1 {
            for value in 1...goal {
                for size in steps where size <= value && solvable[value - size] {
                    solvable[value] = true
                    choice[value] = size
                    break
                }
            }
        }
        guard solvable[goal] else { return nil }

        var counts: [Int: Int] = [:]
        var remaining = goal
        while remaining > 0, let size = choice[remaining] {
            counts[size * unit, default: 0] += 1
            remaining -= size
        }
        return counts
            .sorted { $0.key > $1.key }
            .map { PlateCount(plate: Double($0.key) / 100, count: $0.value) }
    }
}

extension Equipment {

    /// How this equipment is loaded, before any per-exercise correction.
    ///
    /// Machines get their sleeve count from the exercise rather than the
    /// category, since a T-bar and a hack squat are both `.plateLoaded` and
    /// load differently — so the default here is deliberately conservative and
    /// the library overrides it.
    public var defaultLoadingStyle: LoadingStyle? {
        switch self {
        case .barbell:
            return .olympicBarbell
        case .plateLoaded:
            return .unmeasuredMachine(sleeves: 2)
        case .dumbbell, .machineStack, .cable, .bodyweight:
            return nil
        }
    }
}
