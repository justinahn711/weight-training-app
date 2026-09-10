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
/// cancels. Anything uncertain — a bare number, a weight that had to be moved
/// to fit the bar, a field that was thrown out — shows without a countdown and
/// waits to be tapped.
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

                Text(spoken)
                    .font(.title3.weight(.semibold).monospacedDigit())

                Spacer()

                if let autoCommitAt {
                    CountdownRing(deadline: autoCommitAt,
                                  duration: SessionViewModel.autoCommitDelay,
                                  onElapsed: onCommit)
                } else {
                    Button("Log it", action: onCommit)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                }
            }

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
        // Any tap cancels, including one that lands on the banner itself.
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)
        // The tap-anywhere gesture above is invisible to VoiceOver: a gesture
        // on a container is not an action, so the one way to stop an
        // auto-committing set did not exist for a screen-reader user (#114).
        // Reading the banner as a single element also keeps the countdown from
        // being swiped past as loose text on the way to it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(autoCommitAt == nil
                           ? "Double tap to discard."
                           : "Logs automatically. Double tap to discard it.")
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

    /// What the banner says, read aloud in full.
    ///
    /// `spoken` alone is punctuation a screen reader mangles — "185 lb × 5 @ 8"
    /// becomes "185 lb x 5 at 8". Worse, the caveats underneath it are the
    /// whole reason this banner waits for confirmation, and they were separate
    /// labels a reader could stop before. Anything uncertain has to arrive in
    /// the same breath as the numbers it qualifies.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let load = heard.load {
            parts.append("\(load.formatted(in: GymSettings.shared.unit))")
        }
        if let reps = heard.reps { parts.append("for \(reps) reps") }
        if let rpe = heard.rpe { parts.append("at RPE \(rpe)") }

        var sentence = parts.isEmpty ? "Didn't catch that" : "Heard \(parts.joined(separator: " "))"
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
