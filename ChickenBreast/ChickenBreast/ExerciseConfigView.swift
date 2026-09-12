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

    /// Everything this sheet can change, saved in one call.
    ///
    /// Rest rides along with increment and loading rather than getting its own
    /// closure. Two handlers would mean two `store.upsert` calls for one Save,
    /// and the second would start from the exercise as it was when the sheet
    /// opened — silently undoing what the first just wrote (#174).
    let onSave: (LoadIncrement, LoadingStyle?, TimeInterval?) -> Void

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

    /// Whether this lift rests on its own schedule rather than the
    /// compound/isolation heuristic (#174).
    @State private var overridesRest = false

    /// The rest time being edited, in seconds. Only meaningful while
    /// `overridesRest` is true; seeded from the override when there is one,
    /// or from today's default when there isn't, so turning the toggle on
    /// starts from a sane value rather than zero.
    @State private var restSeconds: Double = 90

    /// The empty weight as it is being typed, in `unit` (#99).
    ///
    /// Kept alongside `baseValue` rather than replacing it, because a field
    /// mid-edit is not always a number — "", "7." and whatever a paste leaves
    /// all have to be displayable while none of them is a weight. `baseValue`
    /// holds the last text that *was* one, and that is what Save writes.
    @State private var baseText = ""

    /// Whether the empty-weight field currently holds the keyboard.
    ///
    /// Held so the keyboard can be given up without leaving the sheet: a
    /// decimal pad has no return key, so without this the only way out of it
    /// would be Save, which closes the screen.
    @FocusState private var isEditingBase: Bool

    @State private var hasSeeded = false

    /// Whether `seed` has run for this presentation.
    ///
    /// Moving the seed out of `init` fixed the stale-state bug but left a
    /// window `init` did not have: `body` renders before `onAppear`, so for a
    /// frame the form holds zeros. Saving from that frame would call
    /// `LoadIncrement(0, _)`, whose `precondition(pounds > 0)` traps — turning
    /// a wrong value into a crash. The window is a frame wide and probably
    /// unreachable by a thumb, which is exactly why it should be closed here
    /// rather than left to be discovered.

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

    init(
        exercise: Exercise,
        onSave: @escaping (LoadIncrement, LoadingStyle?, TimeInterval?) -> Void
    ) {
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
        // The field starts on the value it is editing, not empty: this is a
        // correction to a figure the app already holds, and an empty box would
        // make it look like the app had forgotten it.
        baseText = format(baseValue)
        sleeves = exercise.loading?.sleeves ?? 2
        plates = Set(exercise.loading?.availablePlates ?? unit.standardPlates)
        overridesRest = exercise.restOverride != nil
        restSeconds = exercise.restOverride ?? defaultRestSeconds
        hasSeeded = true
    }

    /// What this lift would rest for absent any override — the compound/
    /// isolation heuristic itself, not `exercise.restTarget`, since that
    /// already folds in whatever override is currently seeded. Kept
    /// separate so the footer can name the default even while a person is
    /// actively looking at a different, overridden number above it.
    private var defaultRestSeconds: TimeInterval {
        exercise.isCompound ? 180 : 90
    }

    /// Rest times worth offering: half-minute steps across the range the
    /// library's own heuristic produces (90s and 180s), with a little room
    /// on either side for a lift that genuinely needs more or less.
    private static let restChoices: [Double] = [60, 90, 120, 150, 180, 210, 240, 300]

    private func restLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }

    /// Whether this lift still takes its plates from the gym.
    ///
    /// The same rule `save()` writes to `usesGymRack`: a lift follows the gym
    /// exactly while its plate set equals the gym's, and diverges the moment it
    /// does not. Computed here so the screen can say which of those is true —
    /// the per-lift and gym-level plate sections look identical, and nothing
    /// distinguished editing a default from creating an exception.
    private var followsGymRack: Bool {
        unit == GymSettings.shared.unit
            && plates == Set(GymSettings.shared.config.availablePlates)
    }

    /// Whether this lift is marked in a different unit from the gym.
    ///
    /// Only reachable for a lift that already diverged: `GymConfig.applied` and
    /// `reconcileGym` re-mark every follower, so a follower's unit is the
    /// gym's by construction.
    private var markedInAnotherUnit: Bool { unit != GymSettings.shared.unit }

    /// What changing these plates actually costs.
    ///
    /// The divergence is silent and effectively one-way today: `usesGymRack` is
    /// recomputed on save as "does this equal the gym's set", so a lift only
    /// rejoins by being edited back to exactly the gym's plates — which nobody
    /// can be expected to remember. Hence the button rather than only the text.
    private var plateFooter: String {
        if plates.isEmpty { return "Pick at least one plate size." }
        if followsGymRack {
            return "Following your gym's rack. Changing these makes this lift an exception, and it will stop picking up gym-level changes."
        }
        if markedInAnotherUnit {
            return "This lift is marked in \(unit.displayName.lowercased()) and your gym is in \(GymSettings.shared.unit.displayName.lowercased()), so it keeps its own rack."
        }
        return "This lift has its own rack and won't follow changes made to the gym."
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
                            // Typed, not stepped (#99). This number is *read* —
                            // off a sticker, a plate, a scale — so it is exact
                            // and known before the control exists. Stepping to
                            // 75 lb from a 45 lb default is twelve taps toward
                            // a figure already in hand, and the old bound of
                            // 200 lb was a guess that a heavy sled walks
                            // straight through. The session screen keeps its
                            // stepper for the opposite reason: there a weight
                            // is *chosen*, by nudging a suggestion, and there
                            // is nothing to read it off.
                            HStack {
                                Text("Empty weight")
                                Spacer(minLength: 12)
                                // In `unit` — the unit this machine is marked
                                // in — like everything else on this screen. The
                                // placeholder is the standing value, so a
                                // cleared field still shows what Save writes.
                                TextField(format(baseValue), text: $baseText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .focused($isEditingBase)
                                    // The Stepper carried this label; a
                                    // TextField beside a sibling Text does not
                                    // inherit it, so VoiceOver was announcing
                                    // an unnamed field holding a bare number.
                                    .accessibilityLabel("Empty weight")
                                    .accessibilityValue("\(baseText.isEmpty ? format(baseValue) : baseText) \(unit.symbol)")
                                Text(unit.symbol)
                                    .foregroundStyle(.secondary)
                            }
                            // Nothing is committed while typing. Committing
                            // per keystroke looked like it made Save safe with
                            // the keyboard up, and did the opposite: every
                            // valid *prefix* committed, so backspacing 102.5
                            // away walked the stored value 102 → 10 → 1 and
                            // left 1 standing when the field went empty. A 1 kg
                            // sled makes every plate line off that machine
                            // wrong by the whole apparatus, which is the exact
                            // failure `TypedWeight` exists to prevent.
                            //
                            // `baseValue` is the standing value and only `seed`
                            // sets it. What Save writes is resolved once, from
                            // the text, falling back to the standing value —
                            // so a cleared or half-typed field writes what was
                            // there before, with the keyboard up or not.
                            .onChange(of: isEditingBase) { _, editing in
                                // Leaving the field puts the standing value
                                // back on screen only when what is there is not
                                // a weight. A valid entry is left exactly as
                                // typed: reformatting it to one decimal turned
                                // 45.25 into 45.2 purely because Done was
                                // tapped before Save.
                                guard !editing, TypedWeight.parse(baseText) == nil else { return }
                                baseText = format(baseValue)
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

                    // An unmeasured lift renders no plate section, but it can
                    // still hold its own rack — turn "I've weighed it" off on a
                    // described apparatus and it keeps `availablePlates` and
                    // `usesGymRack: false`, and a row arriving by sync or
                    // restore can be in that state from the start. Settings
                    // counts those lifts, so without this the footer names an
                    // exception whose own screen offers no way out of it.
                    if !isMeasured && !followsGymRack && !markedInAnotherUnit {
                        Section {
                            Button("Follow the gym's rack") {
                                plates = Set(GymSettings.shared.config.availablePlates)
                            }
                        } footer: {
                            Text("This lift keeps a rack of its own and won't follow changes made to the gym.")
                        }
                    }

                    if isMeasured {
                        Section {
                            ForEach(Self.plateChoices(in: unit), id: \.self) { plate in
                                Toggle(isOn: binding(for: plate)) {
                                    Text(format(plate, withSymbol: true))
                                }
                            }
                            // Offered only when the units already agree. The
                            // gym's plate list is in the gym's unit, and `save`
                            // writes whatever is here as *this lift's* unit —
                            // so on a pound-marked lift in a kilogram gym this
                            // button wrote a kilogram rack labelled pounds: no
                            // 45s, a 20 lb plate, and no row in
                            // `plateChoices(in: .pounds)` to untoggle it again.
                            if !followsGymRack && !markedInAnotherUnit {
                                Button("Follow the gym's rack") {
                                    plates = Set(GymSettings.shared.config.availablePlates)
                                }
                            }
                        } header: {
                            // Named as the exception it is. The identical
                            // section in Settings is the one people should
                            // reach for; this overrides it for one apparatus,
                            // and nothing said so (#123).
                            Text(followsGymRack ? "Plates on the rack" : "This lift's own rack")
                        } footer: {
                            Text(plateFooter)
                        }
                    }
                }

                Section {
                    Toggle("Set my own rest time", isOn: $overridesRest.animation(.snappy))

                    if overridesRest {
                        ChoiceRow(
                            caption: "Rest between sets",
                            values: Self.restChoices,
                            isSelected: { $0 == restSeconds },
                            label: restLabel,
                            onSelect: { restSeconds = $0 }
                        )
                    }
                } header: {
                    Text("Rest")
                } footer: {
                    // The gym report behind #174 was "keep the defaults,
                    // just let me change one" — so the footer always names
                    // what this lift would otherwise get, whether or not
                    // it's currently overridden.
                    Text(overridesRest
                         ? "Otherwise defaults to \(restLabel(defaultRestSeconds)) for a lift like this."
                         : "Defaults to \(restLabel(defaultRestSeconds)) — 3 minutes for compound lifts, 90 seconds for isolation work.")
                }
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            // A second way out of the decimal pad, for the thumb that is
            // already on the form rather than up at the toolbar.
            .scrollDismissesKeyboard(.interactively)
            // Before the first frame the sheet shows, and again on every later
            // presentation — the form is never what a previous edit left behind.
            .onAppear(perform: seed)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasSeeded || (isMeasured && plates.isEmpty))
                }

                // A decimal pad has no return key, and the keyboard covers the
                // plate toggles under it. Without this the only way out is Save
                // or Cancel, and both leave the screen — so a lifter correcting
                // the empty weight could not then go on to fix the rack.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditingBase = false }
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
                baseWeight: isMeasured ? Load(TypedWeight.parse(baseText) ?? baseValue, unit) : nil,
                sleeves: sleeves,
                availablePlates: chosen,
                unit: unit,
                // Picking a rack that differs from the gym's is what makes this
                // lift an exception, and exceptions are left alone when the gym
                // changes (#73). Leaving it matching means it keeps following.
                // Compared as a set, matching `followsGymRack` above. This
                // compared a descending-sorted array against the gym's, which
                // agrees only while every writer happens to sort the same way —
                // and a restored archive carries whatever order the file had.
                // Two comparisons of one question, one of them order-sensitive,
                // is how a header comes to say "follows the gym" while the
                // stored flag says it does not.
                usesGymRack: followsGymRack
              )
            : nil
        onSave(increment, loading, overridesRest ? restSeconds : nil)
        dismiss()
    }

    /// A value already in `unit`, so this only tidies the decimal.
    /// Delegates to Core rather than keeping a second rule.
    ///
    /// This had its own one-decimal copy, which is how a 1.25 kg plate toggle
    /// read "1.2 kg" and a typed 45.25 came back as 45.2 after a reopen — the
    /// seeded text was formatted through it. One rule, checked by the suite.
    private func format(
        _ value: Double, in unit: MassUnit? = nil, withSymbol: Bool = false
    ) -> String {
        (unit ?? self.unit).format(value, withSymbol: withSymbol)
    }
}
