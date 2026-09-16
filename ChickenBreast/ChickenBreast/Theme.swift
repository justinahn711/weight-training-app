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

    /// A set logged, a rest complete: the thing you were doing is done.
    static let done = Color.green

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
}
