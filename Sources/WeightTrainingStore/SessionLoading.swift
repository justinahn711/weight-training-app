import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {

    /// Puts the day templates on disk, and keeps them topped up.
    ///
    /// Insert-missing for the same reasons as the exercise library (#2): a
    /// template added later has to reach an existing database, and a template
    /// the user has since edited must not be reverted on relaunch.
    @discardableResult
    public func seedTemplatesIfNeeded() throws -> [DayTemplate] {
        let existing = Set(try dayTemplates().map(\.id))
        let missing = DayTemplateLibrary.all.filter { !existing.contains($0.id) }
        for template in missing {
            try upsert(template)
        }
        return missing
    }

    /// Where the cycle stands, read from what's actually been trained.
    public func cyclePosition(calendar: Calendar = .current) throws -> CyclePosition {
        let templates = try storedTemplatesOrLibrary()
        return CycleEngine.position(history: try allSets(), templates: templates,
                                    calendar: calendar)
    }

    /// Assembles a session for one day of the cycle.
    ///
    /// Every slot is filled with the exercise that's due — the single candidate,
    /// or the side of a rotating pair whose turn it is — so opening a day gives
    /// a target for each slot without any choosing. Swapping within a slot is
    /// #18; this is the one-tap default.
    ///
    /// Anything already logged on `startedAt`'s calendar day is treated as part
    /// of this session rather than as history. Without that, force-quitting
    /// mid-day — or just coming back after the phone locked — would show an
    /// empty set list while the sets sat safely on disk, and the same work
    /// would get logged twice.
    public func startSession(
        kind: DayKind,
        startedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Session {
        let templates = try storedTemplatesOrLibrary()
        let template = templates.first { $0.kind == kind }
            ?? DayTemplateLibrary.template(for: kind)

        let stored = try exercises()
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })

        // Which side of a rotating slot is due depends on how many of this day
        // have been completed, derived from history rather than stored.
        let history = try allSets()
        let completed = CycleEngine.completedSessions(
            of: kind, history: history, templates: templates, calendar: calendar
        )

        let sessionExercises = try template.slots.compactMap { slot -> SessionExercise? in
            // Fall back through the slot's candidates so a lift the user
            // deleted leaves the slot working rather than empty.
            let dueID = slot.dueCandidate(completionCount: completed)
            let candidates = [dueID].compactMap { $0 } + slot.candidateExerciseIDs
            guard let exercise = candidates.lazy.compactMap({ byID[$0] }).first else {
                return nil
            }

            return try sessionExercise(
                for: exercise, slot: slot, startedAt: startedAt, calendar: calendar
            )
        }

        return Session(kind: kind, exercises: sessionExercises, startedAt: startedAt)
    }

    /// When each exercise was last performed, for ranking swap candidates by
    /// staleness (#18).
    public func lastPerformedDates() throws -> [UUID: Date] {
        var dates: [UUID: Date] = [:]
        for set in try allSets() where !set.isWarmup {
            if let existing = dates[set.exerciseID], existing >= set.performedAt { continue }
            dates[set.exerciseID] = set.performedAt
        }
        return dates
    }

    /// Builds one filled slot: the exercise, its target, and its history.
    public func sessionExercise(
        for exercise: Exercise,
        slot: Slot?,
        startedAt: Date,
        calendar: Calendar = .current
    ) throws -> SessionExercise {
        let state = try progressState(forExercise: exercise.id)
        let history = try sets(forExercise: exercise.id)
        let today = history.filter { calendar.isDate($0.performedAt, inSameDayAs: startedAt) }
        let earlier = history.filter { !calendar.isDate($0.performedAt, inSameDayAs: startedAt) }

        return SessionExercise(
            exercise: exercise,
            slot: slot,
            prescription: Prescription(exercise: exercise, state: state),
            // "Last time" means the previous session, so today's own sets are
            // excluded from it.
            lastPerformance: LastPerformance.mostRecent(in: earlier),
            loggedSets: today
        )
    }

    /// Stored templates, falling back to the seeded ones.
    ///
    /// The fallback matters on a database written before templates existed:
    /// the day still opens instead of coming up empty.
    private func storedTemplatesOrLibrary() throws -> [DayTemplate] {
        let stored = try dayTemplates()
        return stored.isEmpty ? DayTemplateLibrary.all : stored
    }
}

extension TrainingStore {

    /// Trailing volume by muscle, for the guard in #25.
    public func volumeReport(
        days: Int = VolumeReport.windowDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> VolumeReport {
        VolumeReport.trailing(
            days: days,
            history: try allSets(),
            exercises: try exercises(),
            now: now,
            calendar: calendar
        )
    }
}
