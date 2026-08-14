import Foundation

/// Where you are in the push/pull/legs cycle.
public struct CyclePosition: Hashable, Sendable {
    /// The day that comes next.
    public let next: DayKind

    /// When each day was last trained. Absent for a day never done.
    public let lastPerformed: [DayKind: Date]

    public init(next: DayKind, lastPerformed: [DayKind: Date]) {
        self.next = next
        self.lastPerformed = lastPerformed
    }

    /// Whole days since a given day was last trained.
    public func daysSince(
        _ kind: DayKind,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard let last = lastPerformed[kind] else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                       to: calendar.startOfDay(for: now)).day
    }

    /// `Next: Pull — last pull was 6 days ago`.
    ///
    /// Elapsed days are stated because they're genuinely useful — a six-day gap
    /// means something — but they never *decide* anything. The next day comes
    /// from cycle position alone.
    public func summary(now: Date = Date(), calendar: Calendar = .current) -> String {
        let name = next.rawValue
        guard let days = daysSince(next, now: now, calendar: calendar) else {
            return "Next: \(name.capitalized) — first time"
        }
        switch days {
        case 0:  return "Next: \(name.capitalized) — last \(name) was today"
        case 1:  return "Next: \(name.capitalized) — last \(name) was yesterday"
        default: return "Next: \(name.capitalized) — last \(name) was \(days) days ago"
        }
    }
}

/// Works out what to train next from cycle position, never from the calendar.
///
/// At three to four sessions a week a full cycle takes five to seven days and
/// drifts against the week. Anything keyed to "this week" misfires: a Monday
/// isn't a push day, it's whatever comes after the last thing you did. No
/// weekday appears anywhere in this file, or anywhere the app shows.
public enum CycleEngine {

    /// Which day a session was, inferred from what was trained.
    ///
    /// Inferred rather than stored. A stored day-kind would have to be written
    /// when the session started, which makes history depend on the app having
    /// been running and on the session having been "started" properly — and a
    /// session logged across an app restart would lose its label. What was
    /// actually performed is the more reliable record.
    ///
    /// - Returns: the day whose template covers the most of what was performed,
    ///   or nil when nothing matches.
    public static func classify(
        session: [SetRecord],
        templates: [DayTemplate] = DayTemplateLibrary.all
    ) -> DayKind? {
        let performed = Set(session.filter { !$0.isWarmup }.map(\.exerciseID))
        guard !performed.isEmpty else { return nil }

        let scored = templates.map { template -> (kind: DayKind, matches: Int) in
            let candidates = Set(template.slots.flatMap(\.candidateExerciseIDs))
            return (template.kind, performed.intersection(candidates).count)
        }

        guard let best = scored.max(by: { $0.matches < $1.matches }), best.matches > 0 else {
            return nil
        }
        return best.kind
    }

    /// Splits a history into sessions and labels each one.
    ///
    /// - Returns: oldest first, only sessions that could be classified.
    public static func labelledSessions(
        history: [SetRecord],
        templates: [DayTemplate] = DayTemplateLibrary.all,
        calendar: Calendar = .current
    ) -> [(kind: DayKind, date: Date)] {
        history.groupedIntoSessions(calendar: calendar).compactMap { session in
            guard let kind = classify(session: session, templates: templates),
                  let date = session.map(\.performedAt).max() else { return nil }
            return (kind, date)
        }
    }

    /// Where the cycle stands.
    ///
    /// The next day follows the last one performed, regardless of how long ago
    /// that was. Three weeks off with an injury doesn't skip anything — you
    /// come back to the day you hadn't done yet.
    public static func position(
        history: [SetRecord],
        templates: [DayTemplate] = DayTemplateLibrary.all,
        calendar: Calendar = .current
    ) -> CyclePosition {
        let sessions = labelledSessions(history: history, templates: templates,
                                        calendar: calendar)

        var lastPerformed: [DayKind: Date] = [:]
        for session in sessions {
            if let existing = lastPerformed[session.kind], existing >= session.date { continue }
            lastPerformed[session.kind] = session.date
        }

        // A fresh install starts at the top of the cycle.
        guard let latest = sessions.last else {
            return CyclePosition(next: .push, lastPerformed: [:])
        }
        return CyclePosition(next: latest.kind.next, lastPerformed: lastPerformed)
    }

    /// How many times a day has been trained, which is what drives which side
    /// of a rotating slot is due.
    ///
    /// Derived from history rather than stored as a counter, so it stays right
    /// when sessions are skipped, abandoned, or logged out of order.
    public static func completedSessions(
        of kind: DayKind,
        history: [SetRecord],
        templates: [DayTemplate] = DayTemplateLibrary.all,
        calendar: Calendar = .current
    ) -> Int {
        labelledSessions(history: history, templates: templates, calendar: calendar)
            .filter { $0.kind == kind }
            .count
    }
}
