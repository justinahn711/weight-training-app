//
//  ChickenBreastWidgetsBundle.swift
//  ChickenBreastWidgets
//

import SwiftUI
import WidgetKit

/// #23 asks for a session on the lock screen, not a home-screen widget, so the
/// Live Activity is the only thing here. The template's placeholder widget was
/// removed rather than left showing an empty square.
@main
struct ChickenBreastWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}
