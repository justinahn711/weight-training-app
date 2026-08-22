import Foundation

/// What was said, once understood.
public enum VoiceCommand: Hashable, Sendable {

    /// A set, in whole or in part. Any field may be absent — "eight reps" says
    /// nothing about the weight, and the form keeps whatever is already there.
    case logSet(load: Load?, reps: Int?, rpe: RPE?)

    /// "add five", "drop ten" — relative to whatever is dialled in.
    case adjustLoad(by: Load)

    /// "same" — repeat the last set exactly.
    case repeatLast

    /// "next" — move to the next exercise.
    case nextExercise

    /// "two minute timer".
    case startTimer(seconds: TimeInterval)

    /// "note, left shoulder felt off".
    case note(String)
}

/// A parsed command and how sure we are.
public struct VoiceParse: Hashable, Sendable {
    public let command: VoiceCommand

    /// Low confidence means show it but never commit it on its own (#22).
    ///
    /// Set when the utterance was understood only partially — a number with no
    /// grammar around it, say. In a loud gym a half-heard phrase is common, and
    /// the cost of acting on one is a wrong set in the log.
    public let isConfident: Bool

    public init(command: VoiceCommand, isConfident: Bool = true) {
        self.command = command
        self.isConfident = isConfident
    }
}

/// A deliberately small closed grammar.
///
/// Small is the point. Open dictation in a gym transcribes clanging plates and
/// somebody else's conversation; a closed grammar can only produce commands
/// that exist, so noise fails to parse instead of logging something.
///
/// Nothing here reaches the store — parsing produces an intention, and #22's
/// snap-and-confirm decides whether it becomes a set.
public enum VoiceGrammar {

    /// Words that mean "reps" follow.
    private static let repMarkers: Set<String> = ["for", "times", "x", "by", "reps", "rep"]
    /// Words that mean an RPE follows.
    private static let rpeMarkers: Set<String> = ["at", "rpe", "@"]

    public static func parse(_ transcript: String) -> VoiceParse? {
        let words = tokenize(transcript)
        guard !words.isEmpty else { return nil }

        if let note = parseNote(words) { return note }
        if let simple = parseSimpleCommand(words) { return simple }
        if let timer = parseTimer(words) { return timer }
        if let adjust = parseAdjustment(words) { return adjust }
        return parseSet(words)
    }

    /// Reps a person actually performs. Beyond this it's a weight or a
    /// mishearing wearing a rep count's clothes.
    private static func plausibleReps(_ value: Double) -> Double? {
        (1...100).contains(value) ? value : nil
    }

    /// Near enough to the RPE scale to be a mishearing of it.
    ///
    /// Wider than the scale on purpose: "at twelve" is a misheard ten and
    /// should snap onto the grid, which is what `RPE(snapping:)` is for. But
    /// snapping exists to tidy 8.3, not to drag 185 down to a confident-looking
    /// 10 — so a number that plainly came from another field is refused rather
    /// than rounded into a plausible lie.
    private static func plausibleRPE(_ value: Double) -> Double? {
        (4...12).contains(value) ? value : nil
    }

    // MARK: - Tokenizing

    private static func tokenize(_ transcript: String) -> [String] {
        transcript
            .lowercased()
            .replacingOccurrences(of: "×", with: " x ")
            .replacingOccurrences(of: "@", with: " at ")
            .components(separatedBy: CharacterSet(charactersIn: " ,.-"))
            .filter { !$0.isEmpty }
    }

    // MARK: - Forms

    /// "note, left shoulder felt off" — everything after the marker is kept
    /// verbatim, since a note is the one place free text belongs.
    private static func parseNote(_ words: [String]) -> VoiceParse? {
        guard let marker = words.firstIndex(where: { $0 == "note" || $0 == "notes" }),
              marker == 0 else { return nil }
        let body = words.dropFirst().joined(separator: " ")
        guard !body.isEmpty else { return nil }
        return VoiceParse(command: .note(body))
    }

    private static func parseSimpleCommand(_ words: [String]) -> VoiceParse? {
        switch words.first {
        case "same", "again":
            return VoiceParse(command: .repeatLast)
        case "next", "skip":
            return VoiceParse(command: .nextExercise)
        default:
            return nil
        }
    }

    /// "two minute timer", "ninety second timer", "three minutes".
    private static func parseTimer(_ words: [String]) -> VoiceParse? {
        let mentionsTimer = words.contains("timer") || words.contains("rest")
        let unitIndex = words.firstIndex { $0.hasPrefix("minute") || $0.hasPrefix("second") }
        guard mentionsTimer || unitIndex != nil, let unitIndex else { return nil }

        guard let amount = SpokenNumber.parse(Array(words[..<unitIndex])) else { return nil }
        let seconds = words[unitIndex].hasPrefix("minute") ? amount * 60 : amount
        guard seconds > 0 else { return nil }
        return VoiceParse(command: .startTimer(seconds: seconds))
    }

    /// "add five", "drop ten", "up ten", "down five".
    private static func parseAdjustment(_ words: [String]) -> VoiceParse? {
        guard let first = words.first else { return nil }
        let direction: Double
        switch first {
        case "add", "up", "plus": direction = 1
        case "drop", "down", "minus", "less": direction = -1
        default: return nil
        }

        guard let amount = SpokenNumber.parse(Array(words.dropFirst())), amount > 0 else {
            return nil
        }
        return VoiceParse(command: .adjustLoad(by: Load(direction * amount)))
    }

    /// The main form: "one eighty five for five at eight", and its fragments.
    private static func parseSet(_ words: [String]) -> VoiceParse? {
        var load: Double?
        var reps: Double?
        var rpe: Double?

        // Walk the phrase, letting each marker say which field the *next*
        // number belongs to. Markers come in two shapes and both are used:
        // leading ("for five", "at eight") and trailing ("eight reps").
        enum Field { case load, reps, rpe }
        var expecting = Field.load
        var pending: [String] = []

        func flush(into field: Field) {
            guard !pending.isEmpty else { return }
            switch field {
            case .load: load = load ?? SpokenNumber.parse(pending)
            // Range-checked rather than accepted. A number that landed in the
            // wrong field is common — "8 reps at 185" put a weight where an
            // RPE goes — and absent is honest where invented is not. The
            // confirm step (#22) can only save you from what it shows you.
            case .reps: reps = reps ?? SpokenNumber.parse(pending).flatMap(plausibleReps)
            case .rpe:  rpe = rpe ?? SpokenNumber.parseWithHalf(pending).flatMap(plausibleRPE)
            }
            pending = []
        }

        for word in words {
            if word == "reps" || word == "rep" {
                // Trailing form: the number already said was the rep count.
                if !pending.isEmpty, reps == nil {
                    flush(into: .reps)
                } else {
                    expecting = .reps
                }
                continue
            }
            if repMarkers.contains(word) {
                flush(into: expecting)
                expecting = .reps
                continue
            }
            if rpeMarkers.contains(word) {
                flush(into: expecting)
                expecting = .rpe
                continue
            }
            pending.append(word)
        }
        flush(into: expecting)

        guard load != nil || reps != nil || rpe != nil else { return nil }

        // A bare number with no grammar around it is the ambiguous case: it
        // could be a weight, reps, or a misheard word. Shown, never committed.
        let isBare = words.count == 1 && load != nil

        return VoiceParse(
            command: .logSet(
                load: load.map { Load($0) },
                reps: reps.map { Int($0) },
                rpe: rpe.flatMap { RPE($0) ?? RPE(snapping: $0) }
            ),
            isConfident: !isBare
        )
    }
}
