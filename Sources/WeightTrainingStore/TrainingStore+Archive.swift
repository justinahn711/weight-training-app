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
            gymConfig: try gymConfig(),
            exerciseSessions: try exerciseSessions()
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
    /// must not silently discard it. Wiping first would make "restore the
    /// wrong file" unrecoverable, which is a strange failure mode for a
    /// feature that exists to prevent data loss.
    ///
    /// **What is already here wins (#271).** A restore only adds what the
    /// phone is missing. A row that already exists with the same id is left
    /// exactly as it is, because the phone's copy is at least as new as any
    /// file the lifter can pick: a set corrected after the export (#61), a
    /// lift renamed, a template edited or a deload applied since would
    /// otherwise be quietly reverted while the alert says everything here was
    /// kept. Per kind:
    ///
    /// - Sets, lifts, templates: by id. The one exception is a catalogue row
    ///   still stamped `EditStamp.stock` — seeding put it there and nobody has
    ///   touched it, so it is nobody's change, and the file's copy of an
    ///   edited catalogue lift or template comes back over it. That is what a
    ///   fresh install needs, since seeding runs before restore can.
    /// - Progress state: by lift. The phone's state wins even when the file
    ///   saw a later session; it used to win only on recency, which let a
    ///   file revert a deload applied here without a new session.
    /// - Bodyweight: by calendar day, a weigh-in's identity.
    /// - Gym (and the split riding on it): the one row, field group by field
    ///   group — see `mergeGym`.
    ///
    /// Rows restore adds are stamped with when the file was written, not with
    /// now: they hold what was true then. A lift edited on another device
    /// after the export carries a later stamp and survives the dedupe below,
    /// rather than losing to the older copy restored here (#268). Rows it
    /// leaves alone keep their own stamps.
    ///
    /// Writes are id-aware rather than blind inserts. `deduplicate()` would
    /// collapse a doubled import afterwards regardless, but only after the
    /// duplicates had already been on disk — and on a synced device they would
    /// mirror outward in that window. Cheaper and safer to not create them.
    ///
    /// Everything lands in one `save`, because a restore is one event: a
    /// per-row commit would leave a half-imported store behind if it failed
    /// partway, and would take minutes on a real history. A failure rolls the
    /// staged changes back rather than leaving them pending for the next write
    /// to commit.
    @discardableResult
    public func restore(
        from archive: TrainingArchive,
        calendar: Calendar = .current
    ) throws -> RestoreReport {
        try archive.checkReadable()

        var report = RestoreReport()
        let stamp = EditStamp.at(archive.exportedAt)

        do {
            // Exercises and templates first. A set whose exercise is missing
            // stays on disk but drops out of history and volume until the lift
            // exists, so the lift should exist by the time the set lands.
            let exercises = try merge(
                archive.exercises,
                key: \Exercise.id,
                storedKey: \StoredExercise.id,
                stock: { $0.updatedAt == EditStamp.stock ? try? $0.toDomain() : nil },
                make: { StoredExercise($0, updatedAt: stamp) },
                update: { $0.update(from: $1); $0.updatedAt = stamp }
            )
            report.exercises = exercises.added
            report.kept += exercises.kept

            let templates = try merge(
                archive.dayTemplates,
                key: \DayTemplate.id,
                storedKey: \StoredDayTemplate.id,
                stock: { $0.updatedAt == EditStamp.stock ? try? $0.toDomain() : nil },
                make: { StoredDayTemplate($0, updatedAt: stamp) },
                update: { $0.update(from: $1); $0.updatedAt = stamp }
            )
            report.dayTemplates = templates.added
            report.kept += templates.kept

            let sets = try merge(
                archive.sets,
                key: \SetRecord.id,
                storedKey: \StoredSetLog.id,
                stock: { _ in nil },
                make: { StoredSetLog($0, updatedAt: stamp) },
                update: { _, _ in }
            )
            report.sets = sets.added
            report.kept += sets.kept

            let states = try mergeProgressStates(archive.progressStates)
            report.progressStates = states.added
            report.kept += states.kept

            let existingSessions = Dictionary(try exerciseSessions().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for session in archive.exerciseSessions ?? [] {
                if let existing = existingSessions[session.id] {
                    if existing.updatedAt > session.updatedAt { continue }
                    if existing.updatedAt == session.updatedAt, existing != session {
                        var conflict = existing
                        conflict.plan = nil
                        conflict.recommendationTrace = nil
                        conflict.completion = .unknown
                        conflict.completedAt = [existing.completedAt, session.completedAt].compactMap { $0 }.max()
                        try writeExerciseSession(conflict)
                        report.exerciseSessions += 1
                        continue
                    }
                }
                try writeExerciseSession(session)
                report.exerciseSessions += 1
            }

            let weighIns = try mergeBodyweights(archive.bodyweights, calendar: calendar)
            report.bodyweights = weighIns.added
            report.kept += weighIns.kept

            if let gym = archive.gymConfig {
                report.restoredGym = try mergeGym(gym, exportedAt: archive.exportedAt)
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

    /// Inserts rows this store lacks and leaves the ones it has.
    ///
    /// - Parameter stock: the row's value when it is an untouched catalogue
    ///   seed, nil otherwise. Only such a row is overwritten, and only when the
    ///   file's copy differs from it — an identical copy is already here.
    /// - Returns: rows added (or filled in over a stock seed), and rows the
    ///   file also had that were left as they are.
    private func merge<Value: Equatable, Model: PersistentModel, Key: Hashable>(
        _ values: [Value],
        key: KeyPath<Value, Key>,
        storedKey: KeyPath<Model, Key>,
        stock: (Model) -> Value?,
        make: (Value) -> Model,
        update: (Model, Value) -> Void
    ) throws -> (added: Int, kept: Int) {
        let existing = try modelContext.fetch(FetchDescriptor<Model>())
        var byKey = Dictionary(
            existing.map { ($0[keyPath: storedKey], $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var added = 0, kept = 0
        for value in values {
            let id = value[keyPath: key]
            if let stored = byKey[id] {
                if let seeded = stock(stored), seeded != value {
                    update(stored, value)
                    added += 1
                } else {
                    kept += 1
                }
            } else {
                let stored = make(value)
                modelContext.insert(stored)
                byKey[id] = stored
                added += 1
            }
        }
        return (added, kept)
    }

    /// One state per lift, and the phone's wins whenever it has one.
    ///
    /// This used to resolve on recency the way `deduplicate()` does, with the
    /// file winning a tie. But a deload applied from the digest after the
    /// export changes the target without a new session, so it tied — and the
    /// file wound it back. The phone's state is at least as new as the file.
    private func mergeProgressStates(_ states: [ProgressState]) throws -> (added: Int, kept: Int) {
        var here = Set(
            try modelContext.fetch(FetchDescriptor<StoredProgressState>()).map(\.exerciseID)
        )
        var added = 0, kept = 0
        for state in states {
            if here.contains(state.exerciseID) {
                kept += 1
            } else {
                modelContext.insert(StoredProgressState(state))
                here.insert(state.exerciseID)
                added += 1
            }
        }
        return (added, kept)
    }

    /// The gym the file was written in, merged into the one row here.
    ///
    /// The row holds three things the lifter chooses separately — the rack
    /// (unit, plates, bar), the split, and the weekly target — so each is
    /// settled on its own: **the phone's wins, unless it is still what a fresh
    /// install starts with.** That exception is the stock-seed one again. A
    /// fresh install forces a split pick before restore is reachable, and that
    /// writes a row carrying the standard pound rack nobody chose; keeping it
    /// would let `reconcileGym()` re-rack a kilogram lifter's restored lifts to
    /// pounds at the next launch (#67, #73). The split they just picked is a
    /// choice, and stays.
    ///
    /// Known edge: a lifter who switched *to* exactly the standard pound rack
    /// (or back to a target of three) after the export gets the file's value
    /// back for that group. Nothing on the row tells that apart from a default.
    ///
    /// Written straight to the row rather than through `saveGymConfig`, which
    /// re-racks every lift that follows the gym — exactly what must not happen
    /// to lifts this restore just brought back at their archived values.
    ///
    /// - Returns: whether anything was taken from the file.
    private func mergeGym(_ theirs: GymConfig, exportedAt: Date) throws -> Bool {
        guard let existing = try storedGymConfig(),
              let mine = try? existing.toDomain() else {
            // No gym here, or one that can't be read: the file's is the only
            // readable opinion.
            if let existing = try storedGymConfig() {
                existing.update(from: theirs, at: exportedAt)
            } else {
                modelContext.insert(StoredGymConfig(theirs, updatedAt: exportedAt))
            }
            return true
        }

        let fresh = GymConfig()
        var merged = mine
        if mine.unit == fresh.unit, mine.availablePlates == fresh.availablePlates,
           mine.barWeight == fresh.barWeight {
            merged.unit = theirs.unit
            merged.availablePlates = theirs.availablePlates
            merged.barWeight = theirs.barWeight
        }
        if mine.trainingSplit == nil { merged.trainingSplit = theirs.trainingSplit }
        if mine.weeklySessionTarget == fresh.weeklySessionTarget {
            merged.weeklySessionTarget = theirs.weeklySessionTarget
        }

        guard merged != mine else { return false }
        // The row now holds this phone's choices too, some made after the
        // export, so it keeps whichever stamp is later.
        existing.update(from: merged, at: max(existing.updatedAt, exportedAt))
        return true
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
    ) throws -> (added: Int, kept: Int) {
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

        var added = 0, kept = 0
        for reading in readings {
            let day = calendar.startOfDay(for: reading.recordedAt)
            // A weigh-in carries no id, so its day *is* its identity, and the
            // reading already logged here for that day is this phone's copy
            // of the row — it wins, as every other row does (#271).
            if byDay[day] != nil {
                kept += 1
                continue
            }
            let stored = StoredBodyweight(reading)
            modelContext.insert(stored)
            byDay[day] = stored
            added += 1
        }
        return (added, kept)
    }
}
