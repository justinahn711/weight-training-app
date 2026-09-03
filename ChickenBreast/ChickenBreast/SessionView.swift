//
//  SessionView.swift
//  ChickenBreast
//

import AudioToolbox
import SwiftUI
import UIKit
import WeightTrainingCore

/// The main surface: context above, one action below.
///
/// Sized to be read at arm's length while resting, which is the whole design
/// constraint — the phone is on a bench two feet away, not in your hand.
struct SessionView: View {
    /// The gym the app is rendering in, so a weight on this screen is in
    /// the unit the lifter's rack is marked in (#67).
    private var gym: GymSettings { .shared }

    @State var model: SessionViewModel
    @State private var isSwapping = false

    /// The lift whose configuration is open, rather than a bare flag (#98).
    ///
    /// The sheet then carries the exercise it is editing for the whole of that
    /// presentation. Reading `model.current` inside the sheet builder instead
    /// re-read it on every parent update — and saving is itself a rebuild, so
    /// the screen's subject could move out from under the person editing it.
    @State private var configuring: Exercise?
    @State private var voice = VoiceRecognizer()

    var body: some View {
        VStack(spacing: 0) {
            if let exercise = model.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(exercise)
                        context(exercise)
                        if !model.warmupRamp.isEmpty {
                            WarmupBlock(
                                ramp: model.warmupRamp,
                                isExpanded: $model.isWarmupRampExpanded,
                                breakdown: { exercise.exercise.plateBreakdown(for: $0) },
                                onLog: { model.logWarmup($0) },
                                onClear: { model.clearWarmupRamp() }
                            )
                        }
                        setRows(exercise)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                if let heard = model.heard {
                    HeardBanner(
                        heard: heard,
                        autoCommitAt: model.autoCommitAt,
                        onCommit: {
                            model.commitHeard()
                            voice.consume()
                        },
                        onCancel: {
                            model.clearHeard()
                            voice.consume()
                        }
                    )
                } else if let rest = model.rest {
                    RestBanner(rest: rest, onSkip: { model.skipRest() })
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
        // Small, and the top rage-quit cause in every lifting app: the screen
        // going dark mid-set (#7). Scoped to this view, so it's restored the
        // moment the session is left rather than depending on a "finish"
        // action being tapped.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.loadSuggestionContext()
            // The lock screen is only useful while a session is open, which is
            // exactly the span this view is on screen for (#23).
            model.publishActivity()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Leaving the session is what finishes it — there's no "done"
            // button to forget to press, and a session abandoned halfway still
            // produced real work that should count.
            model.applyProgression()
            model.endActivity()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Reachable at all times without a menu — sweaty-hand mistaps
                // are constant (#8).
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    model.undoLastSet()
                }
                .disabled(!model.canUndo)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        if voice.isListening { voice.stop() } else { await voice.start() }
                    }
                } label: {
                    Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic")
                        .symbolEffect(.pulse, isActive: voice.isListening)
                }
            }
        }
        // Heard values reach the form only through the snapper — the view has
        // no path that writes a spoken number directly.
        .onChange(of: voice.parsed) { _, parsed in
            guard let parsed else { return }
            model.handle(parsed)
        }
        .onDisappear { voice.stop() }
        .sheet(isPresented: $isSwapping) {
            SwapSheet(
                slotName: model.current?.slot?.name,
                candidates: model.swapCandidates,
                search: { model.searchResults($0) },
                onPick: { exercise in
                    model.swap(to: exercise)
                    isSwapping = false
                },
                onCreate: { exercise in
                    model.createAndSwap(to: exercise)
                    isSwapping = false
                }
            )
        }
        .sheet(item: $configuring) { exercise in
            ExerciseConfigView(exercise: exercise) { increment, loading in
                model.updateConfiguration(of: exercise, increment: increment, loading: loading)
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
            HStack(spacing: 8) {
                Text(model.progressLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                if let slot = exercise.slot {
                    // The slot is the job. Naming it makes a swap legible as a
                    // substitution rather than as abandoning the day's shape.
                    Text(slot.name)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Button {
                isSwapping = true
            } label: {
                HStack(spacing: 6) {
                    Text(exercise.exercise.name)
                        .font(.largeTitle.bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// One line describing what the app currently assumes, so the button says
    /// what tapping it would change rather than just "Settings".
    private func configSummary(_ exercise: SessionExercise) -> String {
        // The increment is rendered in the unit it was marked in rather than
        // the gym's, because that is what it means: a stack measured at 15 lb
        // is a 15 lb stack even in a gym that has since gone metric (#67).
        let stepText = exercise.exercise.increment.formatted
        guard let loading = exercise.exercise.loading else {
            return "Steps of \(stepText)"
        }

        // Both states below are ones where the plate row is absent, and the
        // absence is right — a plate total on an unweighed apparatus, or built
        // from a rack with nothing on it, would be a guess presented as a
        // number. What was missing is the connection between the two facts:
        // "not weighed" was already on screen, already tappable, and never
        // said that weighing it is what brings the plate buttons back (#95).
        //
        // Said here rather than as a second button beside this one. The
        // information and the route were both already here; adding another
        // tinted caption opening the same sheet would have been two ways into
        // one screen, not a clearer one.
        guard let base = loading.baseWeight else {
            return "Steps of \(stepText) · weigh it to add plates"
        }
        if loading.availablePlates.isEmpty {
            // Reachable: clear every plate in config while "I've weighed it"
            // is on, then switch it off and save. Weighing is not what fixes
            // this one, so it must not be what the line asks for.
            return "Steps of \(stepText) · empty \(base.formatted(in: loading.unit)) · no plates set"
        }
        return "Steps of \(stepText) · empty \(base.formatted(in: loading.unit))"
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
                Text(exercise.prescription.displayLine(in: gym.unit))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(exercise.prescription.isColdStart ? .secondary : .primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Last time")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(exercise.lastPerformance?.displayLine(in: gym.unit) ?? "No history yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Sits with the target because that's what it changes, and because
            // the moment you notice a stack moves in 15s is the moment you're
            // reading this line (#20).
            Button {
                configuring = exercise.exercise
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text(configSummary(exercise))
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            // Beside the number, never as it — chips sit directly above the
            // stepper they're talking about, and the stepper is unaffected
            // until one is tapped.
            if !model.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.suggestions) { suggestion in
                            SuggestionChip(
                                suggestion: suggestion,
                                onAccept: { withAnimation(.snappy) { model.accept(suggestion) } },
                                onDismiss: { withAnimation(.snappy) { model.dismiss(suggestion) } }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            WeightStepper(
                load: model.pendingLoad,
                increment: exercise.exercise.increment,
                // Read off while loading the bar, so it sits directly under the
                // number it describes (#14).
                plates: model.plateBreakdown?.displayLine,
                onDecrement: { model.adjustLoad(by: -1) },
                onIncrement: { model.adjustLoad(by: 1) }
            )

            // Building a weight the way it's built in the gym (#77). Only for
            // apparatus that has been measured, since a running total on an
            // unknown bar would be a guess presented as a number.
            if !model.plateOptions.isEmpty {
                PlateRow(
                    plates: model.plateOptions,
                    onAdd: { model.addPlate($0) },
                    onClear: { model.clearToBar() }
                )
            }

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
    private var gym: GymSettings { .shared }

    let number: Int
    let set: SetRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text("\(set.load.formatted(in: gym.unit)) × \(set.reps)")
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

/// Swapping the lift filling a slot (#18).
///
/// The slot's own candidates sit at the top, stalest first, so the common case
/// is one tap with no typing. Search is there for everything else.
///
/// There is deliberately no "create exercise" button. A lift invented at the
/// rack has no history, no increment, and no muscle tags, and it pollutes
/// volume tracking permanently — that's a considered decision, not a mid-set
/// one. This is also the only place in a session a keyboard can appear, and
/// only if you reach for search.
private struct SwapSheet: View {
    let slotName: String?
    let candidates: [Exercise]
    let search: (String) -> [Exercise]
    let onPick: (Exercise) -> Void
    let onCreate: (Exercise) -> Void

    @State private var query = ""
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !candidates.isEmpty, query.isEmpty {
                    Section {
                        ForEach(candidates) { exercise in
                            row(exercise)
                        }
                    } header: {
                        Text(slotName.map { "For \($0.lowercased())" } ?? "Alternatives")
                    } footer: {
                        Text("Least recently trained first.")
                    }
                }

                Section("All exercises") {
                    let results = search(query)
                    if results.isEmpty {
                        // Not finding it is exactly when you'd want to add it,
                        // so the offer belongs here rather than behind a
                        // toolbar button somewhere else (#76).
                        Button {
                            isCreating = true
                        } label: {
                            Label(
                                query.isEmpty ? "Add an exercise" : "Add “\(query)”",
                                systemImage: "plus.circle.fill"
                            )
                        }
                    } else {
                        ForEach(results) { exercise in
                            row(exercise)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search exercises")
            .sheet(isPresented: $isCreating) {
                NewExerciseView(initialName: query) { exercise in
                    onCreate(exercise)
                    dismiss()
                }
            }
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ exercise: Exercise) -> some View {
        Button {
            onPick(exercise)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.body.weight(.medium))
                Text(exercise.primaryMuscles.map(\.rawValue).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One suggestion, stating its reason (#12).
///
/// Tapping the body accepts it — which only moves the number the done button
/// already commits, so accepting is identical to having dialled it by hand. The
/// × dismisses it for the rest of the session.
///
/// Styled as an outline rather than a filled control on purpose: it must not
/// read as the primary action. The blue button below is what logs a set.
private struct SuggestionChip: View {
    private var gym: GymSettings { .shared }

    let suggestion: Suggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAccept) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title(in: gym.unit))
                        .font(.subheadline.weight(.semibold))
                    Text(suggestion.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // A sibling of the accept button, never inside its label — a nested
            // button never receives its own taps.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint.opacity(0.5), lineWidth: 1.5)
        )
    }
}

/// The warmup ramp, collapsed by default (#15).
///
/// Collapsed because on most days the ramp is glanced at rather than read —
/// the weights are obvious once you've done the lift twice. Expanded, each rung
/// is tappable and logs exactly what it shows, so ramping never means dialling
/// the stepper up and back down.
private struct WarmupBlock: View {
    private var gym: GymSettings { .shared }

    let ramp: [WarmupSet]
    @Binding var isExpanded: Bool
    let breakdown: (Load) -> PlateBreakdown?
    let onLog: (WarmupSet) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Clear is a sibling of the disclosure button, not nested inside its
            // label. A button inside another button's label never receives its
            // own taps — the outer gesture wins — which would make #15's "one
            // tap to clear" quietly toggle the block open instead.
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Warmup ramp")
                            .font(.subheadline.weight(.semibold))
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button("Clear", action: onClear)
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }

            if isExpanded {
                ForEach(ramp) { rung in
                    Button {
                        onLog(rung)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(rung.load.formatted(in: gym.unit)) × \(rung.reps)")
                                .font(.body.weight(.medium).monospacedDigit())
                            if let plates = breakdown(rung.load)?.displayLine {
                                Text(plates)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// `45 → 180, 4 sets` — enough to decide whether to expand it.
    private var summary: String {
        guard let first = ramp.first, let last = ramp.last else { return "" }
        return ramp.count == 1
            ? "\(first.load)"
            : "\(first.load) → \(last.load), \(ramp.count) sets"
    }
}

/// The rest clock — the primary thing on screen while resting (#6).
///
/// Driven by `TimelineView` off the system clock rather than by a `Timer`
/// object, which means there is no running state to lose: coming back from the
/// lock screen or from another app redraws the correct value immediately.
private struct RestBanner: View {
    let rest: RestTimer
    let onSkip: () -> Void

    @AppStorage(RestAlertSettings.timingKey) private var showsTiming = true

    /// What the buzz did, once it has done it. See `RestAlertReport`.
    @State private var report: RestAlertReport?

    var body: some View {
        TimelineView(.periodic(from: rest.startedAt, by: 1)) { context in
            let done = rest.isComplete(at: context.date)
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: rest.progress(at: context.date))
                        .stroke(done ? Color.green : Color.accentColor,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 0) {
                    Text(done ? "Rest complete" : "Resting")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(rest.displayTime(at: context.date))
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(done ? Color.green : Color.primary)
                        .contentTransition(.numericText())

                    if showsTiming, let report {
                        Text(report.line)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button("Skip", action: onSkip)
                    .font(.body.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.fill.tertiary)
        }
        // Waits for the clock rather than watching the view.
        //
        // This was an `onChange` on the countdown inside the TimelineView, and
        // it never fired: that closure is rebuilt every tick, so the change
        // detection compares against state in a subtree that keeps being
        // reconstructed. It compiled, read correctly, and did nothing — which
        // is why the buzz was missing on a phone with notifications on and the
        // session on screen (#69).
        //
        // Keyed by the set, so it re-arms for the next rest and cancels when a
        // set is undone or the rest is skipped — the view goes away with it.
        .task(id: rest.setID) {
            let deadline = rest.endsAt
            guard deadline.timeIntervalSinceNow > 0 else { return }

            // Halve the wait, repeatedly, rather than sleeping to the
            // deadline in one go.
            //
            // A long `Task.sleep` drifts late: the system takes a leeway
            // proportional to the interval and coalesces the wake with
            // whatever else it was already doing. Measured on the phone, a
            // 179-second sleep came back 5.6 seconds past its mark — about 3%,
            // and the whole of the complaint.
            //
            // Sleeping *near* the deadline and correcting the last second
            // doesn't survive that, which is what the first attempt at this
            // did: drift only runs one way, so an overshoot lands past the
            // deadline and eats the correction window before it can be used.
            // The margin has to be proportional too.
            //
            // So each pass sleeps half of what's left. Overshoot can only
            // carry past the deadline if the leeway exceeds 100% of the
            // interval, which is a different bug entirely — and the tolerance
            // is pinned at zero besides, so this holds whether or not the
            // system honours that. It converges in about ten wakes across a
            // three-minute rest, which is nothing.
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                // Under a second there's no margin worth reserving, and
                // halving forever would never arrive.
                let step = remaining > 1 ? remaining / 2 : remaining
                try? await Task.sleep(for: .seconds(step), tolerance: .zero)
                guard !Task.isCancelled else { return }
            }

            // Backgrounding suspends this, so on return the loop exits
            // immediately and would buzz for a rest that ended ten minutes ago
            // — after the notification already said so. Only fire if it's
            // actually just happened.
            //
            // Ten seconds rather than five. Five was close enough to the drift
            // being fixed here that a buzz measured at +4.65s passed by a
            // third of a second, and the failure is asymmetric: a late buzz is
            // worse than an on-time one, but silence is worse than both, and
            // the case this guard exists for is minutes out, not seconds.
            //
            // The near misses get recorded rather than dropped, because a buzz
            // held back for being six seconds late and a buzz that arrives six
            // seconds late are the same thing from the bench, and this line is
            // the only thing that can tell them apart.
            let lateness = Date().timeIntervalSince(deadline)
            guard lateness < 10 else {
                report = RestAlertReport(lateness: lateness, call: nil, held: true)
                return
            }

            // Posted before the buzz and again after it, so the line shows
            // the lateness immediately and fills in the vibration time when
            // the system reports back — a buzz that never completes leaves the
            // ellipsis up, which is itself the answer.
            let began = ContinuousClock.now
            report = RestAlertReport(lateness: lateness, call: nil, held: false)
            await RestAlert.buzz()
            report = RestAlertReport(
                lateness: lateness,
                call: ContinuousClock.now - began,
                held: false
            )
        }
    }
}

/// What the buzz actually did, rendered where it can be read off the phone.
///
/// #69 took four rounds because no build, test or log could distinguish a
/// haptic that didn't fire from one that fired and wasn't felt — they are
/// identical from the Mac and obvious from the bench. What broke the loop was
/// putting the attempt on screen. This is the same trick pointed at what's
/// left: the buzz is arriving, so the question is now how late, and whether
/// the lateness is in the timer or in the vibration call itself.
///
/// `+0.00s · motor 564 ms` is the alert working, measured on the phone once
/// the timer drift was fixed. Both halves are now known-good baselines: a
/// large `+` is the wait drifting again, a large `motor` is the vibration path
/// stalling, and those are different bugs with different fixes. A large `+` is the timer
/// drifting; a large `motor` is the vibration path itself stalling, which
/// would be a different fix. Turn it off in Settings once it reads right.
private struct RestAlertReport {

    /// How far past the target the buzz went out.
    let lateness: TimeInterval

    /// How long the vibration took, or `nil` before the system has said.
    let call: Duration?

    /// Whether the buzz was suppressed for arriving too late to mean anything.
    let held: Bool

    var line: String {
        let late = String(format: "%+.2fs", lateness)
        if held { return "buzz held back \(late)" }
        guard let call else { return "buzz \(late) · motor …" }
        let milliseconds = Double(call.components.seconds) * 1000
            + Double(call.components.attoseconds) / 1e15
        return String(format: "buzz %@ · motor %.0f ms", late, milliseconds)
    }
}

/// The buzz that says rest is over, when the session is being watched.
///
/// A full vibration rather than a taptic tap, which is a deliberate step down
/// in refinement. `UINotificationFeedbackGenerator` turned out to be firing
/// correctly the whole time — tracing the attempt on screen showed it reaching
/// the call, on time, every rest — and it still went unnoticed, because a
/// `.success` tap is built for a phone in your hand and this one is face-up on
/// a bench two feet away. The signal wasn't broken, it was too polite.
enum RestAlert {

    /// Buzzes, and returns when the system says the vibration is done.
    ///
    /// The plain `AudioServicesPlaySystemSound` returns long before the motor
    /// has moved — it hands the request to another process and comes straight
    /// back — so timing that call measures the handoff and nothing else. The
    /// completion form is the only handle on how long the vibration path
    /// actually took, which is the half of the lateness the timer can't
    /// explain.
    static func buzz() async {
        await withCheckedContinuation { continuation in
            AudioServicesPlaySystemSoundWithCompletion(kSystemSoundID_Vibrate) {
                continuation.resume()
            }
        }
    }
}

/// Weight, stepped by the exercise's real increment.
///
/// There is no text field here and nowhere else in the session either: the
/// keyboard never appears mid-set (#4). Stepping by the increment also means
/// the control can only produce loads the equipment can actually make — a
/// dumbbell rack has no 67.5, so the UI shouldn't offer one.

/// Plates, as you'd pick them up (#77).
///
/// One tap per plate rather than one per increment: reaching 185 from an empty
/// bar is a 45 and a 25, not twenty-eight nudges. Each tap adds the plate to
/// every sleeve, because that's how a bar is loaded — a 45 on a two-sleeve
/// barbell is 90 lb.
private struct PlateRow: View {
    let plates: [Double]
    let onAdd: (Double) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add plates")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(plates, id: \.self) { plate in
                            Button { onAdd(plate) } label: {
                                Text(label(plate))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    // Sized for chalky hands, like the stepper.
                                    .frame(minWidth: 54, minHeight: 44)
                                    .background(.fill.tertiary,
                                                in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }

                // Pinned outside the scroll. Adding is only fast if starting
                // over is too, and a reset you have to scroll to find is a
                // reset you don't use — it was off the right edge entirely
                // until a screenshot showed it.
                Button(action: onClear) {
                    Text("Bar")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54, minHeight: 44)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(_ plate: Double) -> String {
        plate == plate.rounded()
            ? String(format: "%.0f", plate)
            : String(format: "%.1f", plate)
    }
}

/// Repeats a step while a button is held, speeding up as it goes (#77).
///
/// Starts slow enough that a held button doesn't overshoot on a short move, and
/// ends fast enough that crossing a hundred pounds isn't a wait.
@MainActor
@Observable
private final class StepRepeater {
    private var task: Task<Void, Never>?

    func start(_ step: @escaping () -> Void) {
        stop()
        task = Task {
            var delay: UInt64 = 220_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                step()
                delay = max(60_000_000, delay - 30_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private struct WeightStepper: View {
    private var gym: GymSettings { .shared }

    let load: Load
    let increment: LoadIncrement
    let plates: String?
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @State private var repeater = StepRepeater()

    var body: some View {
        HStack(spacing: 0) {
            button("minus", action: onDecrement)
            VStack(spacing: 0) {
                Text(load.formatted(in: gym.unit))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(plates ?? "\(increment.formatted) steps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
        // Held rather than tapped twenty-eight times (#77). Accelerates, so a
        // long move is quick and a short one is still controllable.
        .onLongPressGesture(minimumDuration: 0.4, pressing: { isPressing in
            if isPressing { repeater.start(action) } else { repeater.stop() }
        }, perform: {})
    }
}

/// A horizontal row of tappable values, one tap to choose.
///
/// Used for both reps and RPE. Scrollable rather than clipped, so an unusually
/// good set doesn't have to be rounded to whatever fits on screen.
/// Shared with the config sheet (#20), so a stack increment is picked from the
/// same chip row the reps and RPE use — one control to learn, not three.
struct ChoiceRow<Value: Hashable>: View {
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
