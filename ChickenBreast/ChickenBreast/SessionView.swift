//
//  SessionView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

/// The main surface: context above, one action below.
///
/// Sized to be read at arm's length while resting, which is the whole design
/// constraint — the phone is on a bench two feet away, not in your hand.
struct SessionView: View {
    @State var model: SessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let exercise = model.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(exercise)
                        context(exercise)
                        setRows(exercise)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                actionBar(exercise)
            } else {
                ContentUnavailableView(
                    "Nothing to train",
                    systemImage: "figure.strengthtraining.traditional",
                    description: Text("This day has no exercises in the library yet.")
                )
            }
        }
        .navigationTitle(model.session.kind.rawValue.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Reachable at all times without a menu — sweaty-hand mistaps
                // are constant (#8).
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    model.undoLastSet()
                }
                .disabled(!model.canUndo)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.failure != nil },
                                    set: { if !$0 { model.dismissFailure() } })) {
            Button("OK") { model.dismissFailure() }
        } message: {
            Text(model.failure ?? "")
        }
    }

    // MARK: - Context above

    private func header(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.progressLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(exercise.exercise.name)
                .font(.largeTitle.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func context(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The target is the biggest thing on screen after the lift's name:
            // it's the one line being checked between sets.
            VStack(alignment: .leading, spacing: 2) {
                Text("Target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(exercise.prescription.displayLine)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(exercise.prescription.isColdStart ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Last time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(exercise.lastPerformance?.displayLine ?? "No history yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Set rows

    private func setRows(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if exercise.loggedSets.isEmpty {
                Text("No sets yet")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(exercise.loggedSets.enumerated()), id: \.element.id) { index, set in
                    SetRow(number: index + 1, set: set)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action below

    private func actionBar(_ exercise: SessionExercise) -> some View {
        VStack(spacing: 12) {
            WeightStepper(
                load: model.pendingLoad,
                increment: exercise.exercise.increment,
                onDecrement: { model.adjustLoad(by: -1) },
                onIncrement: { model.adjustLoad(by: 1) }
            )

            ChoiceRow(
                caption: "Reps",
                values: model.repChoices,
                isSelected: { $0 == model.pendingReps },
                label: { String($0) },
                onSelect: { model.pendingReps = $0 }
            )

            ChoiceRow(
                caption: "RPE",
                values: RPE.sessionChips,
                isSelected: { $0 == model.pendingRPE },
                label: { $0.value == $0.value.rounded()
                    ? String(format: "%.0f", $0.value)
                    : String(format: "%.1f", $0.value) },
                onSelect: { model.pendingRPE = $0 }
            )

            Button {
                model.logSet()
            } label: {
                Text("Log Set")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button("Warmup") { model.logSet(isWarmup: true) }
                    .font(.subheadline)
                Spacer()
                if model.session.currentIndex > 0 {
                    Button("Back") { model.goBack() }
                        .font(.subheadline)
                }
                if !model.session.isOnLastExercise {
                    Button("Next exercise") { model.advance() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// One logged set. Warmups are visually demoted — they're kept in the same list
/// so the day reads in document order, but they never count.
private struct SetRow: View {
    let number: Int
    let set: SetRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text("\(set.load) × \(set.reps)")
                .font(.title3.weight(.medium).monospacedDigit())

            Spacer()

            if set.isWarmup {
                Text("Warmup")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if let rpe = set.rpe {
                Text(rpe.description)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
        .opacity(set.isWarmup ? 0.6 : 1)
    }
}

/// Weight, stepped by the exercise's real increment.
///
/// There is no text field here and nowhere else in the session either: the
/// keyboard never appears mid-set (#4). Stepping by the increment also means
/// the control can only produce loads the equipment can actually make — a
/// dumbbell rack has no 67.5, so the UI shouldn't offer one.
private struct WeightStepper: View {
    let load: Load
    let increment: LoadIncrement
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", action: onDecrement)
            VStack(spacing: 0) {
                Text(load.description)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(Load(increment.pounds)) steps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            button("plus", action: onIncrement)
        }
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                // Oversized on purpose: tapped with chalky hands, mid-set.
                .frame(width: 64, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal row of tappable values, one tap to choose.
///
/// Used for both reps and RPE. Scrollable rather than clipped, so an unusually
/// good set doesn't have to be rounded to whatever fits on screen.
private struct ChoiceRow<Value: Hashable>: View {
    let caption: String
    let values: [Value]
    let isSelected: (Value) -> Bool
    let label: (Value) -> String
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(values, id: \.self) { value in
                            let selected = isSelected(value)
                            Button {
                                onSelect(value)
                            } label: {
                                Text(label(value))
                                    .font(.title3.weight(selected ? .bold : .medium).monospacedDigit())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .frame(minWidth: 54, minHeight: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(selected ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.fill.quaternary))
                                    )
                            }
                            .buttonStyle(.plain)
                            .id(value)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onAppear {
                    // Open with the pre-selected value in view, so the common
                    // case needs no scrolling at all.
                    if let selected = values.first(where: isSelected) {
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }
        }
    }
}
