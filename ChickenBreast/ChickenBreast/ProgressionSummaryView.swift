//
//  ProgressionSummaryView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

/// Shown once, right after a successful Finish, before the route drops back
/// to Train (#184).
///
/// By the time this appears, `SessionViewModel.finish()` has already saved
/// every progression result — this is acknowledgement, not another
/// checkpoint. There is exactly one action, and it means the same thing
/// whether it's tapped or the sheet is swiped away: continue to Train.
/// Neither path can gate or repeat persistence, because neither path touches
/// `store` at all — both just call `onContinue`, which the caller wires to
/// the same `onFinish` a workout with nothing to report already used.
struct ProgressionSummaryView: View {
    let rows: [ProgressionSummaryRow]
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.exerciseName)
                        .font(.subheadline.weight(.semibold))
                    Text(row.bodyText)
                        .font(.body)
                    if let reason = row.reason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                // One label built from the same row model VoiceOver would
                // otherwise stitch together from three separate `Text`
                // views in layout order — explicit here so the reading
                // order can't drift from what the row actually says
                // (#184's "coherent row" acceptance criterion).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
            }
            .navigationTitle("Workout complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onContinue)
                        .accessibilityIdentifier("progressionSummary.done")
                }
            }
        }
        .accessibilityIdentifier("progressionSummary.sheet")
    }
}

#Preview {
    ProgressionSummaryView(
        rows: [
            ProgressionSummaryRow(
                id: UUID(),
                exerciseName: "Incline Press",
                performedLine: "70 lb × 12",
                nextLine: "75 lb × 8",
                reason: "Earned after 2 top-range sessions"
            ),
            ProgressionSummaryRow(
                id: UUID(),
                exerciseName: "Lateral Raise",
                performedLine: "15 lb × 14",
                nextLine: "15 lb × 15",
                reason: nil
            ),
            ProgressionSummaryRow(
                id: UUID(),
                exerciseName: "Bench",
                performedLine: "185 lb × 5",
                nextLine: nil,
                reason: "RPE 9 was above target"
            )
        ],
        onContinue: {}
    )
}
