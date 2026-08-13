import Foundation

/// A count of one plate size on one side of the bar.
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
    public let bar: Load
    public let perSide: [PlateCount]

    /// What the plates actually add up to, which is the load that can be built.
    public let total: Load

    public init(bar: Load, perSide: [PlateCount]) {
        self.bar = bar
        self.perSide = perSide
        let perSideTotal = perSide.reduce(0) { $0 + $1.plate * Double($1.count) }
        self.total = Load(bar.pounds + perSideTotal * 2)
    }

    public var isBarOnly: Bool { perSide.isEmpty }

    /// `45 · 25 · 10` — plates per side, heaviest first, read while loading.
    ///
    /// Repeats are listed rather than multiplied because that's the order they
    /// go on the sleeve, and counting three 45s written out is faster than
    /// parsing "45×3" with a bar in your hands.
    public var displayLine: String {
        guard !isBarOnly else { return "Bar only" }
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

    /// Greedy breakdown of a barbell load.
    ///
    /// - Returns: nil when the load can't be built — lighter than the bar, or
    ///   needing half a 2.5. The caller is expected to snap first; returning
    ///   nil rather than a nearest guess keeps a rounding decision from hiding
    ///   inside a display helper.
    public static func breakdown(
        for load: Load,
        bar: Load = standardBar,
        plates: [Double] = standardPlates
    ) -> PlateBreakdown? {
        guard load >= bar else { return nil }

        // Plates go on in pairs, so only half the difference is loaded per side.
        var remainingPerSide = (load.pounds - bar.pounds) / 2
        guard remainingPerSide >= 0 else { return nil }

        var counts: [PlateCount] = []
        for plate in plates.sorted(by: >) {
            let count = Int((remainingPerSide / plate).rounded(.down))
            guard count > 0 else { continue }
            counts.append(PlateCount(plate: plate, count: count))
            remainingPerSide -= Double(count) * plate
        }

        // Anything left over means the target wasn't buildable to begin with.
        guard remainingPerSide < 0.001 else { return nil }
        return PlateBreakdown(bar: bar, perSide: counts)
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
        if equipment.isPlateBuilt {
            return breakdown(for: load, bar: bar, plates: plates) != nil
        }
        guard load.pounds >= 0, increment.pounds > 0 else { return load.pounds >= 0 }
        let steps = load.pounds / increment.pounds
        return abs(steps - steps.rounded()) < 0.001
    }
}

extension Equipment {

    /// The lightest load this equipment can present.
    ///
    /// A barbell cannot go below the bar, which is the floor every computed
    /// proposal has to respect — a percentage adjustment on a light lift will
    /// otherwise happily suggest 40 lb on a 45 lb bar.
    public var minimumLoad: Load {
        isPlateBuilt ? PlateMath.standardBar : Load.zero
    }
}

extension Exercise {

    /// The plate breakdown for a load on this lift, or nil when a breakdown is
    /// meaningless — a cable stack has no plates to read off.
    public func plateBreakdown(for load: Load) -> PlateBreakdown? {
        guard equipment.isPlateBuilt else { return nil }
        return PlateMath.breakdown(for: load)
    }

    /// The closest load to `load` that this equipment can actually be set to.
    ///
    /// The single place a computed proposal becomes a real weight: snapped to
    /// the increment, then held at or above the equipment's floor. Anything
    /// that suggests a load should route through here.
    public func nearestAchievable(_ load: Load) -> Load {
        let snapped = increment.snapToNearest(load)
        return max(equipment.minimumLoad, snapped)
    }
}
