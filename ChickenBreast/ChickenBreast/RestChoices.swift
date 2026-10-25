import Foundation

/// The rest times the app offers, in one place so the two screens that ask
/// about rest cannot drift apart (#341).
///
/// Lift settings sets one lift's own rest (#174); Settings sets the defaults
/// every lift without its own rest follows. The lifter is picking from the same
/// list in both, and the same value reads the same way in both.
///
/// `nonisolated`: pure values and a pure function, handed to `ChoiceRow` as a
/// plain closure, which the project's default main-actor isolation would
/// otherwise warn about.
nonisolated enum RestChoices {
    /// Half-minute steps from one to five minutes: the range the defaults live
    /// in (1:00 and 3:00 out of the box), with room either side for a lift that
    /// genuinely needs more or less.
    static let values: [Double] = [60, 90, 120, 150, 180, 210, 240, 300]

    /// "3m", "1m 30s". Under a minute reads as seconds alone rather than "0m".
    static func label(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }
}
