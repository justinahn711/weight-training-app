//
//  NewExerciseView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

/// Adds a lift the app doesn't know about (#76).
///
/// The seeded library is a catalogue of what one person trains, not a
/// dictionary of every movement — its own doc comment has always said anything
/// missing can be added in-app. This is that.
///
/// Deliberately short. Everything the app needs beyond a name and the muscles
/// worked can be inferred from the equipment and corrected later at the rack,
/// the way machine increments and plate sets already are (#20, #39). A long
/// form here would be a wall between someone and the set they're about to do.
struct NewExerciseView: View {
    /// Pre-filled from whatever was being searched for when nothing matched.
    let initialName: String
    let onCreate: (Exercise) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var equipment: Equipment = .dumbbell
    @State private var primary: Muscle = .chest
    @State private var secondary: Set<Muscle> = []
    @State private var repRange = RepRange(8, 12)

    init(initialName: String = "", onCreate: @escaping (Exercise) -> Void) {
        self.initialName = initialName
        self.onCreate = onCreate
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("What you'd call it at the rack.")
                }

                Section {
                    Picker("Equipment", selection: $equipment) {
                        ForEach(Equipment.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                } footer: {
                    // Not asked for, because it can be inferred and corrected
                    // later — a stack's real increment is only learnable while
                    // standing at it.
                    Text("Sets the starting increment and how weight is loaded. Correct it from the session screen once you've used it.")
                }

                Section {
                    Picker("Muscle", selection: $primary) {
                        ForEach(Muscle.allCases, id: \.self) { muscle in
                            Text(muscle.displayName).tag(muscle)
                        }
                    }
                } header: {
                    Text("Primary muscle")
                } footer: {
                    Text("Required. Volume by muscle is counted from this, which is what tells you what you've been neglecting.")
                }

                Section("Also works") {
                    ForEach(Muscle.allCases, id: \.self) { muscle in
                        if muscle != primary {
                            Toggle(muscle.displayName, isOn: binding(for: muscle))
                        }
                    }
                }
            }
            .navigationTitle("New exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func binding(for muscle: Muscle) -> Binding<Bool> {
        Binding(
            get: { secondary.contains(muscle) },
            set: { on in
                if on { secondary.insert(muscle) } else { secondary.remove(muscle) }
            }
        )
    }

    private func create() {
        var muscles: [MuscleInvolvement] = [.primary(primary)]
        muscles += secondary.sorted { $0.rawValue < $1.rawValue }.map { .secondary($0) }

        onCreate(Exercise(
            name: trimmedName,
            muscles: muscles,
            equipment: equipment,
            // Double progression, like nearly everything else in the library —
            // add reps until the top of the range, then add weight.
            progressionRule: .doubleProgression(range: repRange)
        ))
        dismiss()
    }
}
