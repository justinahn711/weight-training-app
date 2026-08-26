import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {

    // MARK: - Export (#87)

    /// Everything on disk, as a document that outlives this device.
    ///
    /// Reads through the same uniquing the app reads through, so a store that
    /// has duplicates waiting for the next `deduplicate()` pass still exports
    /// one copy of each row. A backup is a bad place to preserve a defect.
    public func archive(exportedAt: Date = Date()) throws -> TrainingArchive {
        TrainingArchive(
            version: TrainingArchive.currentVersion,
            exportedAt: exportedAt,
            exercises: try exercises(),
            sets: try allSets(),
            progressStates: try allProgressStates(),
            dayTemplates: try dayTemplates(),
            bodyweights: try bodyweights()
        )
    }

    /// Every progress state, uniqued by exercise the way the read paths are,
    /// and in a fixed order.
    ///
    /// The order is the point of the sort, not the order itself — SwiftData
    /// promises nothing without a descriptor, and every other accessor here
    /// picks one (`allSets` by date, `exercises` by name, `bodyweights` by
    /// date). Left unsorted, a phone restored from a backup re-exports the
    /// same history as a *different file*: same rows, shuffled. That defeats
    /// the one cheap way to check a backup is honest — export twice and diff —
    /// and this is the only array in the archive it happened to.
    func allProgressStates() throws -> [ProgressState] {
        var seen: Set<UUID> = []
        return try modelContext.fetch(FetchDescriptor<StoredProgressState>())
            .map { $0.toDomain() }
            .filter { seen.insert($0.exerciseID).inserted }
            .sorted { $0.exerciseID.uuidString < $1.exerciseID.uuidString }
    }

    // MARK: - Restore (#88)

    /// Merges an archive into this store.
    ///
    /// **Merge, not replace.** A restore onto a phone that already has training
    /// must not silently discard it: rows sharing an id are the same row and
    /// get overwritten, rows that don't are all real and all survive. Wiping
    /// first would make "restore the wrong file" unrecoverable, which is a
    /// strange failure mode for a feature that exists to prevent data loss.
    ///
    /// Writes are id-aware rather than blind inserts. `deduplicate()` would
    /// collapse a doubled import afterwards regardless, but only after the
    /// duplicates had already been on disk — and on a synced device they would
    /// mirror outward in that window. Cheaper and safer to not create them.
    ///
    /// Everything lands in one `save`, because a restore is one event: a
    /// per-row commit would leave a half-imported store behind if it failed
    /// partway, and would take minutes on a real history.
    @discardableResult
    public func restore(
        from archive: TrainingArchive,
        calendar: Calendar = .current
    ) throws -> RestoreReport {
        try archive.checkReadable()

        var report = RestoreReport()

        // Exercises and templates first. A set whose exercise is missing stays
        // on disk but drops out of history and volume until the lift exists,
        // so the lift should exist by the time the set lands.
        try upsert(archive.exercises)
        report.exercises = archive.exercises.count

        report.dayTemplates = try merge(
            archive.dayTemplates,
            key: \DayTemplate.id,
            storedKey: \StoredDayTemplate.id,
            make: StoredDayTemplate.init,
            update: { $0.update(from: $1) }
        )

        report.sets = try merge(
            archive.sets,
            key: \SetRecord.id,
            storedKey: \StoredSetLog.id,
            make: StoredSetLog.init,
            update: { $0.update(from: $1) }
        )

        report.progressStates = try mergeProgressStates(archive.progressStates)
        report.bodyweights = try mergeBodyweights(archive.bodyweights, calendar: calendar)

        try saveChanges()

        // The same reconciliation CloudKit conflicts already rely on. An
        // import is the other way duplicate rows arrive, so it runs here too.
        report.deduplicated = try deduplicate()
        return report
    }

    /// Overwrites rows that share an id, inserts the rest.
    private func merge<Value, Model: PersistentModel, Key: Hashable>(
        _ values: [Value],
        key: KeyPath<Value, Key>,
        storedKey: KeyPath<Model, Key>,
        make: (Value) -> Model,
        update: (Model, Value) -> Void
    ) throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<Model>())
        var byKey = Dictionary(
            existing.map { ($0[keyPath: storedKey], $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for value in values {
            let id = value[keyPath: key]
            if let stored = byKey[id] {
                update(stored, value)
            } else {
                let stored = make(value)
                modelContext.insert(stored)
                byKey[id] = stored
            }
        }
        return values.count
    }

    /// Progress state is the one genuinely conflicting entity, so it resolves
    /// the way `deduplicate()` resolves it: whichever saw the later session
    /// wins. A backup restored onto a phone that has since trained on must not
    /// wind that lift's target back to what it was when the file was written.
    private func mergeProgressStates(_ states: [ProgressState]) throws -> Int {
        let existing = try modelContext.fetch(FetchDescriptor<StoredProgressState>())
        var byExercise = Dictionary(
            existing.map { ($0.exerciseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for state in states {
            if let stored = byExercise[state.exerciseID] {
                let here = stored.lastPerformedAt ?? .distantPast
                let incoming = state.lastPerformedAt ?? .distantPast
                if here <= incoming { stored.update(from: state) }
            } else {
                let stored = StoredProgressState(state)
                modelContext.insert(stored)
                byExercise[state.exerciseID] = stored
            }
        }
        return states.count
    }

    /// One reading per day, matching `record(_:calendar:)`.
    ///
    /// Also collapses days that already had more than one row. Nothing else
    /// dedupes bodyweight — `deduplicate()` covers the four entities that
    /// carry an id, and a weigh-in is identified by its day — so two devices
    /// weighing in offline on the same morning can both land. An import is a
    /// reasonable moment to settle that.
    private func mergeBodyweights(
        _ readings: [BodyweightReading],
        calendar: Calendar
    ) throws -> Int {
        var byDay: [Date: StoredBodyweight] = [:]

        for row in try modelContext.fetch(FetchDescriptor<StoredBodyweight>()) {
            let day = calendar.startOfDay(for: row.recordedAt)
            guard let seen = byDay[day] else {
                byDay[day] = row
                continue
            }
            // Keep the later weigh-in, drop the other.
            let loser = seen.recordedAt <= row.recordedAt ? seen : row
            byDay[day] = seen.recordedAt <= row.recordedAt ? row : seen
            modelContext.delete(loser)
        }

        for reading in readings {
            let day = calendar.startOfDay(for: reading.recordedAt)
            if let existing = byDay[day] { modelContext.delete(existing) }
            let stored = StoredBodyweight(reading)
            modelContext.insert(stored)
            byDay[day] = stored
        }
        return readings.count
    }
}
