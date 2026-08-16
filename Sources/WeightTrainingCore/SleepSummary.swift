import Foundation

/// A stretch of time spent asleep, as one source recorded it.
public struct SleepInterval: Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var hours: Double { max(0, end.timeIntervalSince(start)) / 3600 }
}

/// Turns overlapping sleep records into hours actually slept.
///
/// Exists because adding the records up is wrong, and wrong in a direction that
/// looks fine. Oura writes a whole-night "asleep" record *and* the core, deep
/// and REM stages covering the same minutes, so a naive sum counts every night
/// roughly twice — a real 9-hour night reported as 18.5, which then scores as
/// perfect recovery and says nothing (#26).
///
/// The union of the intervals is the honest answer, and it also handles the
/// other case that produces the same bug: a ring and a watch both recording the
/// same night into Health.
public enum SleepSummary {

    /// Hours slept per night, attributed to the morning the night ended on.
    ///
    /// Nights are keyed by their end rather than their start so "last night"
    /// belongs to this morning, which is how anyone reading it would think of it.
    public static func hoursPerNight(
        _ intervals: [SleepInterval],
        calendar: Calendar = .current
    ) -> [HealthSample] {
        var hoursByMorning: [Date: Double] = [:]
        for merged in union(of: intervals) {
            let morning = calendar.startOfDay(for: merged.end)
            hoursByMorning[morning, default: 0] += merged.hours
        }
        return hoursByMorning
            .map { HealthSample(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    /// Merges overlapping and touching intervals.
    ///
    /// Touching ones merge too: consecutive stages abut exactly, and leaving
    /// them separate would be harmless here but makes the result depend on how
    /// finely a device happened to slice the night.
    static func union(of intervals: [SleepInterval]) -> [SleepInterval] {
        let sorted = intervals
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var merged: [SleepInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = SleepInterval(start: current.start,
                                        end: max(current.end, interval.end))
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }
}
