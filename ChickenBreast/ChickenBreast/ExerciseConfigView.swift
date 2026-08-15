//
//  ExerciseConfigView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

/// Corrects what the app assumes about a machine (#20, #39).
///
/// Every default in the library is a guess made away from the gym: a stack's
/// increment, a T-bar's lever weight, which plates are on the rack. The guesses
/// are load-bearing — they decide what gets suggested and whether a plate line
/// can be shown — so there has to be a way to fix one the moment it's noticed,
/// mid-session, without leaving the lift.
///
/// Deliberately not a settings screen buried elsewhere. You discover a stack
/// moves in 15s while standing at it, and if correcting that costs more than a
/// few taps it never gets corrected.
struct ExerciseConfigView: View {
    let exercise: Exercise
    let onSave: (LoadIncrement, LoadingStyle?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var incrementPounds: Double
    @State private var isMeasured: Bool
    @State private var basePounds: Double
    @State private var sleeves: Int
    @State private var plates: Set<Double>

    /// Increments that actually occur: fractional plates, standard plates, and
    /// the coarse steps machine stacks use.
    private static let incrementChoices: [Double] = [2.5, 5, 10, 15, 20, 25]

    /// Plate sizes worth offering. A gym either has a size or doesn't, so this
    /// is a set of toggles rather than a count of each.
    private static let plateChoices: [Double] = [45, 35, 25, 15, 10, 5, 2.5, 1.25]

    init(exercise: Exercise, onSave: @escaping (LoadIncrement, LoadingStyle?) -> Void) {
        self.exercise = exercise
        self.onSave = onSave
        _incrementPounds = State(initialValue: exercise.increment.pounds)
        _isMeasured = State(initialValue: exercise.loading?.isMeasured ?? false)
        _basePounds = State(initialValue: exercise.loading?.baseWeight?.pounds ?? 45)
        _sleeves = State(initialValue: exercise.loading?.sleeves ?? 2)
        _plates = State(initialValue: Set(exercise.loading?.availablePlates ?? LoadingStyle.standardPlates))
    }

    /// Whether this lift is built from plates at all. A cable stack has no
    /// base weight to measure and no plates to pick.
    private var isPlateBuilt: Bool { exercise.loading != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ChoiceRow(
                        caption: "Smallest change",
                        values: Self.incrementChoices,
                        isSelected: { $0 == incrementPounds },
                        label: { Self.format($0) },
                        onSelect: { incrementPounds = $0 }
                    )
                } header: {
                    Text("Increment")
                } footer: {
                    Text("What one notch on the stack, or the smallest pair of plates, actually adds.")
                }

                if isPlateBuilt {
                    Section {
                        Toggle("I've weighed it", isOn: $isMeasured.animation(.snappy))

                        if isMeasured {
                            // The value sits beside the control rather than
                            // under it: LabeledContent stacks multiple children,
                            // which reads as the number belonging to the next
                            // row down.
                            Stepper(value: $basePounds, in: 0...200, step: 2.5) {
                                HStack {
                                    Text("Empty weight")
                                    Spacer(minLength: 12)
                                    Text("\(Self.format(basePounds)) lb")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Picker("Loads onto", selection: $sleeves) {
                                Text("One side").tag(1)
                                Text("Both sides").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                    } header: {
                        Text("Apparatus")
                    } footer: {
                        Text(isMeasured
                             ? "Used to read plate loads off the bar and to keep suggestions to weights this can actually be set to."
                             : "Until it's weighed, the app logs what you lift but won't guess a plate breakdown — a plate list that's wrong gets followed.")
                    }

                    if isMeasured {
                        Section {
                            ForEach(Self.plateChoices, id: \.self) { plate in
                                Toggle(isOn: binding(for: plate)) {
                                    Text("\(Self.format(plate)) lb")
                                }
                            }
                        } header: {
                            Text("Plates on the rack")
                        } footer: {
                            Text(plates.isEmpty
                                 ? "Pick at least one plate size."
                                 : "Suggestions are limited to weights these plates can build.")
                        }
                    }
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isMeasured && plates.isEmpty)
                }
            }
        }
    }

    private func binding(for plate: Double) -> Binding<Bool> {
        Binding(
            get: { plates.contains(plate) },
            set: { keep in
                if keep { plates.insert(plate) } else { plates.remove(plate) }
            }
        )
    }

    private func save() {
        let increment = LoadIncrement(pounds: incrementPounds)
        // Only plate-built lifts carry a loading style; nothing else has a base
        // weight to record, and inventing one would start rendering plate lines
        // for a cable stack.
        let loading: LoadingStyle? = isPlateBuilt
            ? LoadingStyle(
                baseWeight: isMeasured ? Load(basePounds) : nil,
                sleeves: sleeves,
                availablePlates: plates.sorted(by: >)
              )
            : nil
        onSave(increment, loading)
        dismiss()
    }

    private static func format(_ pounds: Double) -> String {
        pounds == pounds.rounded()
            ? String(format: "%.0f", pounds)
            : String(format: "%.1f", pounds)
    }
}
