//
//  Theme.swift
//  ChickenBreast
//

import SwiftUI

/// The few colours and motions that mean something, named once.
///
/// The app is dark, always: a gym is bright overhead and the phone is on a
/// bench or the floor, and a white screen at that angle is glare. Everything
/// ordinary is a shade of grey on near-black; colour is reserved for the
/// moments worth noticing — a record, a set done, a rest over, a ring
/// closing — so that when it appears it is read as news rather than décor.
enum Theme {

    /// Near-black rather than pure black. On an OLED panel pure black makes
    /// every card float as a cut-out; a shade above it keeps the cards on a
    /// surface.
    static let background = Color(red: 0.045, green: 0.045, blue: 0.05)

    /// A personal record. Gold, used for nothing else, so a flash of it
    /// mid-session can only mean one thing.
    static let record = Color(red: 1.0, green: 0.8, blue: 0.24)

    /// Text set on `record`. Fixed black rather than a semantic label color:
    /// `record` is itself a fixed brand color, not a system one, so there is
    /// no adaptive counterpart to derive a matching text color from — and
    /// black clears contrast against this particular gold by a wide margin.
    /// Named here rather than left as a bare `.black` at the call site, so
    /// it reads as a decision, not an oversight.
    static let recordText = Color.black

    /// Text on the accent fill (Log Set, the forward action's glyph).
    ///
    /// White on this orange measured 2.53:1 in a critique pass, failing
    /// even the 3:1 large-text floor on the most-read button in the app.
    /// Near-black on the same orange clears 7:1. Same reasoning as
    /// `recordText`: a fixed brand fill has no adaptive counterpart to
    /// derive its text from, so the pairing is named here once.
    static let onAccent = Color(red: 0.07, green: 0.06, blue: 0.05)

    /// Tint for secondary controls — Undo, Skip, Stay, Go back.
    ///
    /// Orange is reserved for the one action the screen exists for and the
    /// rest ring. When it painted every button it stopped meaning anything
    /// (a critique found it on eight controls at once); a neutral tint keeps
    /// these legible without competing with Log Set.
    static let quietTint = Color.primary

    /// A set logged, a rest complete: the thing you were doing is done.
    static let done = Color.green

    /// Something is behind and worth a look — a muscle under its weekly band.
    ///
    /// Not the accent: "there is a hole in your week" and "this is the button
    /// to press" are different messages, and the dashboard used one orange for
    /// both. Never the only cue; every use pairs it with a glyph and a
    /// sentence. Measures 7.0:1 on the app's background.
    static let attention = Color(red: 1.0, green: 0.42, blue: 0.35)

    /// The three colours that stand for *which kind of thing*, not for news:
    /// day kinds on the History calendar, rings on Progress. Cool, because
    /// every warm hue in this file already means something that just
    /// happened — a record, a finished set, an action to take.
    ///
    /// Validated rather than eyeballed, against this app's dark surface
    /// (`dataviz`'s checker): all three inside the dark lightness band, all
    /// above 3:1 on the background, normal-vision separation ΔE 21. Their
    /// worst colourblind pair (blue against magenta, ΔE 7.1 deutan) sits in
    /// the band that is only legal beside a label — which is why both places
    /// that use these keep their text labels, and the calendar keeps its
    /// day-kind letter.
    static let categories: [Color] = [
        Color(red: 0.231, green: 0.510, blue: 0.965),
        Color(red: 0.753, green: 0.290, blue: 0.847),
        Color(red: 0.059, green: 0.663, blue: 0.549),
    ]

    /// Text on a `categories` fill. Dark for the same reason `recordText` is:
    /// white measured 2.97:1 on the teal, failing a calendar's small digits.
    static let onCategory = Color(red: 0.07, green: 0.06, blue: 0.05)

    /// The one spring for state that moves on screen — a banner arriving,
    /// an exercise changing, a card leaving. Bouncy enough to feel like a
    /// thing landed, short enough that the next tap never waits on it.
    private static let fullSpring = Animation.spring(duration: 0.45, bounce: 0.22)

    /// A number changing under a thumb: quicker, less bounce.
    private static let fullQuick = Animation.spring(duration: 0.28, bounce: 0.12)

    /// Reduce Motion's answer to both of the above. Not `.none` and not an
    /// instant cut — a platform audit named a `0.01ms` kill as much a defect
    /// as unchecked motion, because it drops the state change the animation
    /// was carrying rather than just its bounce. State still visibly moves;
    /// it just eases rather than springs, and nothing slides in from an edge.
    private static let reducedSpring = Animation.easeOut(duration: 0.2)
    private static let reducedQuick = Animation.easeOut(duration: 0.15)

    /// Every call site takes `reduceMotion` from its own
    /// `@Environment(\.accessibilityReduceMotion)` rather than reaching for a
    /// bare constant — a function signature that requires the argument is
    /// what keeps a new call site from silently reintroducing the gap the
    /// audit found in this file's first version, the way a second bare
    /// constant sitting next to this one could not.
    static func spring(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedSpring : fullSpring
    }

    static func quick(reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedQuick : fullQuick
    }

    /// How a banner or disclosure arrives: sliding down from the edge it
    /// belongs to, or — under Reduce Motion — simply fading in place. The
    /// first Reduce Motion pass covered the springs but left these slides
    /// hard-coded at five call sites; routing them through one function is
    /// what keeps the next banner from repeating that.
    static func edgeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}
