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
    /// - Returns: nil when the words contain no number at all.
    static func parse(_ words: [String]) -> Double? {
        var total: Double?
        // Skip anything before the first number rather than giving up at it.
        // A leading word is fatal otherwise — "log 185" parsed as nothing at
        // all, losing the weight, while the trailing "185 pounds" was fine.
        // People say "log", "okay", "set", and recognisers prepend strays.
        var index = words.firstIndex { single($0) != nil } ?? words.count

        while index < words.count {
            let word = words[index]

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

        return total
    }

    /// A single token's numeric value, if it has one.
    static func single(_ word: String) -> Double? {
        if let digits = Double(word) { return digits }
        if word == "hundred" { return 100 }
        if word == "thousand" { return 1_000 }
        return units[word] ?? tens[word]
    }

    /// Parses a number that may carry a half — "eight and a half", "eight
    /// point five", "eight five" after an "at".
    static func parseWithHalf(_ words: [String]) -> Double? {
        // "eight point five"
        if let pointIndex = words.firstIndex(of: "point"),
           let whole = parse(Array(words[..<pointIndex])),
           let fraction = parse(Array(words[(pointIndex + 1)...])) {
            return whole + (fraction == 5 ? 0.5 : fraction / 10)
        }

        // "eight and a half"
        if let andIndex = words.firstIndex(of: "and"),
           Array(words.suffix(from: min(andIndex + 1, words.count)).prefix(2)) == ["a", "half"],
           let whole = parse(Array(words[..<andIndex])) {
            return whole + 0.5
        }

        if words.last == "half", words.count >= 2,
           let whole = parse(Array(words.dropLast())) {
            return whole + 0.5
        }

        return parse(words)
    }
}
