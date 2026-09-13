//
//  LiftConfigurationListView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// Answers "what can I change about a lift" without requiring the asker to be
/// mid-session on that exact lift (#178).
///
/// Three times running, someone asked for a feature that had already shipped:
/// the warmup ramp (#157), plates on the rack, and the load increment. All
/// three live behind `ExerciseConfigView`, and today that sheet has exactly
/// one door: the session screen's config line, under whichever lift happens
/// to be on screen. That door is not *unfindable* — it is a real, labeled,
/// 44pt tap target (#114), not a gesture or a hidden menu. The failure is
/// that it is findable but not obviously the answer, in two ways at once: it
/// only exists while you are already standing on the exact right lift
/// mid-set, and at a lift's defaults it renders as "Standard setup" — a
/// caption that reads as "nothing here" rather than "here's what you could
/// change." Someone wondering whether the cable machines' step can be changed
/// is, by definition, not mid-session on the cable machine that prompted the
/// question.
///
/// This is the second door, built where the first one structurally can't be:
/// Settings, the place people already go to ask how the app is set up, with
/// every lift listed regardless of session state. It reuses
/// `ExerciseConfigView` rather than a second editor (edits still go through
/// one form, one set of preconditions, one Save), and it deliberately does
/// NOT touch the session config line — #122 shortened that line on purpose,
/// and lengthening it back out would trade the noise problem for the
/// discovery problem instead of fixing either.
struct LiftConfigurationListView: View {
    let store: TrainingStore

    @State private var exercises: [Exercise] = []
    @State private var gym: GymConfig = GymSettings.shared.config
    @State private var configuring: Exercise?
    @State private var failure: String?
    @State private var query = ""

    private var filtered: [Exercise] {
        guard !query.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if exercises.isEmpty {
                Text("No lifts in your library yet.")
                    .foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text("No lifts match “\(query).”")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { exercise in
                    row(for: exercise)
                }
            }
        }
        .navigationTitle("Lift library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search lifts")
        .task {
            // Read fresh on every arrival rather than once at init, same
            // reason `SettingsView` re-reads `gym` on `.task`: a CloudKit
            // import or a plate toggle made elsewhere while this list wasn't
            // open must not be shown as stale.
            exercises = (try? store.exercises()) ?? []
            gym = GymSettings.shared.config
        }
        .sheet(item: $configuring) { exercise in
            ExerciseConfigView(exercise: exercise) { increment, loading, restOverride in
                save(exercise, increment: increment, loading: loading, restOverride: restOverride)
            }
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(for exercise: Exercise) -> some View {
        Button {
            configuring = exercise
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .foregroundStyle(.primary)
                    Text(facts(for: exercise))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 4)
            // A `Button` inside a `List` does not inherit the list's own
            // full-row hit testing the way a `NavigationLink` row does — that
            // gap is exactly what shipped four 18pt buttons in #114.
            // `minHeight` alone sets a frame; `contentShape` is what makes
            // the frame tappable.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(exercise.name)
        .accessibilityValue(facts(for: exercise))
        .accessibilityHint("Opens this lift's increment, loading, and rest settings")
        .accessibilityIdentifier("liftLibrary.row.\(exercise.id)")
    }

    /// What this lift steps by, how it's loaded, and how long it rests —
    /// stated whether or not any of it has ever been touched.
    ///
    /// `SessionView.configSummary` deliberately suppresses exactly these
    /// facts at their defaults (#122): read every set for an entire workout,
    /// "5 lb steps" said twenty times is noise. This screen is read once, to
    /// answer "what can I change about this lift" — the same suppression
    /// here would quietly reproduce the bug this screen exists to fix, since
    /// a lift with nothing printed would look identical to a lift with
    /// nothing to print. The "(default)" tag is what lets a fact be both
    /// true and visibly changeable, which is the one thing the session's
    /// quiet line can't say without becoming noisy again.
    private func facts(for exercise: Exercise) -> String {
        var parts: [String] = []

        let unit = exercise.increment.unit
        let defaultIncrement = exercise.equipment.defaultIncrement(in: unit)
        parts.append(exercise.increment == defaultIncrement
            ? "\(exercise.increment.formatted) steps (default)"
            : "\(exercise.increment.formatted) steps")

        if let loading = exercise.loading {
            if let base = loading.baseWeight {
                let loadingUnit = loading.unit
                // Same "what would this lift inherit" question
                // `ExerciseConfigView.followsGymRack` and
                // `SessionView.configSummary` both ask about the rack, asked
                // here about the empty weight instead.
                let inheritedBase = loading.usesGymRack && loadingUnit == gym.unit
                    ? gym.barWeight
                    : loadingUnit.standardBar
                parts.append(base == inheritedBase
                    ? "\(base.formatted(in: loadingUnit)) empty (default)"
                    : "\(base.formatted(in: loadingUnit)) empty")
            } else {
                parts.append("Not weighed yet")
            }
            parts.append(loading.usesGymRack ? "Gym's rack" : "Own rack")
        }

        if let override = exercise.restOverride {
            parts.append("\(restLabel(override)) rest")
        } else {
            // Mirrors `ExerciseConfigView.defaultRestSeconds` — the
            // compound/isolation heuristic itself, not `restTarget`, so this
            // reads the same whether or not `restTarget` later grows more
            // inputs than just the override.
            parts.append("\(restLabel(exercise.isCompound ? 180 : 90)) rest (default)")
        }

        return parts.joined(separator: " · ")
    }

    private func restLabel(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }

    /// Writes exactly what `ExerciseConfigView` computed, through the same
    /// `TrainingStore.upsert` every other correction to a lift uses.
    ///
    /// This is `SessionViewModel.updateConfiguration`'s in-session sibling,
    /// not a copy of it — deliberately smaller, because there is no live
    /// session here to keep in step. No `current`, no rebuilt
    /// `SessionExercise`, no `publishActivity()`. A session already open on
    /// this exact lift when a Settings-side edit lands won't see the change
    /// until it next reads that lift from the store — the same boundary
    /// `updateConfiguration` already accepts for a day that has moved on to
    /// a different lift, and not one this screen can close without reaching
    /// into a view model it doesn't own.
    private func save(
        _ exercise: Exercise,
        increment: LoadIncrement,
        loading: LoadingStyle?,
        restOverride: TimeInterval?
    ) {
        var corrected = exercise
        corrected.increment = increment
        corrected.loading = loading
        corrected.restOverride = restOverride
        do {
            try store.upsert(corrected)
            // Updated in place rather than re-fetched: `corrected` is exactly
            // what was just written, and a full `store.exercises()` re-read
            // would cost a decode of the whole library for every Save.
            if let index = exercises.firstIndex(where: { $0.id == corrected.id }) {
                exercises[index] = corrected
            }
        } catch {
            failure = "Couldn't save that setting: \(error.localizedDescription)"
        }
    }
}
