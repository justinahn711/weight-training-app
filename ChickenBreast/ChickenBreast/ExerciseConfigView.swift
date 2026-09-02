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
    private var unit: MassUnit { exercise.loading?.unit ?? GymSettings.shared.unit }

    /// The increment's own unit, which is not always the screen's.
    ///
    /// A measured step is a fact about one machine and survives a gym marked
    /// in something else — `GymConfig.applied(to:for:)` re-marks defaults and
    /// leaves measurements alone. So a 15 lb stack in a metric gym shows its
    /// step in pounds while its plates and base weight show in kilograms, and
    /// the increment row labels its unit for exactly that reason.
    ///
    /// Read from `exercise` rather than captured in `init`, so it describes the
    /// lift this presentation is actually editing — see `seed()`.
    private var incrementUnit: MassUnit { exercise.increment.unit }

    /// The edit in progress. Placeholders only: every one of these is replaced
    /// by `seed()` before the screen is looked at, and *none* of them may be
    /// seeded here — see `seed()` for why.
    @State private var incrementValue: Double = 0
    @State private var isMeasured = false
    @State private var baseValue: Double = 0
    @State private var sleeves = 2
    @State private var plates: Set<Double> = []

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
    }

    /// Loads the lift's current configuration into the form, on every
    /// presentation (#98).
    ///
    /// This deliberately does *not* happen in `init`. A `State` initial value is
    /// applied only when SwiftUI first creates that view's identity, and nothing
    /// obliges a re-presented sheet to be a new identity — so seeding there made
    /// the screen show, and Save write back, whatever was in the form the *first*
    /// time it opened. Correcting a hack squat and reopening it showed it
    /// unmeasured again, and the next Save put that back on disk.
    ///
    /// `onAppear` fires per presentation rather than per identity, so it is the
    /// one hook that is right whichever way SwiftUI decides to reuse the view.
    /// Same fix, same reason, as the gym screen re-reading its config on appear.
    private func seed() {
        // The increment keeps its OWN unit, which is the whole point of
        // carrying one: a stack measured at 15 lb is a fact about that machine
        // and survives a gym that marks everything else in kilograms
        // (`GymConfig.applied(to:for:)` re-marks only defaults). Reading the
        // value in `increment.unit` and writing it back in `unit` turned that
        // measured 15 lb into 15 kg on a Save that changed nothing.
        incrementValue = exercise.increment.nativeValue
        isMeasured = exercise.loading?.isMeasured ?? false
        baseValue = exercise.loading?.baseWeight?.value(in: unit)
            ?? unit.standardBar.value(in: unit)
        sleeves = exercise.loading?.sleeves ?? 2
        plates = Set(exercise.loading?.availablePlates ?? unit.standardPlates)
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
                        values: Self.incrementChoices(in: incrementUnit),
                        // A kilogram choice round-trips through canonical
                        // pounds and comes back as 7.499999999999999, so an
                        // equality test left every metric chip unselected.
                        isSelected: { abs($0 - incrementValue) < 0.001 },
                        label: { format($0, in: incrementUnit, withSymbol: true) },
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
            // Before the first frame the sheet shows, and again on every later
            // presentation — the form is never what a previous edit left behind.
            .onAppear(perform: seed)
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
        let increment = LoadIncrement(incrementValue, incrementUnit)
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
    private func format(
        _ value: Double, in unit: MassUnit? = nil, withSymbol: Bool = false
    ) -> String {
        let unit = unit ?? self.unit
        let number = value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return withSymbol ? "\(number) \(unit.symbol)" : number
    }
}
