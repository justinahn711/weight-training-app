import Foundation
import SwiftData
import WeightTrainingCore

/// Everything logged, in a file the lifter keeps (#87).
///
/// CloudKit mirroring (#19) is redundancy, not a backup: one account holding
/// one dataset. This is the copy that survives a lost Apple ID, a reset
/// container, or the schema mistake that silently drops the app to local-only
/// storage. It matters more here than in most apps because logged sets are the
/// one thing that cannot be recomputed — records, volume, e1RM and readiness
/// all derive from them, and they derive from nothing.
///
/// Written from `WeightTrainingCore` value types rather than the `Stored*`
/// classes, deliberately. The stored classes never escape `TrainingStore`, and
/// a backup shaped like SwiftData's internals would rot the first time the
/// schema moved — which is exactly the moment an old file has to still open.
public struct TrainingArchive: Codable, Hashable, Sendable {

    /// Bumped when the shape changes in a way an older reader can't handle.
    ///
    /// Versioned from the first release rather than when it first becomes
    /// necessary: an unversioned backup is unreadable the moment the model
    /// moves, and a backup is read at the worst possible time.
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date

    public var exercises: [Exercise]
    public var sets: [SetRecord]
    public var progressStates: [ProgressState]
    public var dayTemplates: [DayTemplate]
    public var bodyweights: [BodyweightReading]

    public init(
        version: Int = TrainingArchive.currentVersion,
        exportedAt: Date = Date(),
        exercises: [Exercise] = [],
        sets: [SetRecord] = [],
        progressStates: [ProgressState] = [],
        dayTemplates: [DayTemplate] = [],
        bodyweights: [BodyweightReading] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.exercises = exercises
        self.sets = sets
        self.progressStates = progressStates
        self.dayTemplates = dayTemplates
        self.bodyweights = bodyweights
    }

    /// True when there is nothing in here worth writing to disk.
    public var isEmpty: Bool {
        exercises.isEmpty && sets.isEmpty && progressStates.isEmpty
            && dayTemplates.isEmpty && bodyweights.isEmpty
    }
}

// MARK: - Reading and writing

public extension TrainingArchive {

    /// ISO-8601 dates and stable key order.
    ///
    /// "Readable without the app" is half the point of having a file, so the
    /// output is meant to survive being opened in a text editor: dates that a
    /// human can check against a training log, and an ordering that makes two
    /// exports of the same history diff cleanly.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ArchiveDate.precise.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ArchiveDate.parse(text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "not an ISO-8601 date: \(text)"
                ))
            }
            return date
        }
        return decoder
    }

    func jsonData() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Reads an archive, refusing one written by a newer build.
    ///
    /// Refusing is the point. A file from a later schema may be missing
    /// nothing an older reader can see, which makes a partial import look like
    /// a successful one — and a half-restored history is worse than no restore,
    /// because it is believed.
    init(json data: Data) throws {
        let archive = try Self.decoder.decode(TrainingArchive.self, from: data)
        try archive.checkReadable()
        self = archive
    }

    func checkReadable() throws {
        guard version <= TrainingArchive.currentVersion else {
            throw ArchiveError.tooNew(found: version, readable: TrainingArchive.currentVersion)
        }
    }

    /// `ChickenBreast-2026-08-26.json`
    var suggestedFilename: String {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return "ChickenBreast-\(day.string(from: exportedAt)).json"
    }
}

/// ISO-8601 with fractional seconds, both ways.
///
/// Fractional seconds are carried because a backup should hand back exactly
/// what it was given. `Date()` keeps sub-second precision, and truncating it
/// on every export would mean a restored history is quietly not the history
/// that was exported — a small enough difference to never be noticed and to
/// make an exact round-trip untestable.
///
/// Parsing accepts a plain second-resolution stamp too, since this file is
/// meant to be readable and therefore editable by hand.
enum ArchiveDate {
    static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        precise.date(from: text) ?? whole.date(from: text)
    }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case tooNew(found: Int, readable: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooNew(found, readable):
            return "This backup is format \(found) and this build reads \(readable). Update ChickenBreast, then import it again."
        }
    }
}

/// What a restore wrote, and what the reconciliation pass collapsed after it.
public struct RestoreReport: Hashable, Sendable {
    public var exercises: Int = 0
    public var sets: Int = 0
    public var progressStates: Int = 0
    public var dayTemplates: Int = 0
    public var bodyweights: Int = 0

    /// Rows `deduplicate()` merged once the import had landed.
    public var deduplicated: DeduplicationReport = DeduplicationReport()

    public var total: Int {
        exercises + sets + progressStates + dayTemplates + bodyweights
    }
    public var isEmpty: Bool { total == 0 }
}
