//
//  StackedStepperRow.swift
//  ChickenBreast
//

import SwiftUI

/// A Form row holding a system `Stepper` whose label is a name and a value —
/// "Weekly goal · 3 days", "Weight · 45 lb" — that keeps the label's words
/// whole at accessibility text sizes (#250).
///
/// A `Stepper` lays its label out beside Apple's fixed 94pt −/+ control, and
/// `LabeledContent` then splits what's left between the name and the value.
/// At AccessibilityXXXL on an SE that left the name narrower than one word,
/// and it broke mid-word: "Wee / kly / goal", "Weig / ht". At accessibility
/// sizes this stacks the row instead — name, then value, then the control on
/// its own line — the same switch the session's reps/RPE steppers make on
/// `isAccessibilitySize`. Below that the stepper is returned untouched, so
/// the default-size layout is exactly the caller's.
///
/// VoiceOver is unchanged either way. The stepper keeps its own label (only
/// hidden visually, via `labelsHidden()`), so it still reads "Weekly goal,
/// 3 days, Increment"; the stacked copy above it is hidden from accessibility
/// so the name and value aren't announced twice.
struct StackedStepperRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let stepper: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                stepper
                    .labelsHidden()
            }
        } else {
            stepper
        }
    }
}
