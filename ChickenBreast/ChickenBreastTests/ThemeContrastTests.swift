//
//  ThemeContrastTests.swift
//  ChickenBreastTests
//

import SwiftUI
import UIKit
import XCTest
@testable import ChickenBreast

/// The hero's fill/text pairs, measured rather than eyeballed. The warmup
/// hero shipped as white on `.secondary` at about 2.8:1 because nothing
/// computed it (critique, 2026-10-06), and the system audit never runs on a
/// warmup rung; this pins both of Log Set's pairs above the 4.5:1 body-text
/// floor, stricter than the 3:1 its large text strictly needs.
final class ThemeContrastTests: XCTestCase {

    /// The accent read from its asset, in the dark appearance the app is
    /// forced into; SwiftUI's `Color.accentColor` doesn't resolve to it here.
    private let accent = UIColor(named: "AccentColor")!

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testLogSetTextClearsBodyContrastOnBothFills() {
        XCTAssertGreaterThanOrEqual(contrast(UIColor(Theme.onAccent), accent), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(UIColor(Theme.onAccent), UIColor(Theme.warmupFill)), 4.5)
    }

    /// The warmup hero is the same control with the hue taken out, not a
    /// lesser one: its fill should weigh what the accent does.
    func testWarmupFillMatchesTheAccentsLightness() {
        XCTAssertEqual(luminance(UIColor(Theme.warmupFill)), luminance(accent), accuracy: 0.03)
    }
}
