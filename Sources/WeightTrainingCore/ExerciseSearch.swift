import Foundation

/// Finding the lift you want to swap to, mid-session, one-handed.
///
/// Two paths, both ending in one tap: the slot's own candidates ranked by
/// staleness, and a fuzzy search across the whole library for everything else.
/// Neither can create an exercise — a lift invented at the rack has no history,
/// no increment, and no muscle tags, and it pollutes volume tracking forever.
/// New exercises are a considered decision, not a mid-set one.
public enum ExerciseSearch {

    /// Orders candidates stalest first.
    ///
    /// Staleness rather than alphabetical because the question being asked at
    /// the rack is "what haven't I done in a while", and a lift never performed
    /// is the stalest thing there is — it sorts to the top rather than being
    /// buried under lifts with recent dates.
    public static func rankedByStaleness(
        _ exercises: [Exercise],
        lastPerformed: [UUID: Date]
    ) -> [Exercise] {
        exercises.sorted { first, second in
            switch (lastPerformed[first.id], lastPerformed[second.id]) {
            case (nil, nil):
                return first.name < second.name
            case (nil, _):
                return true
            case (_, nil):
                return false
            case (let a?, let b?):
                return a == b ? first.name < second.name : a < b
            }
        }
    }

    /// Fuzzy name search, best match first.
    ///
    /// Matching is subsequence-based so partial and abbreviated typing works —
    /// "incdb" finds "Incline DB Press" — which matters when this is being
    /// typed with one hand between sets.
    ///
    /// An empty query returns everything, so the field can be shown already
    /// populated rather than empty and unhelpful.
    public static func search(_ query: String, in exercises: [Exercise]) -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return exercises.sorted { $0.name < $1.name } }

        return exercises
            .compactMap { exercise -> (exercise: Exercise, score: Int)? in
                guard let score = score(query: trimmed, name: exercise.name) else { return nil }
                return (exercise, score)
            }
            .sorted { first, second in
                first.score == second.score
                    ? first.exercise.name < second.exercise.name
                    : first.score > second.score
            }
            .map(\.exercise)
    }

    /// Higher is better; nil means no match.
    ///
    /// The tiers matter more than the exact numbers: an exact or prefix match
    /// must beat a word-start match, which must beat a scattered subsequence,
    /// so the thing you obviously meant is the thing sitting under your thumb.
    static func score(query: String, name: String) -> Int? {
        let needle = query.lowercased()
        let haystack = name.lowercased()

        if haystack == needle { return 1_000 }
        if haystack.hasPrefix(needle) { return 900 }

        // A match at the start of any word — "press" in "Incline DB Press".
        let words = haystack.split(separator: " ")
        if words.contains(where: { $0.hasPrefix(needle) }) { return 800 }
        if haystack.contains(needle) { return 700 }

        // Initials: "idp" for "Incline DB Press".
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(needle) { return 600 }

        return subsequenceScore(needle: needle, haystack: haystack)
    }

    /// Scores a scattered subsequence match, favouring characters that landed
    /// close together — "incpress" should beat a match whose letters are strewn
    /// across the whole name.
    private static func subsequenceScore(needle: String, haystack: String) -> Int? {
        var haystackIndex = haystack.startIndex
        var gaps = 0
        var lastMatch: String.Index?

        for character in needle {
            guard let found = haystack[haystackIndex...].firstIndex(of: character) else {
                return nil
            }
            if let last = lastMatch {
                gaps += haystack.distance(from: last, to: found) - 1
            }
            lastMatch = found
            haystackIndex = haystack.index(after: found)
        }

        return max(1, 500 - gaps * 10)
    }
}
