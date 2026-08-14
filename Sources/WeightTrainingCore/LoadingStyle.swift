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

    /// Plate sizes available in the gym, in pounds.
    public var availablePlates: [Double]

    public init(baseWeight: Load?, sleeves: Int, availablePlates: [Double] = LoadingStyle.standardPlates) {
        precondition(sleeves > 0, "an apparatus with no sleeves cannot be loaded")
        self.baseWeight = baseWeight
        self.sleeves = sleeves
        self.availablePlates = availablePlates
    }

    /// Plate sizes down to 2.5s, which are what make 5 lb barbell jumps
    /// possible at all.
    public static let standardPlates: [Double] = [45, 35, 25, 10, 5, 2.5]

    /// A 45 lb Olympic bar, plates on both sleeves.
    public static let olympicBarbell = LoadingStyle(baseWeight: Load(45), sleeves: 2)

    /// A machine whose empty weight hasn't been measured yet.
    ///
    /// Loading still works — you can log what you lifted — but no plate
    /// breakdown is offered, because the app doesn't know what the number
    /// includes.
    public static func unmeasuredMachine(sleeves: Int) -> LoadingStyle {
        LoadingStyle(baseWeight: nil, sleeves: sleeves)
    }

    /// Whether a plate breakdown can honestly be produced.
    public var isMeasured: Bool { baseWeight != nil }

    /// The smallest load the apparatus can present: itself, empty.
    public var minimumLoad: Load { baseWeight ?? .zero }

    /// The plates for a load, one sleeve's worth, or nil when the load can't be
    /// built from the available plates.
    public func breakdown(for load: Load) -> PlateBreakdown? {
        guard let base = baseWeight, load >= base else { return nil }

        var remainingPerSleeve = (load.pounds - base.pounds) / Double(sleeves)
        guard remainingPerSleeve >= 0 else { return nil }

        var counts: [PlateCount] = []
        for plate in availablePlates.sorted(by: >) {
            let count = Int((remainingPerSleeve / plate).rounded(.down))
            guard count > 0 else { continue }
            counts.append(PlateCount(plate: plate, count: count))
            remainingPerSleeve -= Double(count) * plate
        }

        // Anything left over means the target wasn't buildable to begin with.
        guard remainingPerSleeve < 0.001 else { return nil }
        return PlateBreakdown(bar: base, perSide: counts, sleeves: sleeves)
    }

    /// Whether a load can be built exactly.
    public func canBuild(_ load: Load) -> Bool {
        breakdown(for: load) != nil
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
