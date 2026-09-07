import Foundation

/// A rep count as it arrives from a keyboard (#131).
///
/// The quick choices around a target cover ordinary sets. This parser backs the
/// escape hatch for an actual set that falls outside that window, where the
/// number must be accepted exactly or refused explicitly — never clamped back
/// into the convenient range.
public enum TypedReps {

    /// The positive whole number this text names, or nil when it does not name
    /// a rep count.
    ///
    /// There is deliberately no upper bound. The target-centered chips are a
    /// convenience rather than a validity rule, and an invented ceiling would
    /// create another real count that the manual controls cannot record.
    public static func parse(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.allSatisfy(\.isNumber),
              let reps = Int(cleaned),
              reps > 0
        else { return nil }
        return reps
    }
}
