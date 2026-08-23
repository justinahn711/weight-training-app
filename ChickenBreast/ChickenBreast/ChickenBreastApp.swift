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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
