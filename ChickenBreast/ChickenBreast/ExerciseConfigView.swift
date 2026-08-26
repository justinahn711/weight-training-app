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

    /// Everything on this screen is typed and read in the unit the equipment
    /// is marked in — the lift's own if it has one, otherwise the gym's (#67).
    /// Correcting a machine means reading numbers off it, so the numbers here
    /// have to be the ones printed on the machine.
    private let unit: MassUnit

    @State private var incrementValue: Double
    @State private var isMeasured: Bool
    @State private var baseValue: Double
    @State private var sleeves: Int
    @State private var plates: Set<Double>

    /// Increments that actually occur: fractional plates, standard plates, and
    /// the coarse steps machine stacks use. Chosen per world rather than
    /// converted — a metric stack's notches are 2.5 and 5 kg, not 2.27.
    private static func incrementChoices(in unit: MassUnit) -> [Double] {
        unit == .pounds ? [2.5, 5, 10, 15, 20, 25] : [1.25, 2.5, 5, 7.5, 10, 15]
    }

    /// Plate sizes worth offering. A gym either has a size or doesn't, so this
    /// is a set of toggles rather than a count of each.
    private static func plateChoices(in unit: MassUnit) -> [Double] {
        unit == .pounds
            ? [45, 35, 25, 15, 10, 5, 2.5, 1.25]
            : [25, 20, 15, 10, 5, 2.5, 1.25]
    }

    init(exercise: Exercise, onSave: @escaping (LoadIncrement, LoadingStyle?) -> Void) {
        self.exercise = exercise
        self.onSave = onSave
        let unit = exercise.loading?.unit ?? GymSettings.shared.unit
        self.unit = unit
        _incrementValue = State(initialValue: exercise.increment.nativeValue)
        _isMeasured = State(initialValue: exercise.loading?.isMeasured ?? false)
        _baseValue = State(
            initialValue: exercise.loading?.baseWeight?.value(in: unit)
                ?? unit.standardBar.value(in: unit)
        )
        _sleeves = State(initialValue: exercise.loading?.sleeves ?? 2)
        _plates = State(
            initialValue: Set(exercise.loading?.availablePlates ?? unit.standardPlates)
        )
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
                        values: Self.incrementChoices(in: unit),
                        isSelected: { $0 == incrementValue },
                        label: { format($0) },
                        onSelect: { incrementValue = $0 }
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
                            Stepper(
                                value: $baseValue,
                                in: 0...(unit == .pounds ? 200 : 100),
                                step: unit == .pounds ? 2.5 : 1.25
                            ) {
                                HStack {
                                    Text("Empty weight")
                                    Spacer(minLength: 12)
                                    Text(format(baseValue, withSymbol: true))
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
                            ForEach(Self.plateChoices(in: unit), id: \.self) { plate in
                                Toggle(isOn: binding(for: plate)) {
                                    Text(format(plate, withSymbol: true))
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
        let increment = LoadIncrement(incrementValue, unit)
        let chosen = plates.sorted(by: >)
        // Only plate-built lifts carry a loading style; nothing else has a base
        // weight to record, and inventing one would start rendering plate lines
        // for a cable stack.
        let loading: LoadingStyle? = isPlateBuilt
            ? LoadingStyle(
                baseWeight: isMeasured ? Load(baseValue, unit) : nil,
                sleeves: sleeves,
                availablePlates: chosen,
                unit: unit,
                // Picking a rack that differs from the gym's is what makes this
                // lift an exception, and exceptions are left alone when the gym
                // changes (#73). Leaving it matching means it keeps following.
                usesGymRack: chosen == GymSettings.shared.config.availablePlates
              )
            : nil
        onSave(increment, loading)
        dismiss()
    }

    /// A value already in `unit`, so this only tidies the decimal.
    private func format(_ value: Double, withSymbol: Bool = false) -> String {
        let number = value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return withSymbol ? "\(number) \(unit.symbol)" : number
    }
}
