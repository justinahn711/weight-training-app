import Foundation

/// The room you train in: what unit it's marked in, what's on the plate rack,
/// and what the bar weighs (#73, #67).
///
/// Exists because a gym has one set of plates but a lifter has twenty lifts.
/// #39 put a `LoadingStyle` on each exercise, which is right — a T-bar and a
/// hack squat genuinely load differently — but it meant entering the same rack
/// over and over, and getting it inconsistent. This is the thing they inherit
/// from, with the per-exercise override kept for the cases that need it.
///
/// It is also where the unit preference lives, rather than in `UserDefaults`.
/// The unit and the plates are not two settings; they are one description of a
/// room, and splitting them across two homes would let them disagree — a rack
/// of kilogram plates while the app reads out pounds is exactly the "wrong in a
/// way that looks right" failure #67 was opened about. Keeping it in the synced
/// store also means walking into your gym with a new phone doesn't mean
/// describing the rack again.
///
/// The training split (#136) lives here too, which stretches this type past
/// "the room" — a split is a fact about the person, not the gym. It was put
/// here anyway rather than in a record of its own, because the thing worth
/// reusing isn't the room's meaning, it's the machinery a synced singleton
/// already needed: a fixed id so two offline devices collapse to one row
/// instead of two gyms, `updatedAt` to break a real conflict, and wiring
/// through `deduplicate()` and the backup archive. A second synced model would
/// have needed every one of those again for one more field. The cost is a
/// shared one: `saveGymConfig` already resolves two devices disagreeing about
/// the rack with "the later edit wins, whole row" — extending that to the
/// split means a plate toggle on one phone can now, in the same rare crossed-
/// wire window, revert a split change made on the other. That trade already
/// existed for unit/plates/bar; this asks it to cover one more field rather
/// than opening a second, independent way for two devices to disagree.
public struct GymConfig: Hashable, Codable, Sendable {

    /// How many distinct training days make a consistent week (#65).
    ///
    /// This is stored with the other synced preferences rather than locally,
    /// so History does not tell the same lifter two different stories on two
    /// devices. Three is deliberately ordinary rather than inferred from the
    /// split: a three-day PPL and a six-day PPL use the same rotation but have
    /// very different realistic frequencies.
    public var weeklySessionTarget: Int

    /// The selected training rotation. `nil` means setup hasn't happened yet —
    /// distinct from having chosen push/pull/legs — so a fresh install can
    /// still ask once (#136); `effectiveTrainingSplit` is what every reader
    /// beyond the picker itself should call, since it also covers that case.
    public var trainingSplit: TrainingSplit?

    /// The unit this gym is marked in. Everything the lifter reads and types
    /// is in this; what's stored stays canonically pounds.
    public var unit: MassUnit

    /// Plate sizes on the rack, expressed in `unit`.
    ///
    /// Sizes, not counts — this records that the gym has 25s, not that it has
    /// four of them, so a breakdown can still name more plates than exist. That
    /// limitation belongs here too when it lands (#73), which is part of why
    /// the rack is one object rather than a loose unit setting.
    public var availablePlates: [Double]

    /// What the standard bar in this gym weighs.
    ///
    /// Stored rather than derived from `unit` because it is genuinely per-gym:
    /// most racks have a 20 kg bar, some have a 15 kg one, and a few have a
    /// women's 35 lb bar sitting next to the 45.
    public var barWeight: Load

    /// - Parameters:
    ///   - unit: what the gym is marked in.
    ///   - availablePlates: defaults to the standard rack for `unit` — chosen
    ///     for that world, never converted from the other one.
    ///   - barWeight: defaults to the standard bar for `unit`.
    public init(
        unit: MassUnit = .pounds,
        availablePlates: [Double]? = nil,
        barWeight: Load? = nil,
        trainingSplit: TrainingSplit? = nil,
        weeklySessionTarget: Int = 3
    ) {
        self.unit = unit
        self.availablePlates = availablePlates ?? unit.standardPlates
        self.barWeight = barWeight ?? unit.standardBar
        self.trainingSplit = trainingSplit
        self.weeklySessionTarget = min(max(weeklySessionTarget, 1), 7)
    }

    /// Rows written before this landed describe a pound gym, because that is
    /// the only kind the app could previously represent. Rows written before
    /// #136 have no split at all, which decodes to `nil` — exactly the "setup
    /// hasn't happened" state a genuinely fresh install is in, so an existing
    /// install updating into this feature is asked the same question a new
    /// one is, rather than being silently defaulted onto push/pull/legs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let unit = try container.decodeIfPresent(MassUnit.self, forKey: .unit) ?? .pounds
        self.unit = unit
        self.availablePlates =
            try container.decodeIfPresent([Double].self, forKey: .availablePlates)
            ?? unit.standardPlates
        self.barWeight =
            try container.decodeIfPresent(Load.self, forKey: .barWeight) ?? unit.standardBar
        self.trainingSplit =
            try container.decodeIfPresent(TrainingSplit.self, forKey: .trainingSplit)
        self.weeklySessionTarget = min(max(
            try container.decodeIfPresent(Int.self, forKey: .weeklySessionTarget) ?? 3,
            1
        ), 7)
    }

    /// The split to actually train from: what's chosen, or push/pull/legs
    /// while nothing has been (#136).
    ///
    /// Every reader of the active split — `cyclePosition()`, `startSession`,
    /// the Train screen — should call this rather than `trainingSplit`
    /// directly, so "nobody has picked yet" and "an empty custom split
    /// somehow got stored" both land on a rotation that actually has days in
    /// it, instead of dividing by zero somewhere downstream.
    public var effectiveTrainingSplit: TrainingSplit {
        guard let trainingSplit, !trainingSplit.days.isEmpty else {
            return DayTemplateLibrary.split(.pushPullLegs, startedAt: .distantPast)
        }
        return trainingSplit
    }

    /// What the app assumes until somebody says otherwise: a pound gym with an
    /// Olympic bar and the usual rack.
    public static let standard = GymConfig()

    /// The ordinary gym of a given world.
    public static func standard(in unit: MassUnit) -> GymConfig {
        GymConfig(unit: unit)
    }

    // MARK: - What a lift inherits

    /// The loading style a new plate-loaded lift starts from here.
    ///
    /// - Parameter sleeves: two for a bar, one for a T-bar row.
    public func inheritedLoading(sleeves: Int = 2) -> LoadingStyle {
        LoadingStyle(
            baseWeight: barWeight,
            sleeves: sleeves,
            availablePlates: availablePlates,
            unit: unit,
            followsGymBar: true
        )
    }

    /// The default increment for a piece of equipment in this gym: 5 lb here,
    /// 2.5 kg elsewhere.
    public func defaultIncrement(for equipment: Equipment) -> LoadIncrement {
        equipment.defaultIncrement(in: unit)
    }

    /// Re-racks a loading style that follows the gym, and leaves an overridden
    /// one alone.
    ///
    /// This is the rule #73 asks for: changing the gym's plates reaches every
    /// lift that never had an opinion, and never silently overwrites one that
    /// did. Applying it is cheap and idempotent, so it can run on every read.
    ///
    /// A *measured* base weight survives even on a lift that follows the gym.
    /// The plates and the unit describe the room and are the gym's to change;
    /// what a chest-supported T-bar's lever weighs is a fact about that machine
    /// that somebody went and measured (#20), and no unit change makes it
    /// untrue. Only a base that is just the gym's bar gets swapped for this
    /// gym's.
    ///
    /// Which one a base is, is read from `style.followsGymBar` (#270). #242
    /// tried to recognise it from the number instead — the standard bar, or
    /// the bar of the gym being replaced — which works on the device where the
    /// change is made and nowhere else: a second device learns the gym through
    /// sync with no `previous`, so a stepper's 45 → 40 → 35 stranded its lifts
    /// on 40, and a 35 lb-bar gym switched to kilograms left a 35 lb "bar" in
    /// a kilogram rack. With the answer recorded on the lift, every device
    /// re-racks the same way whatever order the changes arrive in.
    ///
    /// An unmarked base (written before #270) is inferred once and the answer
    /// recorded on the returned style, so it never has to be guessed again:
    /// the gym's current bar, `previous`'s bar, or either unit's standard bar
    /// means following; anything else means measured, because overwriting a
    /// weighed lever is the mistake that can't be seen afterwards. Two cases
    /// come out wrong and can't be told apart from the number alone:
    ///
    /// - A lever weighed at exactly one of those bars is taken as following.
    ///   The lift list already labels such a base "(default)".
    /// - A lift an older build already stranded — on 40 in a gym now at 35,
    ///   or on a 35 lb bar in a kilogram gym — is taken as measured and kept.
    ///   Typing the gym's bar on its sheet hands it back to the gym.
    ///
    /// - Parameter previous: the gym this one replaces, when the caller knows
    ///   it. Only consulted to infer a mark for an unmarked base.
    public func applied(to style: LoadingStyle, replacing previous: GymConfig? = nil) -> LoadingStyle {
        guard style.usesGymRack else { return style }

        var updated = style
        if let base = style.baseWeight {
            let follows = style.followsGymBar ?? isBar(base, replacing: previous)
            if follows { updated.baseWeight = barWeight }
            updated.followsGymBar = follows
        }
        updated.availablePlates = availablePlates
        updated.unit = unit
        return updated
    }

    /// Whether an unmarked base reads as a bar rather than a measurement —
    /// the inference `applied(to:replacing:)` records for rows written before
    /// #270, and the Store's answer when a lifter types a new empty weight.
    public func isBar(_ base: Load, replacing previous: GymConfig? = nil) -> Bool {
        base == barWeight
            || base == previous?.barWeight
            || MassUnit.allCases.contains { base == $0.standardBar }
    }

    /// Re-marks an increment that is still the equipment's default, and leaves
    /// a measured one alone.
    ///
    /// Same rule, same reason. A stack someone measured at 15 lb (#20) is a
    /// fact about that machine; an increment that is merely the default for its
    /// equipment carries no information worth preserving across a unit change,
    /// and leaving it as 5 lb in a kilogram gym would step the bar by 2.27 kg.
    public func applied(to increment: LoadIncrement, for equipment: Equipment) -> LoadIncrement {
        guard increment == equipment.defaultIncrement(in: increment.unit) else { return increment }
        return equipment.defaultIncrement(in: unit)
    }
}
