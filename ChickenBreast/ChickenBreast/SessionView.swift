//
//  SessionView.swift
//  ChickenBreast
//

import AVFoundation
import AudioToolbox
import SwiftUI
import UIKit
import WeightTrainingCore

/// The main surface: context above, one action below.
///
/// Sized to be read at arm's length while resting, which is the whole design
/// constraint — the phone is on a bench two feet away, not in your hand.
struct SessionView: View {
    @State var model: SessionViewModel
    @State private var isSwapping = false
    @State private var isConfiguring = false
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
        .sheet(isPresented: $isConfiguring) {
            if let exercise = model.current?.exercise {
                ExerciseConfigView(exercise: exercise) { increment, loading in
                    model.updateConfiguration(increment: increment, loading: loading)
                }
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
        let step = exercise.exercise.increment.pounds
        let stepText = step == step.rounded()
            ? String(format: "%.0f", step)
            : String(format: "%.1f", step)
        guard let loading = exercise.exercise.loading else {
            return "Steps of \(stepText) lb"
        }
        guard let base = loading.baseWeight else {
            return "Steps of \(stepText) lb · not weighed"
        }
        let baseText = base.pounds == base.pounds.rounded()
            ? String(format: "%.0f", base.pounds)
            : String(format: "%.1f", base.pounds)
        return "Steps of \(stepText) lb · empty \(baseText) lb"
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

            // Sits with the target because that's what it changes, and because
            // the moment you notice a stack moves in 15s is the moment you're
            // reading this line (#20).
            Button {
                isConfiguring = true
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
    let suggestion: Suggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAccept) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
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
                            Text("\(rung.load) × \(rung.reps)")
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

    /// Held rather than made at the moment of use.
    ///
    /// A generator built inline is released the instant the call returns, and
    /// the Taptic Engine is asked to start from cold by an object that no
    /// longer exists. Keeping one for the life of the banner is what the API
    /// asks for, and it's what makes `prepare()` mean anything.
    @State private var haptics = UINotificationFeedbackGenerator()

    /// TEMPORARY, for #69. A haptic that doesn't fire reports nothing — no
    /// error, no return value — so three fixes have shipped green and changed
    /// nothing on the phone. This puts the attempt on screen where it can be
    /// read without a Mac attached. Delete once the cause is known.
    @State private var trace: [String] = []

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

                    if !trace.isEmpty {
                        Text(trace.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
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
            guard rest.endsAt.timeIntervalSinceNow > 0 else { return }
            note("armed")

            // Wake the Taptic Engine just before it's needed, not at the end.
            //
            // A rest is the one stretch where nobody touches the phone, so by
            // the time the clock runs out the engine has been idle for two or
            // three minutes and a request arriving cold is dropped rather than
            // queued. `prepare()` holds it ready for a moment, which is why
            // this sleeps to the last second or two first and then again to
            // the target.
            await sleep(until: rest.endsAt.addingTimeInterval(-Self.warmup))
            guard !Task.isCancelled else { return }
            haptics.prepare()
            note("warm")

            await sleep(until: rest.endsAt)
            guard !Task.isCancelled else { return }

            // Backgrounding suspends this, so on return the sleep finishes
            // immediately and would buzz for a rest that ended ten minutes ago
            // — after the notification already said so. Only fire if it's
            // actually just happened.
            let overrun = rest.overrun(at: Date())
            guard overrun < 5 else {
                note("late+\(Int(overrun))")
                return
            }

            // The two conditions that make the call a silent no-op, recorded at
            // the moment of the call rather than assumed.
            let category = AVAudioSession.sharedInstance().category == .record
            let saving = ProcessInfo.processInfo.isLowPowerModeEnabled
            note("fire\(category ? " rec" : "")\(saving ? " lpm" : "")")

            haptics.notificationOccurred(.success)

            // A second channel, deliberately cruder. If this one is felt and
            // the generator above isn't, the fault is `UIFeedbackGenerator`
            // rather than anything about when the code runs.
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            note("done")
        }
    }

    /// Appends to the on-screen trace. TEMPORARY, with `trace`.
    @MainActor
    private func note(_ step: String) {
        trace.append(step)
        trace = trace.suffix(6)
    }

    /// How long before the target the engine is warmed. `prepare()` only holds
    /// for a short window, so this is deliberately close to the end.
    private static let warmup: TimeInterval = 2

    private func sleep(until date: Date) async {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
                Text(load.description)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(plates ?? "\(Load(increment.pounds)) steps")
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
