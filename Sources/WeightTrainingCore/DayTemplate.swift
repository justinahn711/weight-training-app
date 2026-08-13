import Foundation

/// Which day of the push/pull/legs cycle.
///
/// Cycle position drives what comes next — never the weekday. At 3–4 sessions a
/// week a full cycle takes 5–7 days and drifts against the calendar, so
/// anything keyed to "this week" misfires.
public enum DayKind: String, Codable, CaseIterable, Sendable {
    case push
    case pull
    case legs

    public var next: DayKind {
        switch self {
        case .push: return .pull
        case .pull: return .legs
        case .legs: return .push
        }
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
    public var slots: [Slot]

    public init(id: UUID = UUID(), kind: DayKind, slots: [Slot]) {
        self.id = id
        self.kind = kind
        self.slots = slots
    }
}
