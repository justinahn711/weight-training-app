import Foundation

/// A best worth telling someone about (#70).
///
/// The app already carries good news deliberately — a digest that only ever
/// nags gets silenced — but the best it could previously manage was "e1RM +5 lb
/// over 4 sessions", which is a trend rather than an achievement. A record is
/// the thing people actually train for.
public struct PersonalRecord: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// The heaviest working set ever performed on this lift.
        case heaviest(Load)
        /// The best estimated max, which can be beaten without touching a
        /// heavier weight — more reps at the same load implies a higher ceiling.
        case estimatedMax(Load)
        /// The most reps ever managed at a given weight.
        ///
        /// The one double progression actually rewards: the programme spends
        /// weeks adding reps at an unchanged load before it adds weight, and
        /// without this those weeks contain no records at all.
        case reps(Int, at: Load)
    }

    public let exerciseID: UUID
    public let kind: Kind

    /// The set that set it.
    public let set: SetRecord

    /// What it beat, absent when this is the first record of its kind.
    ///
    /// A first-ever session is not a record, it's a first data point — the same
    /// reasoning that stops readiness scoring without a baseline.
    public let previous: Double?

    public init(exerciseID: UUID, kind: Kind, set: SetRecord, previous: Double?) {
        self.exerciseID = exerciseID
        self.kind = kind
        self.set = set
        self.previous = previous
    }
}

/// Finds records by comparing a set against everything that came before it.
///
/// Computed from history rather than stored, like every other derived figure
/// here. That's what makes a correction (#61) work: delete the set that set a
/// record and the record goes with it, rather than the app remembering a lift
/// that never happened.
public enum PersonalRecords {

    /// Records set by `candidate`, given the history preceding it.
    ///
    /// - Parameter history: every set for this lift. Sets at or after the
    ///   candidate are ignored, so a record is always judged against what was
    ///   known at the time.
    public static func set(
        by candidate: SetRecord,
        history: [SetRecord]
    ) -> [PersonalRecord] {
        // Warmups can't set records, and nothing scores them.
        guard !candidate.isWarmup else { return [] }

        let earlier = history.filter {
            !$0.isWarmup
                && $0.exerciseID == candidate.exerciseID
                && $0.id != candidate.id
                && $0.performedAt < candidate.performedAt
        }
        // The first working set of a lift is a starting point, not a record.
        guard !earlier.isEmpty else { return [] }

        var records: [PersonalRecord] = []

        let heaviestBefore = earlier.map(\.load.pounds).max() ?? 0
        if candidate.load.pounds > heaviestBefore {
            records.append(PersonalRecord(
                exerciseID: candidate.exerciseID,
                kind: .heaviest(candidate.load),
                set: candidate,
                previous: heaviestBefore
            ))
        }

        if let estimate = candidate.e1RM {
            let bestBefore = earlier.compactMap(\.e1RM).map(\.pounds).max() ?? 0
            if estimate.pounds > bestBefore {
                records.append(PersonalRecord(
                    exerciseID: candidate.exerciseID,
                    kind: .estimatedMax(estimate),
                    set: candidate,
                    previous: bestBefore
                ))
            }
        }

        // Only counts as a rep record if this weight has been lifted before.
        // At a brand-new weight every rep count is trivially a "record", which
        // would fire on every single load increase and mean nothing.
        let atSameLoad = earlier.filter { $0.load == candidate.load }
        if let mostBefore = atSameLoad.map(\.reps).max(), candidate.reps > mostBefore {
            records.append(PersonalRecord(
                exerciseID: candidate.exerciseID,
                kind: .reps(candidate.reps, at: candidate.load),
                set: candidate,
                previous: Double(mostBefore)
            ))
        }

        return records
    }

    /// Every record set within `window`, newest first.
    ///
    /// Each set is judged against everything before it, so a record beaten
    /// again later in the same week reports both — the second one is still a
    /// record, and hiding it would make the week look flatter than it was.
    public static func recent(
        in history: [SetRecord],
        since cutoff: Date
    ) -> [PersonalRecord] {
        let ordered = history.sorted { $0.performedAt < $1.performedAt }
        return ordered
            .filter { $0.performedAt >= cutoff }
            .flatMap { set(by: $0, history: ordered) }
            .sorted { $0.set.performedAt > $1.set.performedAt }
    }
}
