//
//  SessionLiveActivity.swift
//  ChickenBreastWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

/// The session on the lock screen and in the Dynamic Island (#23).
///
/// Read at a glance, one-handed, by someone mid-set with a phone on a bench —
/// the same constraint as the session screen, with less room. So it answers
/// only the two questions asked between sets: how long is left, and what am I
/// lifting next.
///
/// The countdown is rendered from `restEndsAt` with `Text(timerInterval:)`,
/// which the system ticks locally. The app sends no per-second updates; it only
/// pushes when the facts change.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(state: context.state, dayKind: context.attributes.dayKind)
                .padding()
                .activityBackgroundTint(.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exerciseName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.targetLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RestReadout(endsAt: context.state.restEndsAt, font: .title2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(setsLine(context.state.setsLogged))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
            } compactTrailing: {
                RestReadout(endsAt: context.state.restEndsAt, font: .caption2)
            } minimal: {
                Image(systemName: "figure.strengthtraining.traditional")
            }
        }
    }

    /// Sets done, with no denominator — the app prescribes a target, never a
    /// number of sets.
    private func setsLine(_ count: Int) -> String {
        count == 1 ? "1 set logged" : "\(count) sets logged"
    }
}

/// The rest clock, or nothing at all.
///
/// Resting is the only state with a number worth showing; between exercises
/// there is no countdown to render and a zeroed timer would read as a rest
/// that just ended.
private struct RestReadout: View {
    let endsAt: Date?
    let font: Font

    var body: some View {
        if let endsAt {
            Text(timerInterval: Date.now...endsAt, countsDown: true)
                .font(font.monospacedDigit())
                .multilineTextAlignment(.trailing)
                // Fixed so the digits don't reflow the layout every second as
                // the numbers change width.
                .frame(minWidth: 44, alignment: .trailing)
        } else {
            Image(systemName: "dumbbell.fill")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LockScreenView: View {
    let state: SessionActivityAttributes.ContentState
    let dayKind: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dayKind.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.exerciseName)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(state.targetLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                RestReadout(endsAt: state.restEndsAt, font: .largeTitle)
                Text(state.isResting ? "resting" : "ready")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
