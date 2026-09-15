import Foundation

/// The three rings on the Progress tab (#task 8): how this week is going,
/// each against a reference the lifter can actually close.
///
/// - Sessions closes at the weekly session target from `GymConfig`.
/// - Sets closes at the lifter's own usual week — the mean of the previous
///   four trained weeks — rather than at a number nobody chose. Nil until
///   there is a previous week to compare with: unknown means silent, and a
///   ring against a made-up goal would be a wrong number that gets believed.
/// - Muscles closes when every tracked muscle is at or above the bottom of
///   its weekly band in the trailing seven days, which is `VolumeReport`'s
///   own notion of "not starved".
public struct WeeklySummary: Hashable, Sendable {
    public let sessions: Int
    public let sessionTarget: Int
    public let hardSets: Double
    public let usualHardSets: Double?
    public let musclesOnTarget: Int
    public let muscleCount: Int

    public init(
        sessions: Int,
        sessionTarget: Int,
        hardSets: Double,
        usualHardSets: Double?,
        musclesOnTarget: Int,
        muscleCount: Int
    ) {
        self.sessions = sessions
        self.sessionTarget = sessionTarget
        self.hardSets = hardSets
        self.usualHardSets = usualHardSets
        self.musclesOnTarget = musclesOnTarget
        self.muscleCount = muscleCount
    }

    /// 0 to 1, clamped; the text beside the ring carries any overflow.
    public var sessionProgress: Double { Self.progress(sessions, of: sessionTarget) }
    public var setProgress: Double? { usualHardSets.map { Self.progress(hardSets, of: $0) } }
    public var muscleProgress: Double { Self.progress(musclesOnTarget, of: muscleCount) }

    private static func progress<N: BinaryInteger>(_ value: N, of target: N) -> Double {
        progress(Double(value), of: Double(target))
    }

    private static func progress(_ value: Double, of target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, value / target))
    }

    /// How many previous weeks the usual is averaged over.
    public static let usualWindow = 4

    public static func current(
        days: [TrainingDay],
        weekly: [WeeklyVolumePoint],
        volume: VolumeReport,
        sessionTarget: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeeklySummary {
        let target = min(max(sessionTarget, 1), 7)
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start

        // Distinct calendar days with a working set this week — the same
        // definition `TrainingHistory.weeklyConsistency` counts a day by.
        let sessionDays = Set(days.compactMap { day -> Date? in
            guard day.workingSetCount > 0, day.date <= now,
                  calendar.dateInterval(of: .weekOfYear, for: day.date)?.start == currentWeek
            else { return nil }
            return calendar.startOfDay(for: day.date)
        })

        let thisWeek = weekly.first { $0.weekStart == currentWeek }?.total ?? 0
        let previous = weekly
            .filter { $0.weekStart < (currentWeek ?? .distantPast) && $0.total > 0 }
            .suffix(usualWindow)
        let usual = previous.isEmpty
            ? nil
            : previous.reduce(0) { $0 + $1.total } / Double(previous.count)

        let onTarget = volume.muscles.filter { $0.standing != .starved }.count

        return WeeklySummary(
            sessions: sessionDays.count,
            sessionTarget: target,
            hardSets: thisWeek,
            usualHardSets: usual,
            musclesOnTarget: onTarget,
            muscleCount: volume.muscles.count
        )
    }
}
