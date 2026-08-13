import Foundation

/// A proposal shown *beside* the number, never as it.
///
/// The distinction is the whole design. A suggestion that writes itself into
/// the weight field is a decision the app made on your behalf and that you have
/// to notice and undo; a suggestion sitting next to the field is a second
/// opinion you can ignore. Everything here is inert until tapped.
public struct Suggestion: Identifiable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// Change the weight for the next set.
        case load(Load)
        /// Change the rep goal for the next set.
        case reps(Int)
        /// Back the weight off and rebuild.
        case deload(Load)
        /// Train something else in this slot.
        ///
        /// No producer yet: choosing an alternative needs the slot candidates
        /// that arrive with day templates (#16) and the swap UI in #18.
        case swap(exerciseID: UUID, name: String)
    }

    public let kind: Kind

    /// Why this is being suggested, in the words it's shown in.
    ///
    /// Not optional, because a chip that can't explain itself is just a number
    /// to argue with. "+10" invites a shrug; "set 1 was RPE 6.5" is a coach.
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    /// Stable across regeneration, so dismissing a chip keeps it dismissed
    /// even though the list is recomputed after every logged set.
    public var id: String {
        switch kind {
        case .load(let load):       return "load-\(load.pounds)"
        case .reps(let reps):       return "reps-\(reps)"
        case .deload(let load):     return "deload-\(load.pounds)"
        case .swap(let id, _):      return "swap-\(id)"
        }
    }

    /// The headline — what would change.
    public var title: String {
        switch kind {
        case .load(let load):   return load.description
        case .reps(let reps):   return "\(reps) reps"
        case .deload(let load): return "Deload to \(load)"
        case .swap(_, let name): return "Swap to \(name)"
        }
    }
}

/// Produces the chips for the current moment in a session.
///
/// Pure: it reads what has happened and returns proposals. It cannot change a
/// target, log a set, or move the weight — which is what makes rule one
/// ("the done button always commits exactly what is displayed") a property of
/// the design rather than a promise to be careful.
public enum SuggestionEngine {

    /// How far below target RPE a set has to land before more weight is
    /// proposed.
    ///
    /// A full point. Half a point is inside the noise of a subjective rating,
    /// and a chip that fires on noise gets dismissed reflexively — at which
    /// point the ones that matter are being dismissed reflexively too.
    static let rpeSlack = 1.0

    /// At most two chips at once.
    ///
    /// Three proposals beside one number is a menu, and reading a menu between
    /// sets is exactly the work this app exists to remove.
    static let maximumChips = 2

    public static func suggestions(
        exercise: Exercise,
        prescription: Prescription,
        loggedToday: [SetRecord],
        state: ProgressState,
        history: [SetRecord],
        pendingLoad: Load,
        pendingReps: Int,
        calendar: Calendar = .current
    ) -> [Suggestion] {
        var chips: [Suggestion] = []

        // Deload first: if the lift is stalling, nothing else worth proposing.
        if let deload = DeloadDetector.evaluate(
            exercise: exercise, state: state, history: history, calendar: calendar
        ), deload.to != pendingLoad {
            chips.append(Suggestion(kind: .deload(deload.to), reason: deload.summary))
        }

        let workingToday = loggedToday.filter { !$0.isWarmup }

        if let last = workingToday.last, let rpe = last.rpe {
            let target = prescription.rpe
            let setNumber = workingToday.count

            if rpe.value <= target.value - rpeSlack {
                // Easier than intended, and the weight on the stepper hasn't
                // already been moved up in response.
                let proposed = exercise.achievableTarget(
                    echoing: Load(pendingLoad.pounds + exercise.increment.pounds)
                )
                if proposed > pendingLoad {
                    chips.append(Suggestion(
                        kind: .load(proposed),
                        reason: "set \(setNumber) was \(rpe)"
                    ))
                }
            } else if rpe.value >= target.value + rpeSlack {
                let proposed = exercise.achievableTarget(
                    echoing: Load(pendingLoad.pounds - exercise.increment.pounds)
                )
                if proposed < pendingLoad {
                    chips.append(Suggestion(
                        kind: .load(proposed),
                        reason: "set \(setNumber) was \(rpe)"
                    ))
                }
            }
        }

        // Rep goal, only when the weight isn't already being argued about.
        // Two chips proposing different things about the same set is a puzzle.
        if chips.isEmpty, workingToday.isEmpty, let target = state.targetReps,
           target != pendingReps, prescription.load == pendingLoad {
            chips.append(Suggestion(
                kind: .reps(target),
                reason: "your target this session"
            ))
        }

        return Array(chips.prefix(maximumChips))
    }
}
