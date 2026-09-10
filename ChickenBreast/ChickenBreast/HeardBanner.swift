//
//  HeardBanner.swift
//  ChickenBreast
//

import SwiftUI
import UIKit
import WeightTrainingCore

/// What was heard, before it becomes a set (#22).
///
/// Voice fills the form; it never silently writes. This is that promise made
/// visible: the values appear, a ring counts down, and any tap anywhere
/// cancels, alongside a visible Cancel button for anyone who cannot use — or
/// cannot see — "anywhere" (#114). Anything uncertain — a bare number, a
/// weight that had to be moved to fit the bar, a field that was thrown out —
/// shows without a countdown and waits to be tapped.
struct HeardBanner: View {
    let heard: SnappedInput
    let autoCommitAt: Date?
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// Retained for the same reason as the rest banner's: a generator made
    /// inline is gone before the engine has started.
    @State private var haptics = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    // Decorative — the values it sits beside already carry the
                    // meaning; a screen reader gains nothing from "waveform,
                    // image" ahead of them.
                    .accessibilityHidden(true)

                Text(spoken)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    // Raw punctuation read badly on its own — "185 lb × 5 @ 8"
                    // as "185 lb x 5 at 8" — which mattered less while this sat
                    // inside one combined element with a hand-written label.
                    // Now that `.contain` below exposes this Text as its own
                    // stop, it needs that fix directly (#114).
                    .accessibilityLabel(spokenAccessibilityLabel)

                Spacer()

                if let autoCommitAt {
                    CountdownRing(deadline: autoCommitAt,
                                  duration: SessionViewModel.autoCommitDelay,
                                  onElapsed: onCommit)
                } else {
                    Button("Log it", action: onCommit)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityHint("Logs the values shown")
                        .accessibilityIdentifier("session.voice.commit")
                }
            }

            // A visible peer of the tap-anywhere gesture below, not a
            // replacement for it (#114). The gesture is a deliberate
            // sighted quick-dismiss — see the haptic note in `onAppear` for
            // why the phone stays face-down on the bench rather than being
            // watched — but a gesture on a container is not an accessibility
            // action, so it was the one way to stop an auto-committing set
            // that never existed for a screen-reader user. This button is
            // that path, independent of the gesture.
            Button("Cancel", role: .cancel, action: onCancel)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Cancel voice input")
                .accessibilityHint("Discards the values shown without logging a set")
                .accessibilityIdentifier("session.voice.cancel")

            ForEach(heard.rejections, id: \.self) { rejection in
                Label(rejection, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if heard.wasSnapped {
                Label("Adjusted to a weight you can load", systemImage: "arrow.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !heard.isConfident {
                Label("Not sure — check it", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary)
        // Any tap cancels, including one that lands on the banner itself —
        // kept alongside the Cancel button above, not replaced by it: this is
        // the deliberate sighted quick-dismiss, and the button is what makes
        // the same action reachable without sight (#114).
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)
        // `.contain`, not `.combine` (#114). `.combine` folds every child into
        // one element and reports one label for the lot — the shape this
        // banner had before a visible Cancel button existed, when the only
        // way to stop the countdown by touch was a tap on the container
        // itself. `.combine` also hides children from the rotor, which once
        // Cancel and Log It are real buttons would make one of them
        // unreachable — the opposite of what #114 asks for. `.contain` keeps
        // this a navigable group — still labelled below, still `.isModal`,
        // still escapable — while both buttons stay individually reachable.
        // The cost is the old single rich sentence read in one breath; it is
        // mitigated two ways: the spoken values above get their own corrected
        // label directly (raw punctuation is not what a screen reader hears),
        // and the caveat rows below ("Adjusted to a weight you can load",
        // "Not sure — check it") stay their own elements, so nothing here
        // becomes unreadable, only reachable one stop later.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("session.voice.confirmation")
        .accessibilityAddTraits(.isModal)
        // Named actions rather than the bare gesture, so both outcomes are
        // reachable from the rotor and neither depends on hitting a target.
        .accessibilityAction(named: "Log it", onCommit)
        .accessibilityAction(named: "Discard", onCancel)
        // Escape is the system gesture for "get me out of this" — a two-finger
        // scrub. Cancelling is the safe direction, matching the tap.
        .accessibilityAction(.escape, onCancel)
        .onAppear {
            // A tap you can feel, so the phone can stay in your pocket-adjacent
            // spot on the bench rather than being watched.
            haptics.impactOccurred()
        }
    }

    /// What was heard, without the caveats — used on the spoken values
    /// themselves so they read correctly in isolation, one stop among several
    /// now that `.contain` exposes them as their own element (#114).
    private var spokenAccessibilityLabel: String {
        var parts: [String] = []
        if let load = heard.load {
            parts.append("\(load.formatted(in: GymSettings.shared.unit))")
        }
        if let reps = heard.reps { parts.append("for \(reps) reps") }
        if let rpe = heard.rpe { parts.append("at RPE \(rpe)") }
        return parts.isEmpty ? "Didn't catch that" : "Heard \(parts.joined(separator: " "))"
    }

    /// The container's own summary, read when a rotor or swipe lands on the
    /// group as a whole rather than on one of its children. Kept in full —
    /// values plus every caveat in one sentence — as the mitigation for
    /// `.contain` no longer folding the whole banner into a single element:
    /// the one-sentence version survives here even though each caveat is also
    /// now reachable on its own below (#114).
    private var accessibilityLabel: String {
        var sentence = spokenAccessibilityLabel
        if heard.wasSnapped { sentence += ". Adjusted to a weight you can load" }
        if !heard.isConfident { sentence += ". Not sure — check it" }
        for rejection in heard.rejections { sentence += ". \(rejection)" }
        return sentence
    }

    /// `185 lb × 5 @ RPE 8`, with absent fields left out rather than filled in.
    private var spoken: String {
        var parts: [String] = []
        // `description` is pounds by definition. This banner auto-commits,
        // so rendering a spoken "sixty kilos" back as "132.3 lb" asks for
        // confirmation of a number nobody said.
        if let load = heard.load { parts.append(load.formatted(in: GymSettings.shared.unit)) }
        if let reps = heard.reps { parts.append("× \(reps)") }
        if let rpe = heard.rpe { parts.append("@ \(rpe)") }
        return parts.isEmpty ? "Didn't catch that" : parts.joined(separator: " ")
    }
}

/// A ring that empties, then fires once.
private struct CountdownRing: View {
    let deadline: Date
    let duration: TimeInterval
    let onElapsed: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / 30)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: remaining / duration)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.caption.bold().monospacedDigit())
            }
            .frame(width: 36, height: 36)
            .onChange(of: remaining <= 0) { _, elapsed in
                if elapsed { onElapsed() }
            }
        }
    }
}
