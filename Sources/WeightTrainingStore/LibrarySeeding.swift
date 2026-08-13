import Foundation
import SwiftData
import WeightTrainingCore

extension TrainingStore {

    /// Puts the starting library on disk, and keeps it topped up on later
    /// launches.
    ///
    /// Insert-missing rather than seed-once-if-empty, deliberately. Two things
    /// have to stay true as the app evolves:
    ///
    /// - A lift added to `ExerciseLibrary` in a future build has to show up for
    ///   someone who already has a populated database. A bare "is the table
    ///   empty" check would hide it forever.
    /// - An exercise the user has since edited — a corrected machine-stack
    ///   increment from #20, a renamed lift — must not be reverted on the next
    ///   launch. Existing rows are left completely alone.
    ///
    /// Deleting a seeded lift will bring it back on relaunch. That's a real
    /// limitation, and the fix when it starts to matter is a tombstone table
    /// rather than a flag on the row, so a deletion syncs like anything else.
    ///
    /// - Returns: the exercises actually inserted, empty on an up-to-date store.
    @discardableResult
    public func seedLibraryIfNeeded() throws -> [Exercise] {
        let existing = Set(try exercises().map(\.id))
        let missing = ExerciseLibrary.all.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return [] }
        try upsert(missing)
        return missing
    }
}
