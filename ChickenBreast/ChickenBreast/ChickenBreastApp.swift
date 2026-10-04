//
//  ChickenBreastApp.swift
//  ChickenBreast
//
//  Created by Justin Ahn on 8/13/26.
//

import SwiftUI

@main
struct ChickenBreastApp: App {

    init() {
        // Before anything reads them, so the first launch behaves like the
        // Settings screen says it will rather than like an empty defaults
        // store — `bool(forKey:)` answers false for a key nobody wrote.
        RestAlertSettings.registerDefaults()

        // Without this the rest alert is discarded whenever the session is on
        // screen. See `NotificationPresenter`.
        NotificationPresenter.install()

        #if DEBUG
        // Before the store opens or a session can start (#285).
        UITestLaunchState.clearProcessStateIfResetting()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Dark, always — see `Theme`.
                .preferredColorScheme(.dark)
                #if DEBUG
                .modifier(UITestIsolationMarker())
                #endif
        }
    }
}

#if DEBUG
/// Proof, for a UI test, that this process opened the isolated store (#321).
///
/// The launch arguments alone aren't proof: iOS can start the app without
/// them (prewarming a fresh install, or a background launch for a Live
/// Activity), and `XCUIApplication.launch()` sometimes adopts that process
/// instead of starting its own. That test then ran against the real store.
/// `ChickenBreastUITestCase.launch` waits for this identifier and refuses
/// to go on without it. A container, so it adds nothing to tap or audit.
private struct UITestIsolationMarker: ViewModifier {
    func body(content: Content) -> some View {
        if UITestLaunchState.usesIsolatedStore {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(UITestLaunchState.isolationMarker)
        } else {
            content
        }
    }
}
#endif
