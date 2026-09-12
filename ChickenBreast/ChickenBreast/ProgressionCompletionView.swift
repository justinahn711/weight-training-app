import SwiftUI
import WeightTrainingCore

/// The acknowledgement after a successful Finish. Progression is already
/// persisted before this appears, so dismissing it is navigation, not consent.
struct ProgressionCompletionView: View {
    let entries: [ProgressionSummaryEntry]
    let onDone: () -> Void

    private var unit: MassUnit { GymSettings.shared.unit }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Next time")
                        .font(.title2.bold())
                        .padding(.bottom, 2)

                    ForEach(entries) { entry in
                        progressionRow(entry)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Workout complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("completion.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("completion.progression.sheet")
    }

    private func progressionRow(_ entry: ProgressionSummaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.exercise.name)
                .font(.headline)

            Text(entry.transitionLine(in: unit))
                .font(.body.weight(.medium))

            Text(entry.result.summary(in: unit))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel(in: unit))
        .accessibilityIdentifier("completion.progression.\(entry.id)")
    }
}
