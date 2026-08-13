//
//  SessionViewModel.swift
//  ChickenBreast
//

import Foundation
import Observation
import WeightTrainingCore
import WeightTrainingStore

/// Drives the session screen: owns the in-flight `Session` and mirrors every
/// change onto disk.
///
/// Sets are written the instant they're logged rather than batched at the end
/// of the day. A lifting app gets backgrounded constantly — by a phone call, by
/// the screen locking, by another app — and an unsaved set is a lost set.
@MainActor
@Observable
final class SessionViewModel {
    private let store: TrainingStore

    private(set) var session: Session
    private(set) var failure: String?

    /// The weight for the next set, seeded from the target and adjusted with
    /// the stepper. Held here rather than in the view so it survives the view
    /// being rebuilt as the day advances.
    var pendingLoad: Load
    var pendingReps: Int

    /// Pre-selected on the target so the common case — hit the target, log it —
    /// stays a single tap on the done button (#5).
    var pendingRPE: RPE

    /// The rest currently running, or nil between exercises. Wall-clock based,
    /// so it needs nothing running to stay correct across a backgrounding (#6).
    private(set) var rest: RestTimer?

    init(store: TrainingStore, session: Session) {
        self.store = store
        self.session = session
        let prescription = session.current?.prescription
        self.pendingLoad = prescription?.load ?? Load.zero
        self.pendingReps = prescription?.reps ?? 8
        self.pendingRPE = prescription?.rpe ?? .eight
        // Resuming a session that already has sets on it should pick up where
        // it left off, exactly as navigating back to a lift does.
        seedPendingFromCurrent()
    }

    var current: SessionExercise? { session.current }

    /// Position in the day, e.g. "3 of 7".
    var progressLabel: String {
        "\(session.currentIndex + 1) of \(session.exercises.count)"
    }

    // MARK: - Logging

    func logSet(isWarmup: Bool = false) {
        guard let current else { return }
        let record = SetRecord(
            exerciseID: current.exercise.id,
            load: pendingLoad,
            reps: pendingReps,
            // Warmups are never scored.
            rpe: isWarmup ? nil : pendingRPE,
            isWarmup: isWarmup,
            performedAt: Date()
        )

        do {
            try store.log(record)
            session.log(record)
            // Log, start resting, and be ready for the next set — one tap does
            // all three (#6). Warmups don't start a rest; ramping is continuous
            // and a countdown there is just noise.
            if !isWarmup {
                rest = RestTimer(
                    startedAt: record.performedAt,
                    duration: current.exercise.restTarget,
                    setID: record.id
                )
            }
        } catch {
            failure = "Couldn't save that set: \(error.localizedDescription)"
        }
    }

    /// Dismisses the rest clock without touching the logged set.
    func skipRest() {
        rest = nil
    }

    /// Removes the most recent set from both the session and disk. Backs #8.
    func undoLastSet() {
        guard let record = session.undoLastSet() else { return }
        do {
            try store.deleteSet(id: record.id)
            // A set that never happened can't be resting from. Only the rest
            // that *this* set started is cleared, so undoing an older mistake
            // mid-rest doesn't cancel the rest you're actually taking (#8).
            if rest?.setID == record.id {
                rest = nil
            }
        } catch {
            // Put it back rather than leaving screen and disk disagreeing.
            session.log(record)
            failure = "Couldn't undo that set: \(error.localizedDescription)"
        }
    }

    var canUndo: Bool { !session.allLoggedSets.isEmpty }

    // MARK: - Weight and reps

    /// Steps the weight by the exercise's real increment — 10 lb on dumbbells,
    /// 5 lb on a barbell — so the stepper can only produce loads the equipment
    /// can actually make.
    func adjustLoad(by steps: Int) {
        guard let increment = current?.exercise.increment.pounds else { return }
        let next = pendingLoad.pounds + Double(steps) * increment
        pendingLoad = Load(max(0, next))
    }

    func adjustReps(by delta: Int) {
        pendingReps = max(1, pendingReps + delta)
    }

    // MARK: - Navigation

    func advance() {
        session.advance()
        seedPendingFromCurrent()
    }

    func goBack() {
        session.goBack()
        seedPendingFromCurrent()
    }

    func select(exerciseID: UUID) {
        session.select(exerciseID: exerciseID)
        seedPendingFromCurrent()
    }

    /// Re-centres the input on the new exercise's target, using the last set
    /// already logged today if there is one — coming back to a lift mid-session
    /// should pick up where it left off, not reset to the target.
    private func seedPendingFromCurrent() {
        guard let current else { return }
        if let lastToday = current.loggedSets.last(where: { !$0.isWarmup }) {
            pendingLoad = lastToday.load
            pendingReps = lastToday.reps
        } else {
            pendingLoad = current.prescription.load ?? Load.zero
            pendingReps = current.prescription.reps
        }
        // RPE always resets to the target rather than carrying the last set's
        // value forward. Effort is the one field that genuinely differs set to
        // set, and inheriting a 9.5 from the previous set would quietly log
        // fatigue that hasn't happened yet.
        pendingRPE = current.prescription.rpe
    }

    /// The rep numbers offered on the row, centred on the target.
    ///
    /// The window is fixed to the target rather than following the selection,
    /// which would slide the row out from under a finger already reaching for
    /// it. It runs well past the top of the range so a genuinely good set never
    /// has to be rounded down to fit the UI.
    var repChoices: [Int] {
        guard let target = current?.prescription.reps else { return Array(1...20) }
        let lowest = max(1, target - 5)
        return Array(lowest...(target + 8))
    }

    func dismissFailure() { failure = nil }
}
