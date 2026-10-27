import Foundation

/// The two rests a lift falls back on when it has none of its own: one for
/// compound lifts, one for accessories (#341).
///
/// These used to be literals inside `Exercise.restTarget`. The owner wanted
/// them to be the lifter's to set — main compound movements need two to three
/// minutes, accessories about one — so they became a value that lives on
/// `GymConfig`. That is the synced row rather than `UserDefaults`, for the
/// reason `GymConfig` gives: a second device would otherwise disagree about how
/// long to rest.
///
/// A value type in Core, passed *into* `Exercise.restTarget(using:)`, rather
/// than something Core reaches for: Core stays Foundation-only and the rule is
/// unit-tested without a store.
///
/// Which lifts count as compound is not part of this. That is
/// `Exercise.isCompound`, and no setting here changes it.
public struct RestDefaults: Hashable, Codable, Sendable {

    /// Which of the two defaults a lift follows.
    ///
    /// Named so lift settings can say "follows the compound default" without
    /// re-deriving the answer from `isCompound` (the App did exactly that,
    /// with the old literals, before #341).
    public enum Kind: CaseIterable, Sendable {
        case compound
        case accessory
    }

    /// What counts as a usable default, in seconds.
    ///
    /// Below a second is not a rest, and once the app turns it into a plan's
    /// whole-second `restSeconds` it truncates to `0`, which
    /// `RecommendationEngine` rejects as an invalid plan. Past an hour is not
    /// a rest either: the clock gives up ten minutes after the target
    /// (`RestTimer.maximumOverrun`). The upper bound also keeps a corrupt
    /// number from trapping in `Int(_:)`. Lift settings offer 1:00 to 5:00.
    public static let usableRange: ClosedRange<TimeInterval> = 1...3600

    /// The out-of-the-box rests: 3:00 on compounds, 1:00 on accessories.
    public static let standard = RestDefaults(
        compound: standardCompound, accessory: standardAccessory)

    private static let standardCompound: TimeInterval = 180
    private static let standardAccessory: TimeInterval = 60

    /// Rest between working sets on a compound lift, in seconds.
    ///
    /// Always usable (see `usableRange`): an assignment outside it falls back
    /// to the standard value, so the lifter's Settings screen can edit this
    /// in place without every reader having to re-check it.
    public var compound: TimeInterval {
        didSet { compound = Self.usable(compound, else: Self.standardCompound) }
    }

    /// Rest between working sets on an accessory, in seconds. Always usable,
    /// as `compound` is.
    public var accessory: TimeInterval {
        didSet { accessory = Self.usable(accessory, else: Self.standardAccessory) }
    }

    /// An unusable value is replaced by the standard for its own kind, not
    /// clamped to the nearest edge of the range.
    ///
    /// A NaN, a negative or a number from a corrupt sync says nothing about
    /// what the lifter wanted. The honest answer is the rest they'd have had
    /// before the setting existed, and a bad compound value must never cost
    /// the accessory its good one, which is why each is judged alone.
    public init(
        compound: TimeInterval = RestDefaults.standard.compound,
        accessory: TimeInterval = RestDefaults.standard.accessory
    ) {
        self.compound = Self.usable(compound, else: Self.standardCompound)
        self.accessory = Self.usable(accessory, else: Self.standardAccessory)
    }

    /// A key that is missing reads as the standard for that kind, so a row or
    /// backup written before #341 (or half-written) decodes instead of
    /// throwing and taking the rest of the gym with it. A key that is present
    /// but unusable goes through the same fallback as `init`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            compound: try container.decodeIfPresent(TimeInterval.self, forKey: .compound)
                ?? Self.standardCompound,
            accessory: try container.decodeIfPresent(TimeInterval.self, forKey: .accessory)
                ?? Self.standardAccessory
        )
    }

    /// The default for one kind of lift.
    public func seconds(for kind: Kind) -> TimeInterval {
        switch kind {
        case .compound: compound
        case .accessory: accessory
        }
    }

    /// The default a given lift follows, whether or not it has an override.
    public func seconds(for exercise: Exercise) -> TimeInterval {
        seconds(for: exercise.restDefaultKind)
    }

    private static func usable(_ seconds: TimeInterval, else standard: TimeInterval) -> TimeInterval {
        // `contains` is false for NaN, and the bounds are finite, so this is
        // also the finiteness check.
        usableRange.contains(seconds) ? seconds : standard
    }
}
