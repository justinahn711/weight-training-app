import Foundation

/// Turns spoken numbers into numbers.
///
/// Lifters say weights the short way — "one eighty five", not "one hundred and
/// eighty five" — and a recogniser transcribes exactly that. Without this,
/// every useful utterance in a gym fails to parse.
enum SpokenNumber {

    private static let units: [String: Double] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Parses a run of number words or digits.
    ///
    /// Handles the gym shorthand where a leading single digit means hundreds:
    /// "two twenty five" is 225, not 2-20-5. The rule is that a single digit
    /// followed by anything twenty or above is a hundreds count — which is
    /// exactly how plate weights get said out loud.
    ///
    /// A half is part of the number wherever it's said — "eight and a half",
    /// "eight point five", "sixty two point five", "two and a half" (#264).
    /// Loads, adjustments and RPE all read numbers the same way, so a half
    /// can't survive in one field and vanish in another.
    ///
    /// - Returns: nil when the words contain no number at all.
    static func parse(_ words: [String]) -> Double? {
        read(words)?.value
    }

    /// A number read from the front of a run of words, and where it stopped.
    struct Reading: Equatable {
        let value: Double
        /// The index of the first word the number did not use.
        let end: Int
    }

    static func read(_ words: [String]) -> Reading? {
        var total: Double?
        // Skip anything before the first number rather than giving up at it.
        // A leading word is fatal otherwise — "log 185" parsed as nothing at
        // all, losing the weight, while the trailing "185 pounds" was fine.
        // People say "log", "okay", "set", and recognisers prepend strays.
        var index = words.firstIndex { single($0) != nil } ?? words.count

        while index < words.count {
            let word = words[index]

            // "and a half" ends the number: "eight and a half" -> 8.5.
            if let whole = total, isAndAHalf(words, at: index) {
                total = whole + 0.5
                index += 3
                break
            }

            // "and" is noise inside a number: "two hundred and twenty five".
            if word == "and", total != nil {
                index += 1
                continue
            }

            guard let value = single(word) else { break }

            if word == "hundred" || word == "thousand" {
                // Scales whatever came before: "two hundred" -> 200.
                total = (total ?? 1) * (word == "hundred" ? 100 : 1_000)
                index += 1
                continue
            }

            if let running = total {
                // A transcribed numeral after a complete number is a separate
                // number, not more of this one: "185 8 8" is a weight and two
                // other things, never 201. The exception is hundreds shorthand
                // — "one 85" is 185 — which shows up as a round hundred with a
                // smaller numeral behind it.
                let isDigits = Double(word) != nil
                let isHundredsShorthand = running.truncatingRemainder(dividingBy: 100) == 0
                    && value < 100
                if isDigits && !isHundredsShorthand { break }
                total = running + value
            } else if value < 10,
                      index + 1 < words.count,
                      let next = single(words[index + 1]),
                      next >= 10 {
                // A leading digit before a larger part is a hundreds count:
                // "three fifteen" is 315, and "one fifteen" is 115. The
                // threshold is ten rather than twenty so the teens are covered,
                // which is where most bar weights land.
                total = words[index + 1] == "hundred" || words[index + 1] == "thousand"
                    ? value
                    : value * 100
            } else {
                total = value
            }
            index += 1
        }

        guard var value = total else { return nil }

        // "eight point five", "sixty two point five". One digit after the
        // point is all anyone says; "point eight" off the RPE grid still
        // snaps later, which is what "seven point eight" relies on.
        if index + 1 < words.count, words[index] == "point",
           let tenth = single(words[index + 1]), (0...9).contains(tenth),
           tenth == tenth.rounded() {
            value += tenth / 10
            index += 2
        } else if index < words.count, words[index] == "half" {
            // "eight half" — the "and a" swallowed by the room.
            value += 0.5
            index += 1
        }

        return Reading(value: value, end: index)
    }

    private static func isAndAHalf(_ words: [String], at index: Int) -> Bool {
        index + 2 < words.count
            && words[index] == "and" && words[index + 1] == "a" && words[index + 2] == "half"
    }

    /// A single token's numeric value, if it has one.
    static func single(_ word: String) -> Double? {
        if let digits = Double(word), digits.isFinite { return digits }
        if word == "hundred" { return 100 }
        if word == "thousand" { return 1_000 }
        return units[word] ?? tens[word]
    }
}
