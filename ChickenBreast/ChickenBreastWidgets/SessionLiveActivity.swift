//
//  SessionLiveActivity.swift
//  ChickenBreastWidgets
//

import ActivityKit
import AppIntents
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
            VStack(spacing: 12) {
                LockScreenView(
                    state: context.state,
                    dayKind: context.attributes.dayKind,
                    isStale: context.isStale
                )
                SessionButtons(
                    state: context.state,
                    workoutID: context.attributes.workoutID,
                    isStale: context.isStale
                )
            }
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
                    RestReadout(
                        endsAt: context.state.restEndsAt,
                        isStale: context.isStale,
                        font: .title2
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(setsLine(context.state.setsLogged))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SessionButtons(
                            state: context.state,
                            workoutID: context.attributes.workoutID,
                            isStale: context.isStale
                        )
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional")
            } compactTrailing: {
                RestReadout(
                    endsAt: context.state.restEndsAt,
                    isStale: context.isStale,
                    font: .caption2
                )
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


/// The lock-screen controls (#23).
///
/// Two, deliberately. The done-when is a full exercise logged without unlocking
/// the phone, which needs exactly "log the set I was told to do" and "I'm done
/// resting" — anything more is a form, and a form is what unlocking is for.
///
/// These are `LiveActivityIntent`s, so tapping them runs the work in the app's
/// process without unlocking or foregrounding anything.
private struct SessionButtons: View {
    let state: SessionActivityAttributes.ContentState
    let workoutID: String?
    let isStale: Bool

    private var isActivelyResting: Bool {
        state.isResting && !isStale
    }

    var body: some View {
        HStack(spacing: 8) {
            if !isActivelyResting,
               state.canLogTarget,
               let pounds = state.targetPounds,
               let workoutID,
               let actionID = state.logActionID {
                Button(intent: LogTargetSetIntent(
                    exerciseID: state.exerciseID,
                    pounds: pounds,
                    reps: state.targetReps,
                    rpe: state.targetRPE,
                    workoutID: workoutID,
                    actionID: actionID
                )) {
                    Label("Log \(state.targetLine)", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !isActivelyResting {
                // A first-ever lift has no target, so there is nothing this
                // button could honestly log.
                Text("Open the app to log the first set")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            if isActivelyResting, let workoutID {
                if let setID = state.lastLoggedSetID {
                    Button(intent: UndoLiveSetIntent(workoutID: workoutID, setID: setID)) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Button(intent: SkipRestIntent(workoutID: workoutID)) {
                    Label("Skip", systemImage: "forward.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// The rest clock, or nothing at all.
///
/// Resting is the only state with a number worth showing; between exercises
/// there is no countdown to render and a zeroed timer would read as a rest
/// that just ended.
private struct RestReadout: View {
    let endsAt: Date?
    /// True once the content has passed its `staleDate`, which the controller
    /// sets to the moment rest ends. WidgetKit re-renders then, which is the
    /// only way this view learns that time has passed — the app pushes updates
    /// when the facts change, and rest finishing is not something anyone does.
    let isStale: Bool
    let font: Font

    var body: some View {
        if let endsAt {
            if isStale {
                // Counting up, not frozen at zero. Rest running long is
                // information — it's the first sign a session is dragging — and
                // a stopped clock reading 0:00 is indistinguishable from a rest
                // that just started.
                Text(timerInterval: endsAt...(endsAt + 3600), countsDown: false)
                    .font(font.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 44, alignment: .trailing)
            } else {
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .font(font.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    // Fixed so the digits don't reflow the layout every second
                    // as the numbers change width.
                    .frame(minWidth: 44, alignment: .trailing)
            }
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
    let isStale: Bool

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
                RestReadout(endsAt: state.restEndsAt, isStale: isStale, font: .largeTitle)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Says which clock is being read, since a countdown and an overrun look
    /// alike at a glance.
    private var caption: String {
        guard state.isResting else { return "ready" }
        return isStale ? "over" : "resting"
    }
}
