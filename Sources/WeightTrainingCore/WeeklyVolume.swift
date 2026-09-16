import Foundation

/// A coarse anatomical grouping for the volume chart's filter row.
///
/// Anatomy, not training days: which muscles a push day trains lives on a
/// mutable `DayTemplate` (see `TrendsView`'s grouping note), while "the
/// triceps are an arm muscle" is a fact that does not move when a split is
/// edited. Six regions rather than fourteen muscles, because a filter row
/// with fourteen chips is a list, and the question the chart answers — "am I
/// doing more or less than usual" — is asked about legs, not calves.
public enum MuscleRegion: String, CaseIterable, Hashable, Codable, Sendable {
    case chest
    case back
    case shoulders
    case arms
    case legs
    case core

    public var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .back: return "Back"
        case .shoulders: return "Shoulders"
        case .arms: return "Arms"
        case .legs: return "Legs"
        case .core: return "Core"
        }
    }
}

extension Muscle {
    public var region: MuscleRegion {
        switch self {
        case .chest: return .chest
        case .lats, .traps: return .back
        case .frontDelts, .sideDelts, .rearDelts: return .shoulders
        case .biceps, .triceps, .forearms: return .arms
        case .quads, .hamstrings, .glutes, .calves: return .legs
        case .abs: return .core
        }
    }
}

/// One calendar week of volume, in two forms that deliberately disagree on a
/// compound lift (#214):
///
/// - `hardSetCount` is literal — one logged hard set is one, full stop.
/// - `setsByMuscle` / `muscleCredit` is the same crediting `VolumeReport`
///   guards with: primary involvement counts a full set, secondary a half,
///   and warmups and easy sets (`isHardSet`) count nothing. A set that
///   trains chest and triceps contributes 1.5 there, on purpose — the chart's
///   region filter and the volume guard have to agree on what a week weighed.
///
/// Keeping both on the same point (rather than picking one) is what lets the
/// chart show a literal headline while still answering "how did chest do" in
/// the units the guard actually uses.
public struct WeeklyVolumePoint: Hashable, Sendable, Identifiable {
    public var id: Date { weekStart }
    public let weekStart: Date
    public let setsByMuscle: [Muscle: Double]

    /// Literal hard sets logged this week, regardless of how many muscles any
    /// of them trained. See `muscleCredit` for the weighted number.
    public let hardSetCount: Int

    public init(weekStart: Date, setsByMuscle: [Muscle: Double], hardSetCount: Int = 0) {
        self.weekStart = weekStart
        self.setsByMuscle = setsByMuscle
        self.hardSetCount = hardSetCount
    }

    /// Muscle-credit volume across every muscle. NOT a count of hard sets —
    /// see the type doc. Use `hardSetCount` for the literal number.
    public var muscleCredit: Double { setsByMuscle.values.reduce(0, +) }

    /// Muscle-credit volume in one region, or across every region when none
    /// is chosen. Weighted the same way as `muscleCredit`; a region total is
    /// inherently credited, not literal, because one set can serve two
    /// regions at once (#214).
    public func muscleCredit(in region: MuscleRegion?) -> Double {
        guard let region else { return muscleCredit }
        return setsByMuscle.reduce(0) { $0 + ($1.key.region == region ? $1.value : 0) }
    }
}

/// Volume over time, for the Progress tab (#task 9).
///
/// Calendar weeks, unlike `VolumeReport`'s rolling window: that report asks
/// "is anything starved right now", which drifts with the cycle, while a bar
/// chart asks "how did this week compare with the last twelve", and bars have
/// to share edges to be compared at all.
public enum WeeklyVolumeBuilder {

    public static let defaultWeeks = 12

    /// Exactly `weeks` points, oldest first, ending with the week containing
    /// `now`. Weeks with nothing logged are present at zero — a gap in a bar
    /// chart is a missing week, and a missing week is the thing worth seeing.
    public static func weeks(
        _ weeks: Int = defaultWeeks,
        history: [SetRecord],
        exercises: [Exercise],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeeklyVolumePoint] {
        guard weeks > 0,
              let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var totals: [Date: [Muscle: Double]] = [:]
        var counts: [Date: Int] = [:]
        for set in history where set.isHardSet && set.performedAt <= now {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: set.performedAt)?.start
            else { continue }
            // Counted by week alone, before the exercise lookup: a literal
            // hard set doesn't stop being one just because its exercise
            // record can't be found (#214) — matches `VolumeReport`.
            counts[week, default: 0] += 1
            guard let exercise = byID[set.exerciseID] else { continue }
            for involvement in exercise.muscles {
                totals[week, default: [:]][involvement.muscle, default: 0] += involvement.role.volumeWeight
            }
        }

        return (0..<weeks).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: currentWeek) else {
                return nil
            }
            return WeeklyVolumePoint(
                weekStart: start,
                setsByMuscle: totals[start] ?? [:],
                hardSetCount: counts[start] ?? 0
            )
        }
    }
}
