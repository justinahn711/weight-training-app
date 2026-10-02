import Foundation
import SwiftData
import WeightTrainingCore

/// What a dedupe pass removed.
public struct DeduplicationReport: Hashable, Sendable {
    public var exercises: Int = 0
    public var sets: Int = 0
    public var progressStates: Int = 0
    public var dayTemplates: Int = 0
    public var gymConfigs: Int = 0
    public var workoutDrafts: Int = 0
    public var exerciseSessions: Int = 0

    public var total: Int {
        exercises + sets + progressStates + dayTemplates + gymConfigs + workoutDrafts + exerciseSessions
    }
    public var isEmpty: Bool { total == 0 }
}

extension TrainingStore {

    /// Merges rows that share an identity.
    ///
    /// This is what replaces the unique constraints the schema had to give up
    /// for CloudKit (#19). A synced store cannot enforce uniqueness at the
    /// database level: two devices offline at the same gym can each create the
    /// same row, and neither is wrong until they meet. The reconciliation has
    /// to happen after the fact, here.
    ///
    /// It is safe to run on every launch — on a store with no duplicates it is
    /// a single fetch per entity and no writes.
    ///
    /// Called before reads rather than on a timer, so a duplicate can never be
    /// observed by the app even briefly.
    @discardableResult
    public func deduplicate() throws -> DeduplicationReport {
        var report = DeduplicationReport()

        // Exercises, sets and templates can all hold different values under
        // one id: lifts are editable (#20, #39, #73, #174), sets correctable
        // (#61), and a fresh install seeds stock rows before CloudKit delivers
        // the lifter's own (#268). `DuplicateSurvivor` says which copy wins,
        // and why that answer is the same on every device.
        report.exercises = try collapse(
            FetchDescriptor<StoredExercise>(), key: \.id,
            winner: DuplicateSurvivor.exercise
        )

        report.sets = try collapse(
            FetchDescriptor<StoredSetLog>(), key: \.id,
            winner: { candidates in
                guard let resolution = DuplicateSurvivor.resolvedSet(candidates),
                      !resolution.ambiguous else { return nil }
                let kept = resolution.winner
                kept.workoutID = resolution.record.workoutID
                kept.acceptedPlanID = resolution.record.acceptedPlanID
                kept.effortWasReported = resolution.record.effortWasReported
                return kept
            }
        )

        report.progressStates = try collapse(
            FetchDescriptor<StoredProgressState>(), key: \.exerciseID
        ) { candidates in
            // Two devices can both advance a lift's target while offline. The most recently
            // performed one wins, because it saw the later session — and a
            // state that never recorded a session loses to one that did.
            candidates.max {
                ($0.lastPerformedAt ?? .distantPast) < ($1.lastPerformedAt ?? .distantPast)
            }
        }

        report.dayTemplates = try collapse(
            FetchDescriptor<StoredDayTemplate>(), key: \.id,
            winner: DuplicateSurvivor.template
        )

        report.gymConfigs = try collapse(
            FetchDescriptor<StoredGymConfig>(), key: \.id
        ) { candidates in
            // Two devices can each describe the rack while offline, and both
            // descriptions are real. The later edit wins, because it
            // is the one made with the other already known about — or, if they
            // truly crossed, the one the lifter touched most recently.
            candidates.max { $0.updatedAt < $1.updatedAt }
        }

        report.workoutDrafts = try collapse(
            FetchDescriptor<StoredWorkoutDraft>(), key: \.id
        ) { candidates in
            candidates.max { $0.updatedAt < $1.updatedAt }
        }

        let sessionRows = try modelContext.fetch(FetchDescriptor<StoredExerciseSession>())
        let sessions = try exerciseSessions()
        report.exerciseSessions = sessionRows.count - sessions.count
        if report.exerciseSessions > 0 {
            for session in sessions { try writeExerciseSession(session) }
        }

        if !report.isEmpty {
            try saveChanges()
        }
        return report
    }

    /// Groups rows by `key`, keeps whichever `winner` picks, deletes the rest.
    private func collapse<Model: PersistentModel, Key: Hashable>(
        _ descriptor: FetchDescriptor<Model>,
        key: KeyPath<Model, Key>,
        winner: ([Model]) -> Model?
    ) throws -> Int {
        let rows = try modelContext.fetch(descriptor)
        let grouped = Dictionary(grouping: rows) { $0[keyPath: key] }

        var removed = 0
        for (_, candidates) in grouped where candidates.count > 1 {
            guard let keep = winner(candidates) else { continue }
            for row in candidates where row.persistentModelID != keep.persistentModelID {
                modelContext.delete(row)
                removed += 1
            }
        }
        return removed
    }
}

// MARK: - Which copy survives

/// The stamp a lifter's write puts on a row, and the one seeding puts on a
/// stock row (#268).
///
/// Whole seconds, because the stamp is compared across devices and one side of
/// every comparison has been through CloudKit. A sub-second value that came
/// back rounded would let two devices order the same pair differently — and a
/// different order is a different survivor, which is the bug being fixed.
enum EditStamp {
    /// A catalogue row put there by seeding and not written since. The epoch,
    /// which no real edit can carry, so a seeded row is recognisable on every
    /// device rather than only the one that seeded it.
    static let stock = Date(timeIntervalSince1970: 0)

    static func at(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// Picks the copy `deduplicate()` keeps, and the one a read shows before it
/// runs.
///
/// **The rule has to give the same answer on every device.** Each device
/// dedupes on its own, and deleting the loser is a write that syncs. If device
/// A keeps its copy and device B keeps its own, each deletes the other's and
/// the row is gone everywhere. So the survivor is a function of what the rows
/// hold — values every device sees identically once synced — and never of
/// fetch order, which is local insertion order and differs by device.
///
/// In order, the first difference decides:
///
/// 1. **Who wrote it, and when** (`updatedAt`). A lifter's write beats a row
///    from before stamps existed, which beats a stock row seeded and never
///    touched; between two writes, the later one. This is `StoredGymConfig`'s
///    last-writer-wins, with seeding made to lose rather than look new —
///    stamping a seed with the time it was seeded would make every fresh
///    install's catalogue the newest thing in the account.
/// 2. **Whether it still equals the catalogue.** Between two unstamped rows —
///    both from before this rule — the one that differs from its
///    `ExerciseLibrary` or `DayTemplateLibrary` entry is somebody's edit, and a
///    row identical to the seed is not.
/// 3. **What it holds**, compared byte by byte. Arbitrary but total: two copies
///    that differ in content are ordered the same way everywhere.
/// 4. **Which copy it is** (`copyID`). Only reached by copies with identical
///    content, where keeping either loses nothing — but both devices must
///    still keep the *same* one.
///
/// A pair of pre-#268 rows with identical content and no `copyID` is the one
/// case with nothing left to order by. Either survivor holds the same values,
/// so the worst outcome is the one the old rule always risked.
enum DuplicateSurvivor {

    static func exercise(_ candidates: [StoredExercise]) -> StoredExercise? {
        best(candidates) { row in
            Rank(
                stamp: row.updatedAt,
                isStock: isStock(row),
                content: Content()
                    .adding(row.name).adding(row.equipmentRaw)
                    .adding(row.incrementPounds).adding(row.incrementUnitRaw)
                    .adding(row.needsWarmupRamp ? "1" : "0")
                    .adding(row.musclesData).adding(row.progressionRuleData)
                    .adding(row.loadingData)
                    .adding(row.restOverrideSeconds.map { "\($0.bitPattern)" } ?? "-")
                    .bytes,
                copyID: row.copyID
            )
        }
    }

    static func set(_ candidates: [StoredSetLog]) -> StoredSetLog? {
        best(candidates) { row in
            Rank(
                stamp: row.updatedAt,
                // A logged set has no catalogue to differ from.
                isStock: false,
                content: Content()
                    .adding(row.exerciseID.uuidString).adding(row.pounds)
                    .adding("\(row.reps)")
                    .adding(row.rpeValue.map { "\($0.bitPattern)" } ?? "-")
                    .adding(row.isWarmup ? "1" : "0")
                    .adding(row.performedAt.timeIntervalSince1970)
                    .adding(row.workoutID?.uuidString ?? "-")
                    .adding(row.acceptedPlanID?.uuidString ?? "-")
                    .adding(row.effortWasReported.map { $0 ? "1" : "0" } ?? "-")
                    .bytes,
                copyID: row.copyID
            )
        }
    }

    struct SetResolution {
        var winner: StoredSetLog
        var record: SetRecord
        var ambiguous: Bool
    }

    /// A deterministic display survivor is not proof that disputed work was
    /// performed. Keep equally authoritative conflicting copies on disk until
    /// an explicit, newer correction resolves them. Reads withdraw their
    /// workout association, so they cannot earn either increases or resets.
    /// This also keeps a second deduplication or relaunch from losing the fact
    /// that the performance was disputed.
    static func resolvedSet(_ candidates: [StoredSetLog]) -> SetResolution? {
        guard let winner = set(candidates) else { return nil }
        let authority = Provenance(winner.updatedAt)
        let current = candidates.filter { Provenance($0.updatedAt) == authority }
        var record = winner.toDomain()
        let workouts = Set(current.compactMap(\.workoutID))
        let plans = Set(current.compactMap(\.acceptedPlanID))
        let effort = Set(current.compactMap(\.effortWasReported))
        let ambiguous = workouts.count > 1 || plans.count > 1 || effort.count > 1
            || current.contains {
                $0.exerciseID != winner.exerciseID || $0.pounds != winner.pounds
                    || $0.reps != winner.reps || $0.rpeValue != winner.rpeValue
                    || $0.isWarmup != winner.isWarmup || $0.performedAt != winner.performedAt
            }
        if ambiguous {
            record.workoutID = nil
            record.acceptedPlanID = nil
            record.effortWasReported = nil
        } else {
            // Older clients omit these fields. Matching actuals can retain
            // known provenance without claiming that an unknown value refutes it.
            record.workoutID = workouts.first
            record.acceptedPlanID = plans.first
            record.effortWasReported = effort.first
        }
        return SetResolution(winner: winner, record: record, ambiguous: ambiguous)
    }

    static func template(_ candidates: [StoredDayTemplate]) -> StoredDayTemplate? {
        best(candidates) { row in
            Rank(
                stamp: row.updatedAt,
                isStock: isStock(row),
                content: Content().adding(row.kindRaw).adding(row.slotsData).bytes,
                copyID: row.copyID
            )
        }
    }

    // MARK: Ranking

    /// What a row's stamp says about who wrote it. Declaration order is rank.
    enum Provenance: Comparable {
        /// Seeded and never written since.
        case stock
        /// Written before rows were stamped — possibly an edit.
        case unstamped
        /// Written by the lifter at this time.
        case written(Date)

        init(_ stamp: Date?) {
            switch stamp {
            case nil: self = .unstamped
            case EditStamp.stock?: self = .stock
            case let date?: self = .written(date)
            }
        }
    }

    struct Rank {
        var provenance: Provenance
        var isStock: Bool
        var content: [UInt8]
        var copyID: String

        init(stamp: Date?, isStock: Bool, content: [UInt8], copyID: UUID?) {
            self.provenance = Provenance(stamp)
            self.isStock = isStock
            self.content = content
            self.copyID = copyID?.uuidString ?? ""
        }

        /// True when `self` should be kept over `other`.
        func outranks(_ other: Rank) -> Bool {
            if provenance != other.provenance { return provenance > other.provenance }
            if isStock != other.isStock { return !isStock }
            if content != other.content {
                return other.content.lexicographicallyPrecedes(content)
            }
            return copyID > other.copyID
        }
    }

    private static func best<Row>(_ candidates: [Row], rank: (Row) -> Rank) -> Row? {
        var best: (row: Row, rank: Rank)?
        for row in candidates {
            let r = rank(row)
            if let current = best, !r.outranks(current.rank) { continue }
            best = (row, r)
        }
        return best?.row
    }

    // MARK: Catalogue

    private static let stockExercises = Dictionary(
        ExerciseLibrary.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    private static let stockTemplates = Dictionary(
        DayTemplateLibrary.allBuiltIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    private static func isStock(_ row: StoredExercise) -> Bool {
        guard let stock = stockExercises[row.id] else { return false }
        return (try? row.toDomain()) == stock
    }

    /// Kind and slots only: a stored template doesn't keep its display name,
    /// so the name it reads back with is a default, not something it holds.
    private static func isStock(_ row: StoredDayTemplate) -> Bool {
        guard let stock = stockTemplates[row.id],
              let template = try? row.toDomain() else { return false }
        return template.kind == stock.kind && template.slots == stock.slots
    }

    /// A row's values as one byte string, each field length-prefixed so that
    /// no two different rows can concatenate to the same bytes.
    ///
    /// The JSON columns go in as stored, deliberately not decoded and
    /// re-encoded: `JSONEncoder` does not promise a key order, so two
    /// encodings of one value can differ. The stored bytes are what a record
    /// carries through CloudKit, identical on every device holding it — which
    /// is the only property this ordering needs.
    private struct Content {
        var bytes: [UInt8] = []

        func adding(_ string: String) -> Content {
            var copy = self
            copy.bytes += Array("\(string.utf8.count):".utf8) + Array(string.utf8)
            return copy
        }

        func adding(_ data: Data) -> Content {
            var copy = self
            copy.bytes += Array("\(data.count):".utf8) + Array(data)
            return copy
        }

        /// Exact, rather than a formatted decimal that could round two
        /// different values to one.
        func adding(_ value: Double) -> Content {
            adding("\(value.bitPattern)")
        }
    }
}

extension TrainingStore {

    /// Rows with a duplicated key reduced to the survivor `deduplicate()` would
    /// keep, in their original order — so a read before the pass shows exactly
    /// what the pass will leave behind.
    func survivors<Model: PersistentModel, Key: Hashable>(
        _ rows: [Model],
        key: KeyPath<Model, Key>,
        winner: ([Model]) -> Model?
    ) -> [Model] {
        let grouped = Dictionary(grouping: rows) { $0[keyPath: key] }
        guard grouped.count < rows.count else { return rows }

        var kept: Set<PersistentIdentifier> = []
        for (_, candidates) in grouped {
            if candidates.count == 1 {
                kept.insert(candidates[0].persistentModelID)
            } else if let keep = winner(candidates) {
                kept.insert(keep.persistentModelID)
            }
        }
        return rows.filter { kept.contains($0.persistentModelID) }
    }
}
