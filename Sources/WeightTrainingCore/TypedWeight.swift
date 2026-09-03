import Foundation

/// A weight as it arrives from a keyboard (#99).
///
/// Some numbers are *read* rather than chosen. A machine's empty weight is on a
/// sticker, a plate or a scale before any control exists, so it gets typed in
/// whole instead of stepped towards. Typing means the field passes through
/// states that are not weights: empty for as long as the old value is being
/// cleared, `7.` on the way to `7.5`, and whatever a paste leaves behind.
///
/// This lives beside `Load` rather than in the view because "what counts as a
/// weight" is the same question `LoadIncrement`'s precondition answers, and
/// because a rule in Core is checked by the fast suite rather than by a person
/// standing at a rack.
public enum TypedWeight {

    /// The weight this text names, or nil when it does not name one.
    ///
    /// Nil is not zero, and the whole point is the difference. A caller that
    /// reads a failed parse as `0` has quietly recorded a hack squat sled that
    /// weighs nothing, and every plate total taken off it is then wrong by the
    /// sled — a number that is believed and loaded. Nil says "no new value",
    /// which leaves whatever was already there standing.
    ///
    /// Nil covers:
    ///
    /// - An empty or whitespace-only field. That is what clearing looks like on
    ///   every keystroke between the old value and the new one, so it has to
    ///   mean "not yet" rather than "nothing".
    /// - Text that is not a number.
    /// - Zero and negatives. A decimal pad types no minus sign but a paste
    ///   does, and nothing anybody weighs comes out at zero: an apparatus that
    ///   has not been weighed is a *nil* `baseWeight`, said with the toggle,
    ///   never a zero one.
    ///
    /// There is deliberately no upper bound. There is no weight a machine
    /// cannot be, and a ceiling invented here would eventually reject a real
    /// one — the failure would look like the app being broken, at the machine,
    /// with no way around it.
    public static func parse(_ text: String) -> Double? {
        // Trimmed at the ends, not stripped throughout. Collapsing internal
        // whitespace turns a pasted "4 5" into 45, and a space is a thousands
        // separator in several locales — so stripping it invents a number
        // rather than reading one.
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Digits and at most one separator, and nothing else.
        //
        // `Double(_:)` is strtod-backed, so without this it accepts "1e3" as
        // 1000, "0x10" as 16 and "+45" as 45. A decimal pad types none of
        // those, but this type's whole premise is that it sees "whatever a
        // paste leaves behind", and a sled that silently weighs 1000 is worse
        // than one the field refuses.
        let separators = cleaned.filter { $0 == "." || $0 == "," }
        guard separators.count <= 1,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," })
        else { return nil }

        // A separator followed by exactly three digits is ambiguous: "1,234"
        // is 1234 to a paste from a grouped number and 1.234 to a decimal
        // comma, and nothing in the string says which. Refused rather than
        // guessed — 1.234 kg is not a weight anybody measured, and the guess
        // that produced it would be believed. "Unknown means silent" applies
        // to input as much as to output.
        if let separator = cleaned.firstIndex(where: { $0 == "." || $0 == "," }) {
            let fraction = cleaned[cleaned.index(after: separator)...]
            if fraction.count == 3 && fraction.allSatisfy(\.isNumber) { return nil }
        }

        guard let value = Double(cleaned.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0
        else { return nil }
        return value
    }
}
