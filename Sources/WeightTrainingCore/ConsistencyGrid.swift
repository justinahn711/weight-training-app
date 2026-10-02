import Foundation

/// How hard a training day was, in bands a colour ramp can carry.
///
/// Working sets rather than hard sets: this grid answers "did I show up",
/// and a day of RPE-6 work is still a day showed up for. Fixed bands rather
/// than the lifter's own quantiles, so the same colour means the same thing
/// in March as in November.
public enum TrainingIntensity: Int, CaseIterable, Hashable, Sendable {
    case none = 0
    case light
    case moderate
    case heavy
    case full

    public static func level(workingSets: Int) -> TrainingIntensity {
        switch workingSets {
        case ..<1: return .none
        case 1..<8: return .light
        case 8..<16: return .moderate
        case 16..<24: return .heavy
        default: return .full
        }
    }
}

/// One day on the consistency grid.
public struct ConsistencyCell: Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let workingSets: Int
    /// Days after `now`, which the grid draws blank rather than as rest.
    public let isFuture: Bool

    public init(date: Date, workingSets: Int, isFuture: Bool) {
        self.date = date
        self.workingSets = workingSets
        self.isFuture = isFuture
    }

    public var intensity: TrainingIntensity { .level(workingSets: workingSets) }
}

/// The last N calendar weeks, one cell per day, for the heatmap (task 7).
public enum ConsistencyGrid {

    public static let defaultWeeks = 12

    /// `weeks * 7` cells, oldest first, from the start of the week `weeks - 1`
    /// weeks ago through the end of the current week. Every day is present,
    /// so the view can lay the cells out in columns of seven without
    /// looking at a date.
    public static func cells(
        weeks: Int = defaultWeeks,
        days: [TrainingDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ConsistencyCell] {
        guard weeks > 0,
              let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let firstDay = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeek)
        else { return [] }

        let today = calendar.startOfDay(for: now)
        let setsByDay = days.reduce(into: [Date: Int]()) { totals, day in
            totals[calendar.startOfDay(for: day.date), default: 0] += day.workingSetCount
        }

        return (0..<(weeks * 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return ConsistencyCell(
                date: date,
                workingSets: setsByDay[date] ?? 0,
                isFuture: date > today
            )
        }
    }
}
