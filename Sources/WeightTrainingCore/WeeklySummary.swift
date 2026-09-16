import Foundation

/// The three rings on the Progress tab (#task 8, #214): how the trailing
/// window is going, each against a reference the lifter can actually close.
///
/// All three read the same `windowDays`-day trailing window — the one
/// `volume` (a `VolumeReport`) was already built over — rather than three
/// different periods dressed up as one card. Before #214, Sessions and Sets
/// were a calendar week while Muscles was a rolling seven days, so "this
/// week" quietly meant two different date ranges depending on which ring you
/// read. `VolumeReport`'s rolling window won that argument: it's also used
/// by the standalone volume guard and the digest, so it's the window that
/// already has to be right.
///
/// - Sessions closes at the weekly session target from `GymConfig`.
/// - Sets is a literal count of hard sets logged in the window — one logged
///   set is one, never muscle-credited (#214) — and closes at the lifter's
///   own usual week: the mean of the previous four *completed calendar*
///   weeks' literal counts. That baseline is a calendar-week average compared
///   against a rolling-window count; the two are close enough in length to
///   be a fair "usual", but not identical, which is why it's presented as a
///   separate "usual" reference rather than folded into the ring's own
///   window claim.
/// - Muscles closes when every tracked muscle is at or above the bottom of
///   its weekly band in the window, which is `VolumeReport`'s own notion of
///   "not starved".
public struct WeeklySummary: Hashable, Sendable {
    public let sessions: Int
    public let sessionTarget: Int

    /// Literal hard sets logged in the window — see the type doc. Use
    /// `MuscleVolume.sets` (via `VolumeReport`) for muscle-credit volume.
    public let hardSets: Int
    public let usualHardSets: Double?
    public let musclesOnTarget: Int
    public let muscleCount: Int

    /// How many trailing days every ring above answers for. Sourced from the
    /// `VolumeReport` passed to `current`, so the card can never drift from
    /// the window it actually computed against.
    public let windowDays: Int

    public init(
        sessions: Int,
        sessionTarget: Int,
        hardSets: Int,
        usualHardSets: Double?,
        musclesOnTarget: Int,
        muscleCount: Int,
        windowDays: Int
    ) {
        self.sessions = sessions
        self.sessionTarget = sessionTarget
        self.hardSets = hardSets
        self.usualHardSets = usualHardSets
        self.musclesOnTarget = musclesOnTarget
        self.muscleCount = muscleCount
        self.windowDays = windowDays
    }

    /// 0 to 1, clamped; the text beside the ring carries any overflow.
    public var sessionProgress: Double { Self.progress(sessions, of: sessionTarget) }
    public var setProgress: Double? {
        usualHardSets.map { Self.progress(Double(hardSets), of: $0) }
    }
    public var muscleProgress: Double { Self.progress(musclesOnTarget, of: muscleCount) }

    private static func progress<N: BinaryInteger>(_ value: N, of target: N) -> Double {
        progress(Double(value), of: Double(target))
    }

    private static func progress(_ value: Double, of target: Double) -> Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, value / target))
    }

    /// How many previous calendar weeks the usual is averaged over.
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

        // Distinct days with a working set inside `volume`'s own window —
        // the same inclusion test `VolumeReport.trailing` applies to a set,
        // so this ring can never claim a wider or narrower range than the
        // muscles ring beside it (#214). This intentionally no longer
        // matches `TrainingHistory.weeklyConsistency`'s calendar-week
        // grouping, which is a different, explicitly calendar-labelled
        // streak metric, not one of this card's rings.
        let sessionDays = Set(days.compactMap { day -> Date? in
            let workingSets = day.exercises.flatMap(\.workingSets)
            guard workingSets.contains(where: { $0.performedAt >= volume.from && $0.performedAt <= volume.to })
            else { return nil }
            return calendar.startOfDay(for: day.date)
        })

        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let previous = weekly
            .filter { $0.weekStart < (currentWeek ?? .distantPast) && $0.hardSetCount > 0 }
            .suffix(usualWindow)
        let usual = previous.isEmpty
            ? nil
            : Double(previous.reduce(0) { $0 + $1.hardSetCount }) / Double(previous.count)

        let onTarget = volume.muscles.filter { $0.standing != .starved }.count

        let windowDays = calendar.dateComponents([.day], from: volume.from, to: volume.to).day
            ?? VolumeReport.windowDays

        return WeeklySummary(
            sessions: sessionDays.count,
            sessionTarget: target,
            hardSets: volume.hardSetCount,
            usualHardSets: usual,
            musclesOnTarget: onTarget,
            muscleCount: volume.muscles.count,
            windowDays: windowDays
        )
    }
}
