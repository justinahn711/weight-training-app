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
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Stepper(
                    label: "\(model.pendingLoad)",
                    caption: "Weight",
                    onDecrement: { model.adjustLoad(by: -1) },
                    onIncrement: { model.adjustLoad(by: 1) }
                )
                Stepper(
                    label: "\(model.pendingReps)",
                    caption: "Reps",
                    onDecrement: { model.adjustReps(by: -1) },
                    onIncrement: { model.adjustReps(by: 1) }
                )
            }

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

/// A big two-sided stepper. Targets are deliberately oversized — this gets
/// tapped with chalky hands, mid-set.
private struct Stepper: View {
    let label: String
    let caption: String
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 0) {
                button("minus", action: onDecrement)
                Text(label)
                    .font(.title3.bold().monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                button("plus", action: onIncrement)
            }
        }
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 46, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
