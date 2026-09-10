import Foundation

/// Identifies one day within whatever split is active.
///
/// Was a fixed `push`/`pull`/`legs` enum until #136 asked for upper/lower,
/// full body, and custom splits with user-chosen day names — a closed set of
/// three cases can't name a fifth day. It's a `String`-backed struct instead,
/// which keeps every existing use (a dictionary key, a `Codable` field, a
/// `switch` matched against `.push`) compiling unchanged: `RawRepresentable`
/// plus `Equatable` is what a `switch`'s `case .push:` actually compiles down
/// to, not enum-ness specifically. What no longer works is exhaustiveness
/// checking, so every such `switch` picked up a `default:` alongside this.
///
/// **Invariant: `rawValue` is the display name, not an opaque id.** A custom
/// day's raw value is the exact name the person typed
/// (`DayTemplateLibrary.customDay(name:exercises:)`), never a synthesized
/// UUID or slug — because `SessionView` and the Live Activity, both outside
/// this issue's file ownership, already render `kind.rawValue.capitalized`
/// and could not be taught to look a name up elsewhere. A future change that
/// gives a custom day a separate opaque identity would silently break both:
/// they would start showing that identity instead of the name.
///
/// `.capitalized` is a lossy read of that name, not a perfect one — it
/// title-cases correctly ("upper body" and "Upper Body" both come back
/// "Upper Body"), but it also lowercases interior capitals a name may have
/// meant to keep, e.g. "HIIT Day" becomes "Hiit Day". That's an accepted
/// cosmetic gap in the two screens that read `.rawValue.capitalized`, not
/// something this change makes worse — it applied equally to "push"/"pull"/
/// "legs" before, they just never had a mixed-case letter to lose.
public struct DayKind: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let rawValue: String

    /// Fails on empty rather than accepting it, the same way a blank exercise
    /// name would be refused — an identity with no name to show is not a
    /// smaller version of a day, it's a broken one.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public static let push = DayKind(rawValue: "push")!
    public static let pull = DayKind(rawValue: "pull")!
    public static let legs = DayKind(rawValue: "legs")!

    /// The original three. Deliberately not "every kind any split can name" —
    /// a custom day's identity is arbitrary text, so enumerating it would mean
    /// nothing. Every existing caller of this constant is specifically about
    /// the fixed push/pull/legs triad.
    public static let allCases: [DayKind] = [.push, .pull, .legs]

    /// The fixed triad's own neighbour, kept for callers still walking it
    /// directly. A configured split doesn't use this — `CycleEngine.position`
    /// steps through the split's own ordered `days` instead, because a custom
    /// or upper/lower day has no neighbour of its own to name.
    public var next: DayKind {
        if self == .push { return .pull }
        if self == .pull { return .legs }
        return .push
    }
}

extension DayKind: Codable {
    /// Encodes and decodes as the bare string an enum-backed `DayKind` always
    /// wrote. `TrainingArchive` is a hand-editable backup file meant to
    /// survive for years (#87), and an export taken before #136 has
    /// `"kind":"push"` sitting in it as a plain JSON string — the synthesized
    /// keyed-container shape a plain struct would otherwise get here
    /// (`{"rawValue":"push"}`) is incompatible, and that file has to keep
    /// opening.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = DayKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "DayKind can't be empty"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A position in a day that gets filled by one exercise.
///
/// Days are shapes rather than fixed lists. A slot offers candidates and the
/// exercise is chosen at the gym, which is what keeps flexible selection from
/// costing a target.
public struct Slot: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String

    /// Ranked by staleness when presented; the first is the default.
    public var candidateExerciseIDs: [UUID]

    /// When true, the slot alternates through its candidates across sessions
    /// rather than defaulting to the same one. Push day uses this to swap chest
    /// fly and skull crushers, holding session length down without giving up
    /// weekly volume on either.
    public var rotates: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        candidateExerciseIDs: [UUID],
        rotates: Bool = false
    ) {
        self.id = id
        self.name = name
        self.candidateExerciseIDs = candidateExerciseIDs
        self.rotates = rotates
    }

    /// Which candidate is due, given how many times this slot has been filled.
    ///
    /// Rotation is derived from a completion count rather than stored, so it
    /// stays correct even when sessions are skipped or logged out of order.
    public func dueCandidate(completionCount: Int) -> UUID? {
        guard !candidateExerciseIDs.isEmpty else { return nil }
        guard rotates else { return candidateExerciseIDs.first }
        return candidateExerciseIDs[completionCount % candidateExerciseIDs.count]
    }
}

/// The shape of one training day.
public struct DayTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var kind: DayKind
    /// What's shown for this day. Defaults to the kind's own word, which is
    /// all push/pull/legs and upper/lower/full body ever need; a custom day
    /// always supplies one explicitly (#136), and — because `customDay`
    /// gives it the same text as `kind`'s raw value — the two stay identical
    /// there too.
    public var name: String
    public var slots: [Slot]

    public init(id: UUID = UUID(), kind: DayKind, name: String? = nil, slots: [Slot]) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.rawValue.capitalized
        self.slots = slots
    }

    /// Rows and archives written before #136 have no `name` at all — the
    /// kind's own capitalized word is exactly what they'd have shown.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(DayKind.self, forKey: .kind)
        slots = try container.decode([Slot].self, forKey: .slots)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? kind.rawValue.capitalized
    }
}

/// Which of the four starting shapes a split began from (#136).
///
/// Kept alongside the day templates themselves rather than inferred from
/// their count, so Settings can still say "Custom" for a one-day custom split
/// instead of confusing it with Full Body, and so re-opening the picker can
/// highlight what's actually selected.
public enum TrainingSplitKind: String, Codable, CaseIterable, Sendable {
    case pushPullLegs
    case upperLower
    case fullBody
    case custom

    public var displayName: String {
        switch self {
        case .pushPullLegs: return "Push / Pull / Legs"
        case .upperLower: return "Upper / Lower"
        case .fullBody: return "Full Body"
        case .custom: return "Custom"
        }
    }
}

/// The rotation currently suggesting what to train next (#136).
///
/// A split is a suggestion, exactly as a single `DayTemplate` always was —
/// #137 already lets a day's roster be edited before it starts, and nothing
/// here should make the plan feel binding. Changing which split is active
/// never touches a logged set: a set belongs to an exercise and a date, not
/// to whichever split happened to suggest it.
public struct TrainingSplit: Hashable, Codable, Sendable {
    public var kind: TrainingSplitKind
    public var days: [DayTemplate]

    /// When this rotation began.
    ///
    /// Answers the other question #136 leaves open: switching from a 3-day
    /// cycle to a 4-day one mid-week has no honest mapping from "pull was
    /// last" onto a slot that may not exist in the new shape, so a change
    /// restarts the rotation rather than guessing. Restarting means
    /// `CycleEngine` only counts sessions logged on or after this date toward
    /// "what's next" — it is a lens on history, not an edit to it, so every
    /// set from before the change still shows up everywhere else exactly as
    /// it was logged.
    public var startedAt: Date

    public init(kind: TrainingSplitKind, days: [DayTemplate], startedAt: Date = Date()) {
        self.kind = kind
        self.days = days
        self.startedAt = startedAt
    }
}
