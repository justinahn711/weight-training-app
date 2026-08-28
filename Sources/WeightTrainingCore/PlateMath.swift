import Foundation

/// A count of one plate size on one side of the bar.
///
/// `plate` is in the rack's own unit — a `25` on a kg rack is 25 kg, not the
/// pounds it converts to. `PlateBreakdown.unit` says which world it is.
public struct PlateCount: Hashable, Sendable {
    public let plate: Double
    public let count: Int

    public init(plate: Double, count: Int) {
        self.plate = plate
        self.count = count
    }
}

/// How to build a barbell load, one side of the bar.
public struct PlateBreakdown: Hashable, Sendable {
    /// What the apparatus weighs empty — the bar, the lever, the sled.
    public let bar: Load
    public let perSide: [PlateCount]

    /// How many sleeves these plates go on. Two for a barbell, one for a T-bar.
    public let sleeves: Int

    /// What the plates actually add up to, which is the load that can be built.
    public let total: Load

    /// The unit the plate numbers are marked in.
    public let unit: MassUnit

    public init(bar: Load, perSide: [PlateCount], sleeves: Int = 2, unit: MassUnit = .pounds) {
        self.bar = bar
        self.perSide = perSide
        self.sleeves = sleeves
        self.unit = unit
        let perSleeve = perSide.reduce(0) { $0 + $1.plate * Double($1.count) }
        self.total = Load(bar.value(in: unit) + perSleeve * Double(sleeves), unit)
    }

    public var isBarOnly: Bool { perSide.isEmpty }

    /// `45 · 25 · 10` — plates per sleeve, heaviest first, read while loading.
    ///
    /// Repeats are listed rather than multiplied because that's the order they
    /// go on the sleeve, and counting three 45s written out is faster than
    /// parsing "45×3" with a bar in your hands.
    public var displayLine: String {
        guard !isBarOnly else { return sleeves == 1 ? "Empty" : "Bar only" }
        return perSide
            .flatMap { entry in Array(repeating: entry.plate, count: entry.count) }
            .map { $0 == $0.rounded() ? String(format: "%.0f", $0) : String(format: "%.1f", $0) }
            .joined(separator: " · ")
    }
}

/// Turns a target weight into plates that exist in the gym.
///
/// Every suggestion the app makes has to land on something that can actually
/// be built. A proposal of 193.3 lb is worse than useless — it's a number that
/// has to be silently rounded by the person holding the bar, which is exactly
/// the arithmetic the app exists to remove.
public enum PlateMath {

    /// A standard 45 lb Olympic bar.
    public static let standardBar = Load(45)

    /// Plate sizes available, heaviest first. 2.5s included, which is what
    /// makes 5 lb barbell jumps possible at all.
    public static let standardPlates: [Double] = [45, 35, 25, 10, 5, 2.5]

    /// Greedy breakdown against a standard Olympic bar.
    ///
    /// Kept for the barbell case; anything else should go through the
    /// exercise's own `LoadingStyle`, which knows its base weight and how many
    /// sleeves it loads onto.
    public static func breakdown(
        for load: Load,
        bar: Load = standardBar,
        plates: [Double] = standardPlates
    ) -> PlateBreakdown? {
        LoadingStyle(baseWeight: bar, sleeves: 2, availablePlates: plates)
            .breakdown(for: load)
    }

    /// Whether a load can be built exactly with the given equipment.
    ///
    /// Plate-built lifts are checked against real plates; everything else
    /// against its configured increment, which is what a machine stack or a
    /// dumbbell rack actually offers.
    public static func isAchievable(
        _ load: Load,
        equipment: Equipment,
        increment: LoadIncrement,
        bar: Load = standardBar,
        plates: [Double] = standardPlates
    ) -> Bool {
        if equipment.usesOlympicBar {
            return breakdown(for: load, bar: bar, plates: plates) != nil
        }
        guard load.pounds >= 0, increment.pounds > 0 else { return false }
        let steps = load.pounds / increment.pounds
        return abs(steps - steps.rounded()) < 0.001
    }
}

extension Equipment {

    /// Whether loads are built on a 45 lb Olympic bar loaded in pairs.
    ///
    /// Narrower than `isPlateBuilt` on purpose. A chest-supported T-bar row
    /// loads one sleeve and a hack squat pushes a sled; neither has a 45 lb bar,
    /// so neither can honestly render "45 · 25" or claim the empty bar as its
    /// lightest setting. They're still plate-built for the purpose of rest
    /// length and warmup ramps, which is what `isPlateBuilt` is for.
    ///
    /// The real weight of a T-bar or a sled is per-machine and has to be
    /// measured, which is the same problem `LoadIncrement` has on stacks (#20).
    public var usesOlympicBar: Bool {
        self == .barbell
    }

    /// The lightest load this equipment can present.
    ///
    /// A barbell cannot go below the bar, which is the floor every computed
    /// proposal has to respect — a percentage adjustment on a light lift will
    /// otherwise happily suggest 40 lb on a 45 lb bar.
    public var minimumLoad: Load {
        usesOlympicBar ? PlateMath.standardBar : Load.zero
    }
}

extension Exercise {

    /// The plate breakdown for a load on this lift, or nil when a breakdown is
    /// meaningless — a cable stack has no plates to read off.
    /// How to build a load on this specific apparatus, or nil when there are
    /// no plates to read off — a stack, a dumbbell, or a machine nobody has
    /// weighed yet.
    public func plateBreakdown(for load: Load) -> PlateBreakdown? {
        loading?.breakdown(for: load)
    }

    /// The closest load to `load` that this equipment can actually be set to.
    ///
    /// The single place a computed proposal becomes a real weight. Anything
    /// that suggests a load must route through here — including proposals that
    /// merely echo what was lifted, since a stale increment (#20) can leave a
    /// stored weight the equipment can no longer make.
    ///
    /// A measured plate-built lift answers from its plate set, because that is
    /// what it can physically make; everything else snaps to the increment.
    /// Having both read the same source is the point of #39 — a lift with a
    /// 2.5 lb increment used to be proposed 187.5 by this method and then told
    /// by `plateBreakdown` that it couldn't be loaded.
    public func nearestAchievable(_ load: Load) -> Load {
        if let loading, loading.isMeasured {
            return loading.nearestBuildable(load)
        }
        let snapped = increment.snapToNearest(load)
        return max(minimumLoad, snapped)
    }

    /// Makes a load that was actually lifted safe to reuse as a target.
    ///
    /// Deliberately gentler than `nearestAchievable`, which is for weights the
    /// app computed. What you lifted is evidence and the increment is a guess,
    /// so an odd dumbbell or stack weight is left exactly as logged — the rack
    /// having 65s is far likelier than the set being imaginary.
    ///
    /// Barbells are the exception, because plate math is objective: 187 lb
    /// cannot be built from standard plates, so it's a mis-log rather than a
    /// mis-configured increment, and echoing it would leave a target that can
    /// never be loaded and no plate line under the stepper.
    ///
    /// Either way the equipment's floor is enforced — nothing goes under the bar.
    public func achievableTarget(echoing load: Load) -> Load {
        let floored = max(minimumLoad, load)
        // Only correct the number where the arithmetic is objective. Plate math
        // on a measured apparatus is; a configured stack increment is a guess,
        // and the rack having 65s is likelier than the set being imaginary.
        guard let loading, loading.isMeasured else { return floored }
        return max(minimumLoad, increment.snapToNearest(floored))
    }

    /// The lightest load this exercise can be set to and still be a set.
    ///
    /// Below one increment there is nothing to load, so a proposal that lands
    /// there isn't lighter — it's nothing at all.
    public var lightestUsableLoad: Load {
        max(minimumLoad, Load(increment.pounds))
    }

    /// The lightest load this exercise can present: the empty apparatus, or
    /// nothing at all for a stack or a dumbbell.
    public var minimumLoad: Load {
        loading?.minimumLoad ?? .zero
    }

    /// Whether this exercise can actually be set to a load.
    ///
    /// Measured plate-loaded lifts are checked against real plates; everything
    /// else against its increment, which is what a stack or a dumbbell rack
    /// offers.
    public func canBuild(_ load: Load) -> Bool {
        if let loading, loading.isMeasured {
            return loading.canBuild(load)
        }
        guard load >= minimumLoad, increment.pounds > 0 else { return false }
        let steps = (load.pounds - minimumLoad.pounds) / increment.pounds
        return abs(steps - steps.rounded()) < 0.001
    }
}
