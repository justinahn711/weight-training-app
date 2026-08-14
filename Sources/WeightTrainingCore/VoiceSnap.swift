import Foundation

/// A heard command, made safe to show.
///
/// Every value here has already been snapped to something the equipment can
/// produce and checked for plausibility. What's left is either loadable or
/// absent — there is no third state where a number reaches the form unchecked.
public struct SnappedInput: Hashable, Sendable {
    public let load: Load?
    public let reps: Int?
    public let rpe: RPE?

    /// Values that were thrown out, with the reason, so the screen can say what
    /// it ignored instead of silently dropping half an utterance.
    public let rejections: [String]

    /// Whether a value was quietly moved to fit the equipment — 187 heard on a
    /// barbell becomes 185, which is worth a glance before it commits.
    public let wasSnapped: Bool

    /// Whether the recogniser was sure enough to act without confirmation.
    public let isConfident: Bool

    public init(
        load: Load?, reps: Int?, rpe: RPE?,
        rejections: [String] = [], wasSnapped: Bool = false, isConfident: Bool = true
    ) {
        self.load = load
        self.reps = reps
        self.rpe = rpe
        self.rejections = rejections
        self.wasSnapped = wasSnapped
        self.isConfident = isConfident
    }

    public var isEmpty: Bool { load == nil && reps == nil && rpe == nil }

    /// Whether this may commit on its own after the countdown.
    ///
    /// Auto-commit is the whole convenience of voice, and also the whole risk.
    /// It's allowed only when the recogniser was confident, nothing was thrown
    /// out, and nothing needed moving to fit the bar. Anything else waits for a
    /// tap.
    public var canAutoCommit: Bool {
        isConfident && rejections.isEmpty && !wasSnapped && !isEmpty
    }
}

/// Makes heard values safe before they reach the form.
///
/// Voice fills the form; it never writes. This is the guard that makes that
/// promise keepable — a garbled "one eighty" transcribed as "one thousand
/// eighty" has to be refused here, because by the time it's a number in a text
/// field it looks exactly like a deliberate one.
public enum VoiceSnapper {

    /// Reps a human might actually perform.
    ///
    /// Thirty is generous — nobody logs a set of 60, and a recogniser that
    /// hears one has misheard something.
    public static let plausibleReps = 1...30

    /// How far a heard weight may sit from the weight already dialled in.
    ///
    /// The guard that catches an order-of-magnitude mis-hear. Doubling is a
    /// stretch but conceivable when switching exercises mid-utterance; ten
    /// times is never a real set.
    public static let plausibleLoadRatio = 0.4...2.0

    /// Absolute ceiling when there's nothing to compare against.
    public static let plausibleLoadCeiling = Load(1_000)

    /// - Parameters:
    ///   - reference: the weight currently dialled in, used to judge whether a
    ///     heard weight is plausible. Nil on a cold start, where only the
    ///     absolute ceiling applies.
    public static func snap(
        _ parse: VoiceParse,
        for exercise: Exercise,
        reference: Load?
    ) -> SnappedInput? {
        guard case .logSet(let heardLoad, let heardReps, let heardRPE) = parse.command else {
            return nil
        }

        var rejections: [String] = []
        var wasSnapped = false

        var load: Load?
        if let heardLoad {
            let snapped = exercise.nearestAchievable(heardLoad)
            if !isPlausible(snapped, reference: reference, exercise: exercise) {
                rejections.append("\(heardLoad) doesn't look right")
            } else {
                load = snapped
                wasSnapped = wasSnapped || snapped != heardLoad
            }
        }

        var reps: Int?
        if let heardReps {
            if plausibleReps.contains(heardReps) {
                reps = heardReps
            } else {
                rejections.append("\(heardReps) reps doesn't look right")
            }
        }

        // RPE needs no plausibility check: the type only permits 6 to 10 in
        // halves, so an impossible value never becomes an RPE in the first
        // place. This is the payoff for making it a failable type back in #1
        // rather than a Double.
        let rpe = heardRPE

        let snappedInput = SnappedInput(
            load: load, reps: reps, rpe: rpe,
            rejections: rejections,
            wasSnapped: wasSnapped,
            isConfident: parse.isConfident
        )
        return snappedInput.isEmpty && rejections.isEmpty ? nil : snappedInput
    }

    /// Whether a weight is believable for this lift right now.
    private static func isPlausible(
        _ load: Load,
        reference: Load?,
        exercise: Exercise
    ) -> Bool {
        guard load >= exercise.minimumLoad, load.pounds > 0 else { return false }
        guard load <= plausibleLoadCeiling else { return false }

        guard let reference, reference.pounds > 0 else { return true }
        let ratio = load.pounds / reference.pounds
        return plausibleLoadRatio.contains(ratio)
    }
}
