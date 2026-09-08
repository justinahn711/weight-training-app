import SwiftUI
import WeightTrainingCore

/// A logged set plus the equipment definition needed to correct it safely.
struct ActiveSetEditTarget: Identifiable {
    let record: SetRecord
    let exercise: Exercise
    var id: UUID { record.id }
}

/// Corrects one set without borrowing the controls for the next set (#130).
///
/// The sheet owns its draft for the whole presentation. `onSave` returns false
/// when persistence fails, leaving both the sheet and every entered value in
/// place for a retry.
struct ActiveSetEditor: View {
    let target: ActiveSetEditTarget
    let onSave: (SetRecord) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var load: Load
    @State private var reps: Int
    @State private var rpe: RPE?
    @State private var isWarmup: Bool

    init(target: ActiveSetEditTarget, onSave: @escaping (SetRecord) -> Bool) {
        self.target = target
        self.onSave = onSave
        _load = State(initialValue: target.record.load)
        _reps = State(initialValue: target.record.reps)
        _rpe = State(initialValue: target.record.rpe)
        _isWarmup = State(initialValue: target.record.isWarmup)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    loadControl
                    // Logged work is the record of what happened, so this
                    // must not impose the quick-entry row's convenient range.
                    // `Int.max` also lets Stepper disable increment before an
                    // overflow rather than inventing a target-derived ceiling.
                    Stepper(value: $reps, in: 1...Int.max) {
                        LabeledContent("Reps", value: "\(reps)")
                    }
                } header: {
                    Text(target.exercise.name)
                }

                Section {
                    Picker("RPE", selection: $rpe) {
                        Text("—").tag(RPE?.none)
                        ForEach(RPE.sessionChips, id: \.self) { value in
                            Text(value.description).tag(RPE?.some(value))
                        }
                    }
                    .disabled(isWarmup)
                    Toggle("Warmup", isOn: $isWarmup)
                } footer: {
                    Text(isWarmup
                         ? "Warmups are recorded but never counted as work."
                         : "This changes the logged set. Your next set and rest stay as they are.")
                }
            }
            .navigationTitle("Correct logged set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var corrected = target.record
                        corrected.load = load
                        corrected.reps = reps
                        corrected.rpe = isWarmup ? nil : rpe
                        corrected.isWarmup = isWarmup
                        if onSave(corrected) { dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var loadControl: some View {
        if let loading = target.exercise.loading, loading.isMeasured {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Weight")
                    Spacer()
                    Button {
                        if let previous = loading.previousBuildable(before: load) {
                            load = previous
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(loading.previousBuildable(before: load) == nil)
                    .accessibilityLabel("Decrease weight")

                    Text(load.formatted(in: GymSettings.shared.unit))
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 76)
                        .accessibilityLabel("Weight")

                    Button {
                        if let next = loading.nextBuildable(after: load) {
                            load = next
                        }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(loading.nextBuildable(after: load) == nil)
                    .accessibilityLabel("Increase weight")
                }

                if let breakdown = loading.breakdown(for: load) {
                    Text(breakdown.displayLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Stepper(
                value: Binding(
                    get: { load.pounds },
                    set: { load = Load($0) }
                ),
                in: target.exercise.minimumLoad.pounds...max(
                    2_000, target.exercise.minimumLoad.pounds
                ),
                step: target.exercise.increment.pounds
            ) {
                LabeledContent(
                    "Weight",
                    value: load.formatted(in: GymSettings.shared.unit)
                )
            }
        }
    }
}
