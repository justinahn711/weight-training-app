import Foundation

/// One session's best estimated max for a lift.
public struct TrendPoint: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let e1RM: Load

    /// What produced the estimate, so a point on the chart can be traced back
    /// to an actual set rather than being an unexplained dot.
    public let topSet: SetRecord

    public init(date: Date, e1RM: Load, topSet: SetRecord) {
        self.date = date
        self.e1RM = e1RM
        self.topSet = topSet
    }
}

/// The "am I actually progressing" series for one lift.
///
/// One point per session rather than per set: a session's ceiling is what
/// progressed or didn't, and plotting every set turns a trend into a scatter of
/// back-off sets.
public struct E1RMTrend: Hashable, Sendable, Identifiable {
    public var id: UUID { exercise.id }
    public let exercise: Exercise
    public let points: [TrendPoint]

    public init(exercise: Exercise, points: [TrendPoint]) {
        self.exercise = exercise
        self.points = points
    }

    /// Sessions needed before a line means anything.
    ///
    /// Two points always make a straight line, and a straight line always looks
    /// like a trend. Three is the fewest that can disagree with itself.
    public static let minimumSessions = 3

    /// Whether there's enough here to draw honestly.
    public var isMeaningful: Bool { points.count >= E1RMTrend.minimumSessions }

    /// How many more sessions before the chart appears.
    public var sessionsUntilMeaningful: Int {
        max(0, E1RMTrend.minimumSessions - points.count)
    }

    public var latest: TrendPoint? { points.last }
    public var best: TrendPoint? { points.max { $0.e1RM < $1.e1RM } }

    /// Change from the first session to the most recent, in pounds.
    public var change: Load? {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return nil
        }
        return Load(last.e1RM.pounds - first.e1RM.pounds)
    }

    /// `+12 lb over 5 sessions`, or an honest admission that there isn't a
    /// trend yet.
    public var summary: String { summary(in: .pounds) }

    /// The same, in the unit the lifter thinks in (#67).
    ///
    /// "Flat" is decided in the display unit rather than in pounds, because
    /// that is the question being asked: a change too small to show at this
    /// precision is one the lifter cannot see, and reporting `+0 kg over 5
    /// sessions` instead of "flat" would be a distinction without a difference.
    public func summary(in unit: MassUnit) -> String {
        guard isMeaningful, let change else {
            let remaining = sessionsUntilMeaningful
            return remaining == 1
                ? "One more session to see a trend"
                : "\(remaining) more sessions to see a trend"
        }
        let value = unit.value(fromPounds: change.pounds)
        let rounded = abs(value) < 0.05 ? 0 : (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : ""
        let amount = rounded == rounded.rounded()
            ? String(format: "%@%.0f %@", sign, rounded, unit.symbol)
            : String(format: "%@%.1f %@", sign, rounded, unit.symbol)
        return rounded == 0
            ? "Flat over \(points.count) sessions"
            : "\(amount) over \(points.count) sessions"
    }
}

/// Builds the trend series.
public enum E1RMTrendBuilder {

    /// One trend per exercise that has been performed at all.
    ///
    /// Lifts with no history are omitted entirely — a chart screen listing
    /// nineteen lifts, sixteen of them empty, buries the three that have
    /// something to say.
    public static func trends(
        history: [SetRecord],
        exercises: [Exercise],
        calendar: Calendar = .current
    ) -> [E1RMTrend] {
        let byExercise = Dictionary(grouping: history.filter { !$0.isWarmup }) {
            $0.exerciseID
        }

        return exercises.compactMap { exercise -> E1RMTrend? in
            guard let sets = byExercise[exercise.id], !sets.isEmpty else { return nil }

            let points = sets.groupedIntoSessions(calendar: calendar)
                .compactMap { session -> TrendPoint? in
                    // The session's ceiling, and the set that reached it.
                    guard let top = session.max(by: { ($0.e1RM ?? .zero) < ($1.e1RM ?? .zero) }),
                          let estimate = top.e1RM,
                          let date = session.map(\.performedAt).max() else { return nil }
                    return TrendPoint(date: date, e1RM: estimate, topSet: top)
                }

            guard !points.isEmpty else { return nil }
            return E1RMTrend(exercise: exercise, points: points)
        }
        // Most sessions first: the lifts with something to show go at the top.
        .sorted { $0.points.count > $1.points.count }
    }
}
