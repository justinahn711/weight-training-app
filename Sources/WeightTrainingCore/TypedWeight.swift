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
        // A decimal pad prints the *locale's* separator, so a comma typed into
        // one is a decimal point rather than a thousands mark — that key is the
        // only separator the pad offers.
        let cleaned = text
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: ",", with: ".")

        guard let value = Double(cleaned), value.isFinite, value > 0 else {
            return nil
        }
        return value
    }
}
