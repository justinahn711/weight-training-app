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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State var model: SessionViewModel
    let onFinish: () -> Void
    /// The lift the swap sheet was opened for, rather than a bare flag (#120).
    ///
    /// Same reason as `configuring`: the sheet is decided over seconds, the mic
    /// keeps listening beneath it, and a spoken "next exercise" moves the day
    /// while it is open. Carrying the subject means the swap lands where it was
    /// aimed.
    @State private var swapping: SessionExercise?

    /// The lift whose configuration is open, rather than a bare flag (#98).
    ///
    /// The sheet then carries the exercise it is editing for the whole of that
    /// presentation. Reading `model.current` inside the sheet builder instead
    /// re-read it on every parent update — and saving is itself a rebuild, so
    /// the screen's subject could move out from under the person editing it.
    @State private var configuring: Exercise?
    /// The lift whose exact-rep sheet is open. Voice can advance beneath a
    /// sheet, so carrying the subject keeps Save aimed where the tap began.
    @State private var enteringReps: RepEntryTarget?
    @State private var enteringWeight: WeightEntryTarget?
    @State private var isChoosingExercise = false
    /// Plate building is the exception path, opened from the breakdown it
    /// edits (#138). It stays open while plates are added, then closes when
    /// the lifter moves to a different exercise.
    @State private var isPlateRowExpanded = false
    /// Pins the logged row being corrected even if voice navigation moves the
    /// workout while its sheet is open.
    @State private var editingSet: ActiveSetEditTarget?
    @State private var showingPartialFinishConfirmation = false
    @State private var voice = VoiceRecognizer()

    var body: some View {
        GeometryReader { geometry in
            if let exercise = model.current {
                if verticalSizeClass == .compact {
                    landscapeLayout(exercise, size: geometry.size)
                } else {
                    stackedLayout(
                        exercise,
                        isCompact: geometry.size.height < 650 || dynamicTypeSize.isAccessibilitySize
                    )
                }
            } else {
                emptySession
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
        }
        .toolbar {
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
        .onChange(of: model.current?.id) { _, _ in
            isPlateRowExpanded = false
        }
        .onChange(of: model.plateOptions) { _, options in
            if options.isEmpty {
                isPlateRowExpanded = false
            }
        }
        .onDisappear { voice.stop() }
        .sheet(item: $swapping) { replaced in
            SwapSheet(
                slotName: replaced.slot?.name,
                candidates: model.swapCandidates(for: replaced),
                search: { model.searchResults($0, for: replaced) },
                onPick: { exercise in
                    model.swap(replaced, to: exercise)
                    swapping = nil
                },
                onCreate: { exercise in
                    model.createAndSwap(replaced, to: exercise)
                    swapping = nil
                }
            )
        }
        .sheet(item: $configuring) { exercise in
            ExerciseConfigView(exercise: exercise) { increment, loading in
                model.updateConfiguration(of: exercise, increment: increment, loading: loading)
            }
        }
        .sheet(item: $enteringReps) { target in
            RepEntrySheet(initialReps: target.reps) { reps in
                model.setPendingReps(reps, for: target.id)
            }
        }
        .sheet(item: $enteringWeight) { target in
            WeightEntrySheet(target: target) { load in
                model.setTypedLoad(load, for: target.id)
            }
        }
        .sheet(isPresented: $isChoosingExercise) {
            exercisePicker
        }
        .sheet(item: $editingSet) { target in
            ActiveSetEditor(target: target) { model.correctSet($0) }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.failure != nil },
                                    set: { if !$0 { model.dismissFailure() } })) {
            Button("OK") { model.dismissFailure() }
        } message: {
            Text(model.failure ?? "")
        }
        .confirmationDialog(
            "Finish this workout?",
            isPresented: $showingPartialFinishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Finish workout") { onFinish() }
            Button("Keep training", role: .cancel) {}
        } message: {
            Text("Your logged sets will stay saved. Exercises you have not started will be skipped.")
        }
    }

    private var emptySession: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Nothing to train",
                systemImage: "figure.strengthtraining.traditional",
                description: Text("This day has no exercises in the library yet.")
            )
            Button("Finish workout", action: onFinish)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Regular portrait keeps the familiar document-over-dock arrangement.
    /// Short portrait and accessibility text compact only the dock, while
    /// status changes move into the document so logging controls never jump.
    private func stackedLayout(_ exercise: SessionExercise, isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            contextScroll(exercise, isCompact: isCompact, includesStatus: isCompact)
            if !isCompact {
                statusBanners
            }
            actionBar(exercise, isCompact: isCompact)
        }
    }

    /// iPhone landscape remains supported deliberately. Width is plentiful
    /// while height is not, so context and action become peers instead of
    /// competing vertically. Rest, voice, and undo live on the left; their
    /// transitions cannot move any control on the right.
    private func landscapeLayout(_ exercise: SessionExercise, size: CGSize) -> some View {
        HStack(spacing: 0) {
            contextScroll(exercise, isCompact: true, includesStatus: true)
                .frame(width: min(size.width * 0.48, max(280, size.width * 0.42)))

            Divider()

            ScrollView {
                actionBar(exercise, isCompact: true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.bar)
        }
    }

    private func contextScroll(
        _ exercise: SessionExercise,
        isCompact: Bool,
        includesStatus: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 12 : 20) {
                header(exercise, isCompact: isCompact)

                if includesStatus {
                    statusBanners
                }

                context(exercise, isCompact: isCompact)

                if isCompact {
                    compactSetRows(exercise)
                    suggestionRow
                }

                if !model.warmupRamp.isEmpty {
                    WarmupBlock(
                        ramp: model.warmupRamp,
                        isExpanded: $model.isWarmupRampExpanded,
                        breakdown: { exercise.exercise.plateBreakdown(for: $0) },
                        onLog: { model.logWarmup($0) },
                        onClear: { model.clearWarmupRamp() }
                    )
                }

                if !isCompact {
                    setRows(exercise)
                }
            }
            .padding(.horizontal, isCompact ? 12 : 20)
            .padding(.bottom, isCompact ? 12 : 24)
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
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
        if let record = model.recentlyLoggedSet {
            LoggedSetBanner(
                record: record,
                unit: gym.unit,
                onUndo: { model.undoRecentlyLoggedSet(id: record.id) },
                onExpire: { model.dismissRecentSetUndo(id: record.id) }
            )
        }
    }

    // MARK: - Context above

    private func header(_ exercise: SessionExercise, isCompact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isChoosingExercise = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.progressLabel)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose exercise")
                .accessibilityValue("\(model.progressLabel), \(exercise.exercise.name)")
                .accessibilityHint("Shows every exercise in this workout")
                if let slot = exercise.slot {
                    // The slot is the job. Naming it makes a swap legible as a
                    // substitution rather than as abandoning the day's shape.
                    Text(slot.name)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Finish") {
                    requestFinish()
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityLabel("Finish workout")
            }
            Button {
                swapping = exercise
            } label: {
                HStack(spacing: 6) {
                    Text(exercise.exercise.name)
                        .font(isCompact ? .title2.bold() : .largeTitle.bold())
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

    private var exercisePicker: some View {
        NavigationStack {
            List(model.session.exercises) { exercise in
                Button {
                    model.select(exerciseID: exercise.id)
                    isChoosingExercise = false
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.exercise.name)
                                .foregroundStyle(.primary)
                            let count = exercise.workingSets.count
                            Text("\(count) working \(count == 1 ? "set" : "sets")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if exercise.id == model.current?.id {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(exercise.exercise.name)
                .accessibilityValue(exercisePickerAccessibilityValue(for: exercise))
                .accessibilityAddTraits(exercise.id == model.current?.id ? .isSelected : [])
            }
            .navigationTitle("Workout exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isChoosingExercise = false }
                }
            }
        }
    }

    private func exercisePickerAccessibilityValue(for exercise: SessionExercise) -> String {
        let count = exercise.workingSets.count
        let progress = "\(count) working \(count == 1 ? "set" : "sets")"
        return exercise.id == model.current?.id ? "Current exercise, \(progress)" : progress
    }

    /// The assumptions worth noticing, rather than every default (#122).
    ///
    /// This line is read every set and edited almost never. Naming the default
    /// increment and the ordinary gym rack made the common case the longest one
    /// on the card, even though neither fact told the lifter anything. Defaults
    /// collapse to a short route label; corrections stay visible because they
    /// are the facts that can explain a surprising target.
    private func configSummary(_ exercise: SessionExercise) -> String {
        let definition = exercise.exercise

        // The increment is rendered in the unit it was marked in rather than
        // the gym's, because that is what it means: a stack measured at 15 lb
        // is a 15 lb stack even in a gym that has since gone metric (#67).
        let customStep = definition.increment
            != definition.equipment.defaultIncrement(in: definition.increment.unit)
        var facts = customStep ? ["\(definition.increment.formatted) steps"] : []

        guard let loading = definition.loading else {
            return facts.first ?? "Standard setup"
        }

        if !loading.usesGymRack {
            facts.append("Own rack")
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
            facts.append("Weigh it to add plates")
            return facts.joined(separator: " · ")
        }
        if loading.availablePlates.isEmpty {
            // Reachable: clear every plate in config while "I've weighed it"
            // is on, then switch it off and save. Weighing is not what fixes
            // this one, so it must not be what the line asks for.
            facts.append("No plates set")
            return facts.joined(separator: " · ")
        }

        // A plate-loaded machine starts unmeasured, so any base here is a fact
        // somebody supplied. A barbell following the gym merely repeats the
        // bar already described in Settings and earns no space on this line.
        let inheritedBar = loading.usesGymRack && loading.unit == gym.unit
            ? gym.config.barWeight
            : loading.unit.standardBar
        if definition.equipment != .barbell || base != inheritedBar {
            // Native, not converted: an empty weight is measured on the
            // apparatus in its own unit. Through `formatted(in:)` the config
            // sheet read back a typed 45.25 while this line said 45.3.
            // When the custom step is marked in the same unit it has already
            // named that unit for the whole line. Repeating it here is the
            // exact visual stutter #122 reported; differing units both stay,
            // because then the distinction is the fact being communicated.
            let repeatsStepUnit = customStep && definition.increment.unit == loading.unit
            let baseText = loading.unit.format(
                base.value(in: loading.unit),
                withSymbol: !repeatsStepUnit
            )
            facts.append("\(baseText) empty")
        }

        return facts.isEmpty ? "Gym setup" : facts.joined(separator: " · ")
    }

    /// What the app assumes, then what it therefore proposes, then what was
    /// actually done. The order is the argument (#100).
    ///
    /// The assumption line used to close this card, under "Last time". A line
    /// reads as belonging to the one above it, so the single statement of what
    /// the app believes about the machine read as a footnote to history — which
    /// is the one thing it has nothing to do with. Above the target it reads as
    /// the target's premise: this step, this empty weight, *therefore* this
    /// number. That is also the direction a correction actually runs. The
    /// number you doubt is the target, and its cause is now the line
    /// immediately above it instead of two lines past it.
    ///
    /// It stays a visible, tinted, one-tap line rather than moving onto the
    /// lift's name or under a long press, because the summary has to stay on
    /// screen wherever the route goes (#95) — a lift with no plate buttons has
    /// no other explanation here. Every other placement would have left this
    /// line where it was and added a *second* way into one sheet.
    private func context(_ exercise: SessionExercise, isCompact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sits directly under the lift's name, which is what it is about,
            // and is still the line you are reading at the moment you notice a
            // stack moves in 15s (#20).
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
            .accessibilityHint("Corrects what the app assumes about this lift")

            // Keeps the once-ever tap from reading as a third row of the pair
            // below, which are read every set and are not controls at all.
            Divider()

            if isCompact {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        targetSummary(exercise)
                        lastTimeSummary(exercise)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        targetSummary(exercise)
                        lastTimeSummary(exercise)
                    }
                }
            } else {
                targetSummary(exercise)
                lastTimeSummary(exercise)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func targetSummary(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Target")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(exercise.prescription.displayLine(in: gym.unit))
                .font(.title2.weight(.semibold))
                .foregroundStyle(exercise.prescription.isColdStart ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastTimeSummary(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last time")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(exercise.lastPerformance?.displayLine(in: gym.unit) ?? "No history yet")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button {
                        editingSet = ActiveSetEditTarget(
                            record: set,
                            exercise: exercise.exercise
                        )
                    } label: {
                        SetRow(number: index + 1, set: set)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edits this logged set")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The newest result is the one checked between sets. Earlier rows remain
    /// one disclosure away for correction, but no longer push it below the
    /// fold on the smallest screen.
    private func compactSetRows(_ exercise: SessionExercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest set")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let latest = exercise.loggedSets.last {
                Button {
                    editingSet = ActiveSetEditTarget(record: latest, exercise: exercise.exercise)
                } label: {
                    SetRow(number: exercise.loggedSets.count, set: latest)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edits this logged set")

                if exercise.loggedSets.count > 1 {
                    DisclosureGroup("Earlier sets (\(exercise.loggedSets.count - 1))") {
                        VStack(spacing: 8) {
                            ForEach(
                                Array(exercise.loggedSets.dropLast().enumerated()),
                                id: \.element.id
                            ) { index, set in
                                Button {
                                    editingSet = ActiveSetEditTarget(
                                        record: set,
                                        exercise: exercise.exercise
                                    )
                                } label: {
                                    SetRow(number: index + 1, set: set)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edits this logged set")
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                }
            } else {
                Text("No sets yet")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var suggestionRow: some View {
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
    }

    // MARK: - Action below

    private func actionBar(_ exercise: SessionExercise, isCompact: Bool = false) -> some View {
        VStack(spacing: isCompact ? 8 : 12) {
            // Beside the number, never as it — chips sit directly above the
            // stepper they're talking about, and the stepper is unaffected
            // until one is tapped.
            if !isCompact {
                suggestionRow
            }

            WeightStepper(
                load: model.pendingLoad,
                increment: exercise.exercise.increment,
                equipment: exercise.exercise.equipment,
                // Read off while loading the bar, so it sits directly under the
                // number it describes (#14).
                plates: model.plateBreakdown?.displayLine,
                isPlateDisclosureExpanded: isPlateRowExpanded,
                onTogglePlates: model.plateOptions.isEmpty ? nil : {
                    withAnimation(.snappy) {
                        isPlateRowExpanded.toggle()
                    }
                },
                onEnterWeight: model.plateOptions.isEmpty ? {
                    enteringWeight = WeightEntryTarget(
                        exercise: exercise.exercise,
                        load: model.pendingLoad
                    )
                } : nil,
                onDecrement: { model.adjustLoad(by: -1) },
                onIncrement: { model.adjustLoad(by: 1) }
            )

            // Building a weight the way it's built in the gym (#77). Only for
            // apparatus that has been measured, since a running total on an
            // unknown bar would be a guess presented as a number.
            if isPlateRowExpanded, !model.plateOptions.isEmpty {
                PlateRow(
                    plates: model.plateOptions,
                    breakdown: model.plateBreakdown,
                    sleeves: exercise.exercise.loading?.sleeves ?? 2,
                    isBarbell: exercise.exercise.equipment.usesOlympicBar,
                    unit: exercise.exercise.loading?.unit ?? gym.unit,
                    onAdd: { model.addPlate($0) },
                    onRemove: { model.removePlate($0) },
                    onClear: { model.clearToBar() }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isCompact {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        repChoices(exercise)
                        rpeChoices
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        repChoices(exercise)
                        rpeChoices
                    }
                }
            } else {
                repChoices(exercise)
                rpeChoices
            }

            Button {
                model.logSet()
            } label: {
                Text("Log Set")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .frame(height: isCompact ? 50 : 56)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button("Warmup") { model.logSet(isWarmup: true) }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                Spacer()
                if model.session.currentIndex > 0 {
                    Button("Back") { model.goBack() }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                if !model.session.isOnLastExercise {
                    Button("Next exercise") { model.advance() }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                } else {
                    Button("Finish workout", action: requestFinish)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, isCompact ? 12 : 20)
        .padding(.top, isCompact ? 8 : 12)
        .padding(.bottom, isCompact ? 4 : 8)
        .background(.bar)
    }

    private func repChoices(_ exercise: SessionExercise) -> some View {
        RepChoiceRow(
            exerciseID: exercise.id,
            values: model.repChoices,
            selected: model.pendingReps,
            usesOtherCount: model.usesOtherRepCount,
            onSelect: { model.setPendingReps($0) },
            onOther: {
                enteringReps = RepEntryTarget(id: exercise.id, reps: model.pendingReps)
            }
        )
        .frame(maxWidth: .infinity)
    }

    private var rpeChoices: some View {
        ChoiceRow(
            caption: "RPE",
            values: RPE.sessionChips,
            isSelected: { $0 == model.pendingRPE },
            label: { $0.value == $0.value.rounded()
                ? String(format: "%.0f", $0.value)
                : String(format: "%.1f", $0.value) },
            onSelect: { model.pendingRPE = $0 }
        )
        .frame(maxWidth: .infinity)
    }

    /// A normal completed workout stays one tap. Finishing while planned lifts
    /// are untouched gets one deliberate checkpoint because it advances the
    /// training state and cannot be mistaken for ordinary exercise navigation.
    private func requestFinish() {
        if model.session.startedCount < model.session.exercises.count {
            showingPartialFinishConfirmation = true
        } else {
            onFinish()
        }
    }
}

/// A short, scoped recovery action for the set that was just written (#8).
///
/// Naming the exact set answers "what will this remove?" before the tap. It
/// expires because older corrections have a safer, explicit home in Today.
private struct LoggedSetBanner: View {
    let record: SetRecord
    let unit: MassUnit
    let onUndo: () -> Void
    let onExpire: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.isWarmup ? "Warmup logged" : "Set logged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(record.load.formatted(in: unit)) × \(record.reps)")
                    .font(.body.weight(.semibold))
            }

            Spacer(minLength: 8)

            Button("Undo", action: onUndo)
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.isWarmup ? "Warmup" : "Set") logged, "
            + "\(record.load.formatted(in: unit)), \(record.reps) reps"
        )
        .accessibilityAction(named: "Undo logged set", onUndo)
        .task(id: record.id) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }
}

/// A sheet target carries both the exercise and the standing value at the
/// moment the alternative entry path was opened.
private struct RepEntryTarget: Identifiable {
    let id: UUID
    let reps: Int
}

private struct WeightEntryTarget: Identifiable {
    let exercise: Exercise
    let load: Load
    var id: UUID { exercise.id }
    var unit: MassUnit { exercise.loading?.unit ?? exercise.increment.unit }
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

    @AppStorage(RestAlertSettings.timingKey) private var showsTiming = RestAlertSettings.timingDefault

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
/// would be a different fix. Enable the readout in Settings while investigating.
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
    let breakdown: PlateBreakdown?
    let sleeves: Int
    let isBarbell: Bool

    /// The rack's unit, so the sizes render at the precision the rack has.
    /// Passed in rather than read from `GymSettings`: a lift can carry a rack
    /// that differs from the gym's, and the plates on the button are that
    /// lift's.
    let unit: MassUnit
    let onAdd: (Double) -> Void
    let onRemove: (Double) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sleeves == 1 ? "Loaded" : "Loaded · each side")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if loadedPlates.isEmpty {
                    Text(breakdown == nil ? "This weight is not an exact plate build" : emptyLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(loadedPlates.enumerated()), id: \.offset) { _, plate in
                                Button { onRemove(plate) } label: {
                                    HStack(spacing: 5) {
                                        Text(label(plate))
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .frame(minWidth: 62, minHeight: 44)
                                    .background(.tint.opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(spokenLabel(plate))")
                                .accessibilityHint(removalHint)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(sleeves == 1 ? "Add plates" : "Add plates · each side")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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
                            .accessibilityLabel("Add \(spokenLabel(plate))")
                            .accessibilityHint(additionHint)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            // A reset is intentionally outside both plate rows. It is not an
            // inverse add action: it removes everything from the apparatus.
            Button(action: onClear) {
                Label(resetLabel, systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Removes all loaded plates")
        }
    }

    private var loadedPlates: [Double] {
        breakdown?.perSide.flatMap { entry in
            Array(repeating: entry.plate, count: entry.count)
        } ?? []
    }

    private var emptyLabel: String {
        isBarbell ? "Bar only" : "Empty apparatus"
    }

    private var resetLabel: String {
        isBarbell ? "Reset to bar" : "Reset to empty"
    }

    private var removalHint: String {
        sleeves == 1 ? "Removes it from the sleeve" : "Removes one from each side"
    }

    private var additionHint: String {
        sleeves == 1 ? "Adds it to the sleeve" : "Adds one to each side"
    }

    /// Plate sizes are native to the rack, so the unit's own rule renders
    /// them. This was a fifth copy of the old one-decimal rule — the buttons
    /// you tap while loading a bar would have offered a "1.2" in a metric gym.
    private func label(_ plate: Double) -> String {
        unit.format(plate, withSymbol: false)
    }

    private func spokenLabel(_ plate: Double) -> String {
        unit.format(plate, withSymbol: true) + " plate"
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
    let equipment: Equipment
    let plates: String?
    let isPlateDisclosureExpanded: Bool
    let onTogglePlates: (() -> Void)?
    let onEnterWeight: (() -> Void)?
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @State private var repeater = StepRepeater()

    var body: some View {
        HStack(spacing: 0) {
            button("minus", caption: decrementCaption, label: decrementLabel, action: onDecrement)
            if let onTogglePlates {
                Button(action: onTogglePlates) {
                    plateReadout(detail: plates)
                        // The whole readout is the target, not the tiny
                        // chevron. It remains easy to hit with chalky hands.
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Plate controls")
                .accessibilityValue(
                    "\(load.formatted(in: gym.unit)), \(plates ?? "not an exact plate build"), "
                    + (isPlateDisclosureExpanded ? "expanded" : "collapsed")
                )
                .accessibilityHint(
                    isPlateDisclosureExpanded ? "Hides plate buttons" : "Shows plate buttons"
                )
            } else {
                Button(action: onEnterWeight ?? {}) {
                    readout(detail: adjustmentLabel, showsEntry: onEnterWeight != nil)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onEnterWeight == nil)
                .accessibilityLabel("Enter exact weight")
                .accessibilityValue(load.formatted(in: gym.unit))
                .accessibilityHint("Plus and minus remain the primary controls")
            }
            button("plus", caption: incrementCaption, label: incrementLabel, action: onIncrement)
        }
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func plateReadout(detail: String?) -> some View {
        VStack(spacing: 1) {
            Text(load.formatted(in: gym.unit))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Text("Adjust plates")
                    .font(.callout.weight(.semibold))
                Image(systemName: isPlateDisclosureExpanded ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
            Text(detail ?? "Not an exact plate build")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func readout(detail: String, showsEntry: Bool) -> some View {
        VStack(spacing: 0) {
            Text(load.formatted(in: gym.unit))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                Text(detail)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if showsEntry {
                    Image(systemName: "square.and.pencil")
                        .accessibilityHidden(true)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func button(_ symbol: String, caption: String?, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.title2.weight(.semibold))
                if let caption { Text(caption).font(.caption2.weight(.semibold)) }
            }
                // Oversized on purpose: tapped with chalky hands, mid-set.
                .frame(width: 64, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        // Held rather than tapped twenty-eight times (#77). Accelerates, so a
        // long move is quick and a short one is still controllable.
        .onLongPressGesture(minimumDuration: 0.4, pressing: { isPressing in
            if isPressing { repeater.start(action) } else { repeater.stop() }
        }, perform: {})
    }

    private var adjustmentLabel: String {
        switch equipment {
        case .dumbbell: return "Dumbbell rack"
        case .machineStack, .cable: return "One notch"
        default: return "\(increment.formatted) steps"
        }
    }

    private var decrementCaption: String? {
        equipment == .dumbbell ? "Previous" : nil
    }

    private var incrementCaption: String? {
        equipment == .dumbbell ? "Next" : nil
    }

    private var decrementLabel: String {
        switch equipment {
        case .dumbbell: return "Previous dumbbell"
        case .machineStack, .cable: return "One notch down"
        default: return "Decrease weight by \(increment.formatted)"
        }
    }

    private var incrementLabel: String {
        switch equipment {
        case .dumbbell: return "Next dumbbell"
        case .machineStack, .cable: return "One notch up"
        default: return "Increase weight by \(increment.formatted)"
        }
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

/// Target-centred shortcuts plus one stable path to every positive rep count.
///
/// `Other` stays fixed beside the scrolling quick choices instead of hiding at
/// the far end or inserting the selected exception among them. That keeps the
/// route visible and the common controls from moving beneath a finger, while
/// the button itself becomes the exact selected number so the form always says
/// what Log Set will record (#131).
private struct RepChoiceRow: View {
    let exerciseID: UUID
    let values: [Int]
    let selected: Int
    let usesOtherCount: Bool
    let onSelect: (Int) -> Void
    let onOther: () -> Void

    /// A quick-chip tap already happened at a visible, intentional location.
    /// Remember it long enough to avoid moving the row after that tap; changes
    /// from navigation or the exact-entry sheet do need recentering.
    @State private var directSelection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reps")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(values, id: \.self) { value in
                                let isSelected = value == selected
                                Button {
                                    directSelection = value
                                    onSelect(value)
                                } label: {
                                    repChip(String(value), selected: isSelected)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(value) reps")
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                .id(value)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .onAppear {
                        scrollToSelected(using: proxy)
                    }
                    .onChange(of: exerciseID) {
                        directSelection = nil
                        scrollToSelected(using: proxy)
                    }
                    .onChange(of: values) {
                        scrollToSelected(using: proxy)
                    }
                    .onChange(of: selected) { _, newValue in
                        if directSelection == newValue {
                            directSelection = nil
                        } else {
                            directSelection = nil
                            // Saving an in-range value through Other has no
                            // selected trailing control, so its chip must be
                            // brought into view when the sheet closes.
                            scrollToSelected(using: proxy)
                        }
                    }
                }

                Button(action: onOther) {
                    repChip(usesOtherCount ? String(selected) : "Other",
                            selected: usesOtherCount)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(usesOtherCount
                                    ? "Change rep count"
                                    : "Enter another rep count")
                .accessibilityValue(usesOtherCount
                                    ? "\(selected) reps selected"
                                    : "Current selection, \(selected) reps")
                .accessibilityAddTraits(usesOtherCount ? .isSelected : [])
            }
        }
    }

    private func repChip(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.title3.weight(selected ? .bold : .medium).monospacedDigit())
            .foregroundStyle(selected ? Color.white : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(minWidth: 54, minHeight: 48)
            .padding(.horizontal, label == "Other" ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.fill.quaternary))
            )
    }

    private func scrollToSelected(using proxy: ScrollViewProxy) {
        if values.contains(selected) {
            proxy.scrollTo(selected, anchor: .center)
        }
    }
}

/// Exact rep entry is secondary: normal target logging still needs only the
/// standing selection and the Log Set button.
private struct RepEntrySheet: View {
    let onSave: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(initialReps: Int, onSave: @escaping (Int) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: String(initialReps))
    }

    private var parsedReps: Int? { TypedReps.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reps", text: $text)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .focused($isFocused)
                        .accessibilityLabel("Rep count")
                        .accessibilityValue(text.isEmpty ? "Empty" : text)
                } footer: {
                    Text("Enter a whole number greater than zero.")
                }
            }
            .navigationTitle("Enter reps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsedReps else { return }
                        onSave(parsedReps)
                        dismiss()
                    }
                    .disabled(parsedReps == nil)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }
}

/// Exact weight entry is a secondary escape hatch behind the standing number.
/// Normal rack/notch stepping remains visible and primary.
private struct WeightEntrySheet: View {
    let target: WeightEntryTarget
    let onSave: (Load) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(target: WeightEntryTarget, onSave: @escaping (Load) -> Bool) {
        self.target = target
        self.onSave = onSave
        _text = State(initialValue: target.unit.format(
            target.load.value(in: target.unit), withSymbol: false
        ))
    }

    private var resolution: TypedWeight.Resolution? {
        TypedWeight.resolve(text, in: target.unit, for: target.exercise)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $text)
                            .keyboardType(.decimalPad)
                            .font(.title2.monospacedDigit())
                            .focused($isFocused)
                            .accessibilityLabel("Exact weight")
                        Text(target.unit.symbol).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Enter the number marked on this equipment.")
                }

                if case .nearest(let requested, let achievable) = resolution {
                    Section {
                        Text("\(requested.formatted(in: target.unit)) cannot be set on this equipment.")
                        Button("Use \(achievable.formatted(in: target.unit))") {
                            if onSave(achievable) { dismiss() }
                        }
                        .font(.body.weight(.semibold))
                    } header: {
                        Text("Not available")
                    } footer: {
                        Text("The nearest achievable weight is offered, never substituted silently.")
                    }
                }
            }
            .navigationTitle("Enter weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard case .exact(let load) = resolution else { return }
                        if onSave(load) { dismiss() }
                    }
                    .disabled(!isExact)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var isExact: Bool {
        if case .exact = resolution { return true }
        return false
    }
}
