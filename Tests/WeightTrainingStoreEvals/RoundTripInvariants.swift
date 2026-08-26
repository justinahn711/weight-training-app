import Foundation
import WeightTrainingCore
@testable import WeightTrainingStore

public struct CheckResult {
    public let name: String
    public let passed: Bool
    public let detail: String

    static func of(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String) -> CheckResult {
        CheckResult(name: name, passed: passed, detail: passed ? "" : detail())
    }
}

/// Everything on disk, as comparable values.
///
/// Compared as sets rather than arrays: nothing in the app promises a stable
/// row order out of SwiftData, so an eval that demanded one would fail on a
/// detail no lifter can see.
public struct StoreSnapshot: Equatable {
    public var exercises: Set<Exercise>
    public var sets: Set<SetRecord>
    public var states: [UUID: ProgressState]
    public var templates: Set<DayTemplate>
    public var bodyweights: Set<BodyweightReading>

    @MainActor
    public static func of(_ store: TrainingStore) throws -> StoreSnapshot {
        StoreSnapshot(
            exercises: Set(try store.exercises()),
            sets: Set(try store.allSets()),
            states: Dictionary(
                try store.allProgressStates().map { ($0.exerciseID, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            templates: Set(try store.dayTemplates()),
            bodyweights: Set(try store.bodyweights())
        )
    }

    /// What differs, phrased in rows rather than in diffs of opaque structs.
    public func difference(from other: StoreSnapshot) -> String {
        var lines: [String] = []
        func report(_ label: String, _ mine: Int, _ theirs: Int) {
            if mine != theirs { lines.append("  \(label): \(theirs) → \(mine)") }
        }
        report("exercises", exercises.count, other.exercises.count)
        report("sets", sets.count, other.sets.count)
        report("progress states", states.count, other.states.count)
        report("templates", templates.count, other.templates.count)
        report("bodyweights", bodyweights.count, other.bodyweights.count)

        let lostSets = other.sets.subtracting(sets)
        if !lostSets.isEmpty {
            let sample = lostSets.sorted { $0.performedAt < $1.performedAt }.prefix(3)
                .map { "\($0.load) x \($0.reps) at \($0.performedAt)" }
            lines.append("  lost sets: \(sample.joined(separator: ", "))")
        }
        let changedSets = sets.subtracting(other.sets)
        if !changedSets.isEmpty, lostSets.isEmpty {
            let sample = changedSets.sorted { $0.performedAt < $1.performedAt }.prefix(3)
                .map { "\($0.load) x \($0.reps) at \($0.performedAt)" }
            lines.append("  unexpected sets: \(sample.joined(separator: ", "))")
        }
        return lines.isEmpty ? "  (counts match; a value differs)" : lines.joined(separator: "\n")
    }
}

/// What the lifter actually reads: records, volume, trends, history.
///
/// This is the half of #88's done-when that row equality doesn't reach — "the
/// same history, records and trends". Derived data is recomputed from logged
/// sets, so a round trip that preserves every row but perturbs an instant or
/// an ordering can still hand back different answers on screen.
public struct DerivedSnapshot: Equatable {
    public var records: [PersonalRecord]
    public var volume: Set<MuscleVolume>
    public var trends: [E1RMTrend]
    public var days: [TrainingDay]

    /// A fixed `now`, because volume is a trailing window and a real clock
    /// would make the comparison depend on when the suite ran.
    static let now = Corpus.at(day: 200)

    @MainActor
    public static func of(_ store: TrainingStore) throws -> DerivedSnapshot {
        let history = try store.allSets()
        let exercises = try store.exercises()
        let calendar = Corpus.calendar

        return DerivedSnapshot(
            records: PersonalRecords.recent(in: history, since: Date.distantPast)
                .sorted { left, right in
                    (left.set.performedAt, left.set.id.uuidString, String(describing: left.kind))
                        < (right.set.performedAt, right.set.id.uuidString, String(describing: right.kind))
                },
            volume: Set(VolumeReport.trailing(
                days: 10_000, history: history, exercises: exercises,
                now: now, calendar: calendar
            ).muscles),
            trends: E1RMTrendBuilder.trends(history: history, exercises: exercises, calendar: calendar)
                .sorted { $0.exercise.id.uuidString < $1.exercise.id.uuidString },
            days: TrainingHistory.days(history: history, exercises: exercises, calendar: calendar)
                .sorted { $0.date < $1.date }
        )
    }

    public func difference(from other: DerivedSnapshot) -> String {
        var lines: [String] = []
        if records != other.records {
            lines.append("  records: \(other.records.count) → \(records.count)")
        }
        if volume != other.volume { lines.append("  volume differs") }
        if trends != other.trends {
            lines.append("  trends: \(other.trends.count) → \(trends.count)")
        }
        if days != other.days {
            let mine = days.map(\.date), theirs = other.days.map(\.date)
            lines.append("  training days: \(theirs.count) → \(mine.count)")
            if mine != theirs {
                let lost = Set(theirs).subtracting(Set(mine)).sorted().prefix(3)
                if !lost.isEmpty { lines.append("  days lost: \(lost)") }
            }
        }
        return lines.isEmpty ? "  (a value differs)" : lines.joined(separator: "\n")
    }
}

/// The properties a backup has to hold for every history, not just the one it
/// was developed against.
public enum RoundTrip {

    /// Seeds a fresh store with the shape and returns it.
    @MainActor
    public static func store(for shape: HistoryShape) throws -> TrainingStore {
        let store = try TrainingStore.inMemory()
        try shape.seed(into: store)
        return store
    }

    @MainActor
    public static func check(_ shape: HistoryShape) throws -> [CheckResult] {
        let origin = try store(for: shape)
        let exportedAt = Corpus.at(day: 100)
        let archive = try origin.archive(exportedAt: exportedAt)
        let json = try archive.jsonData()

        let before = try StoreSnapshot.of(origin)
        let derivedBefore = try DerivedSnapshot.of(origin)

        // A reinstall: a brand-new store that has never seen this history.
        let restored = try TrainingStore.inMemory()
        try restored.restore(from: TrainingArchive(json: json), calendar: Corpus.calendar)
        let after = try StoreSnapshot.of(restored)

        var results: [CheckResult] = []

        results.append(.of(
            "every row comes back",
            after == before,
            after.difference(from: before)
        ))

        let derivedAfter = try DerivedSnapshot.of(restored)
        results.append(.of(
            "what the lifter reads is unchanged",
            derivedAfter == derivedBefore,
            derivedAfter.difference(from: derivedBefore)
        ))

        // Instants, not calendar days. Which day an instant falls on is a
        // property of the calendar you ask with; what a restore owes you is
        // the instant itself, unshifted by any timezone the file passed
        // through on the way (#79, #88).
        let originalInstants = before.sets
            .map(\.performedAt.timeIntervalSince1970).sorted()
        let restoredInstants = after.sets
            .map(\.performedAt.timeIntervalSince1970).sorted()
        results.append(.of(
            "timestamps survive to the instant",
            originalInstants == restoredInstants,
            "\(zip(originalInstants, restoredInstants).filter { $0 != $1 }.count) of "
                + "\(originalInstants.count) instants moved"
        ))

        // Re-exporting has to produce the same document, or two backups of one
        // history disagree and neither can be trusted.
        let reexported = try restored.archive(exportedAt: exportedAt).jsonData()
        results.append(.of(
            "a restored store exports the same document",
            reexported == json,
            "\(json.count) bytes → \(reexported.count) bytes"
        ))

        // Importing the same file twice is the thing a worried person does.
        try restored.restore(from: TrainingArchive(json: json), calendar: Corpus.calendar)
        let afterSecondImport = try StoreSnapshot.of(restored)
        results.append(.of(
            "importing twice changes nothing",
            afterSecondImport == after,
            afterSecondImport.difference(from: after)
        ))

        return results
    }

    /// A restore onto a phone that has kept training. Nothing either side
    /// already had may disappear.
    @MainActor
    public static func checkMerge(
        _ shape: HistoryShape,
        onto other: HistoryShape
    ) throws -> [CheckResult] {
        let origin = try store(for: shape)
        let archive = try origin.archive(exportedAt: Corpus.at(day: 100))

        let target = try store(for: other)
        let existing = try StoreSnapshot.of(target)

        try target.restore(from: archive, calendar: Corpus.calendar)
        let merged = try StoreSnapshot.of(target)

        let incoming = try StoreSnapshot.of(origin)
        let lost = existing.sets.subtracting(merged.sets)
        let missing = incoming.sets.subtracting(merged.sets)

        return [
            .of("training already here survives the restore", lost.isEmpty,
                "\(lost.count) sets were discarded"),
            .of("the imported training arrives", missing.isEmpty,
                "\(missing.count) sets never landed"),
            .of("nothing is invented",
                merged.sets == existing.sets.union(incoming.sets),
                "\(merged.sets.count) sets, expected "
                    + "\(existing.sets.union(incoming.sets).count)")
        ]
    }
}
