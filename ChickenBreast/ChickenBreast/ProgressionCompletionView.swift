import SwiftUI
import WeightTrainingCore

/// The acknowledgement after a successful Finish. Progression is already
/// persisted before this appears, so dismissing it is navigation, not consent.
struct ProgressionCompletionView: View {
    let entries: [ProgressionSummaryEntry]
    var records: [SessionRecordEntry] = []
    let onDone: () -> Void

    private var unit: MassUnit { GymSettings.shared.unit }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !records.isEmpty {
                        Text(records.count == 1 ? "Personal record" : "Personal records")
                            .font(.title2.bold())
                            .padding(.bottom, 2)
                        ForEach(records) { entry in
                            recordRow(entry)
                        }
                    }

                    if !entries.isEmpty {
                        Text("Next time")
                            .font(.title2.bold())
                            .padding(.top, records.isEmpty ? 0 : 8)
                            .padding(.bottom, 2)

                        ForEach(entries) { entry in
                            progressionRow(entry)
                        }
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

    private func recordRow(_ entry: SessionRecordEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(Theme.record)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.exercise.name)
                    .font(.headline)
                Text(recordLine(entry.record))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.record.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("completion.record.\(entry.id)")
    }

    private func recordLine(_ record: PersonalRecord) -> String {
        switch record.kind {
        case .heaviest(let load):
            return "\(load.formatted(in: unit)) × \(record.set.reps) — heaviest ever"
        case .reps(let reps, let load):
            return "\(reps) reps at \(load.formatted(in: unit)) — most ever at that weight"
        case .estimatedMax(let estimate):
            return "Estimated max \(estimate.formatted(in: unit)) — a best"
        }
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
