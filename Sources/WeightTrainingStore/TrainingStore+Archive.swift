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
            bodyweights: try bodyweights(),
            gymConfig: try gymConfig()
        )
    }

    /// Every progress state, uniqued by exercise the way the read paths are:
    /// the one that saw the later session wins.
    ///
    /// First-seen would have been an arbitrary pick, because fetch order is
    /// unspecified — so an export taken inside the window where CloudKit has
    /// delivered a duplicate could capture the stale target and wind that lift
    /// back when the file was restored. `storedState(for:)` and
    /// `deduplicate()` both use this rule; now this does too.
    func allProgressStates() throws -> [ProgressState] {
        var freshest: [UUID: ProgressState] = [:]
        for state in try modelContext.fetch(FetchDescriptor<StoredProgressState>()).map({ $0.toDomain() }) {
            if let seen = freshest[state.exerciseID],
               (seen.lastPerformedAt ?? .distantPast) >= (state.lastPerformedAt ?? .distantPast) {
                continue
            }
            freshest[state.exerciseID] = state
        }
        return Array(freshest.values)
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
    /// The merges land in one `save`, because a restore is one event: a
    /// per-row commit would leave a half-imported store behind if it failed
    /// partway, and would take minutes on a real history. A failure rolls the
    /// staged changes back rather than leaving them pending for the next write
    /// to commit.
    ///
    /// The exception is `upsert(archive.exercises)`, which commits on its own
    /// before the rest runs — so a failure after it leaves the lifts restored
    /// and nothing else. That is recoverable by restoring again, which is why
    /// it is tolerable, but it is not the single atomic write the rest of this
    /// paragraph describes.
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

        do {

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

            // The gym the file was written in, written straight to the row rather
            // than through `saveGymConfig` — that re-racks every lift that follows
            // the gym, which is exactly what must not happen to lifts this restore
            // just brought back at their archived values.
            if let gym = archive.gymConfig {
                if let existing = try storedGymConfig() {
                    existing.update(from: gym, at: archive.exportedAt)
                } else {
                    modelContext.insert(StoredGymConfig(gym, updatedAt: archive.exportedAt))
                }
                report.restoredGym = true
            }

            try saveChanges()
        } catch {
            // SwiftData does not roll back a failed save on its own, so
            // without this the staged inserts, updates and deletions stay
            // pending in the shared context and the next unrelated write —
            // logging one set — commits the half-import silently.
            modelContext.rollback()
            throw error
        }

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
            // The archived reading wins, deliberately: a weigh-in carries no
            // id, so its day *is* its identity, and "rows sharing an id are
            // the same row and get overwritten" is the rule this whole merge
            // is built on. `testRestoreKeepsOneWeighInPerDay` pins it.
            //
            // Known tension, left as a decision rather than a fix: restoring
            // an older file therefore replaces a newer weigh-in for that day,
            // while the restore alert says "anything already logged here was
            // kept". Either the rule narrows to recency the way
            // `mergeProgressStates` does, or the sentence narrows to the sets
            // and lifts it is really about. That is a judgement about the
            // lifter's data, so it is Justin's.
            if let existing = byDay[day] { modelContext.delete(existing) }
            let stored = StoredBodyweight(reading)
            modelContext.insert(stored)
            byDay[day] = stored
        }
        return readings.count
    }
}
