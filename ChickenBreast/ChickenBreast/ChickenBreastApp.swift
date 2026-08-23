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
