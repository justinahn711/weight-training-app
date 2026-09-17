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
    @Environment(\.scenePhase) private var scenePhase
    /// Read once per render and threaded into every `Theme.spring`/`.quick`
    /// call in this file — see `Theme`'s own doc for why the accessor takes
    /// this as an argument rather than reaching past it (a P1 finding from
    /// `/impeccable audit`: this screen shipped several springs with no
    /// Reduce Motion alternative).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// The add-exercise sheet from #175 — "the rack is free, I'll do one
    /// more." Reuses the shape of #137's pre-session add sheet (search the
    /// library, no exercise creation here), rebuilt here rather than shared:
    /// that sheet is a `private` type inside `ContentView.swift`.
    @State private var isAddingExercise = false
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
        sessionContent
            // A record is felt before it is read: the phone is often on the
            // floor when the set ends. `.success` is the system's own "you
            // did the thing" pattern, distinct from the rest-over buzz.
            .sensoryFeedback(.success, trigger: model.recentRecord?.set.id) { _, new in new != nil }
            // The haptic reaches a phone on the floor; neither it nor the
            // gold banner reaches VoiceOver. Both moments that change what
            // the lifter should believe — a record, and the screen moving to
            // a different lift on its own — are announced, not just drawn.
            .onChange(of: model.recentRecord?.set.id) { _, new in
                guard new != nil, let record = model.recentRecord else { return }
                AccessibilityNotification.Announcement(
                    "Personal record, \(record.set.load.formatted(in: gym.unit)), \(record.set.reps) reps"
                ).post()
            }
            .onChange(of: model.autoAdvancedFrom?.id) { _, new in
                guard new != nil, let name = model.current?.exercise.name else { return }
                AccessibilityNotification.Announcement("Moved on to \(name)").post()
            }
            // The spring behind every banner arriving or leaving (task 3).
            // Keyed on the states that add or remove one, so a tick of the
            // rest clock never re-runs it.
            .animation(Theme.spring(reduceMotion: reduceMotion), value: model.rest?.startedAt)
            .animation(Theme.spring(reduceMotion: reduceMotion), value: model.recentlyLoggedSet?.id)
            .animation(Theme.spring(reduceMotion: reduceMotion), value: model.pendingAdvance?.id)
            .animation(Theme.spring(reduceMotion: reduceMotion), value: model.autoAdvancedFrom?.id)
            .animation(Theme.spring(reduceMotion: reduceMotion), value: model.session.currentIndex)
            // `confirmationDialog` can adapt to an anchored popover. The
            // partial-finish checkpoint must stay thumb-reachable on every
            // iPhone, so use a real bottom sheet instead (#158).
            .sheet(isPresented: $showingPartialFinishConfirmation) {
                PartialFinishSheet(
                    onFinish: {
                        showingPartialFinishConfirmation = false
                        onFinish()
                    },
                    onKeepTraining: {
                        showingPartialFinishConfirmation = false
                    }
                )
            }
    }

    private var sessionContent: some View {
        GeometryReader { geometry in
            if let exercise = model.current {
                if verticalSizeClass == .compact {
                    landscapeLayout(exercise, size: geometry.size)
                } else {
                    stackedLayout(
                        exercise,
                        height: geometry.size.height,
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
            // A relaunch can arrive with a lock-screen set and timer already
            // in ActivityKit. Adopt those before publishing so this view never
            // replaces them with the draft's deliberately transient state.
            model.reconcileLiveActivityActions()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.leaveSession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.reconcileLiveActivityActions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        if voice.isListening { voice.stop() } else { await voice.start() }
                    }
                } label: {
                    Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic")
                        .symbolEffect(.pulse, isActive: voice.isListening && !reduceMotion)
                }
                // Listening was conveyed by a filled glyph and a pulse, both
                // invisible to a screen reader — so the one control whose whole
                // point is hands-free use could not report whether it was on.
                .accessibilityLabel(voice.isListening ? "Stop listening" : "Log a set by voice")
                .accessibilityValue(voice.isListening ? "Listening" : "Off")
                .accessibilityIdentifier("session.microphone")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingExercise = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add exercise")
                .accessibilityHint("Adds a lift to today's workout, next or at the end")
                .accessibilityIdentifier("session.exercise.add")
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
            ExerciseConfigView(exercise: exercise) { increment, loading, restOverride in
                model.updateConfiguration(
                    of: exercise,
                    increment: increment,
                    loading: loading,
                    restOverride: restOverride
                )
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
        .sheet(isPresented: $isAddingExercise) {
            AddExerciseSheet(
                search: { model.addableExercises($0) },
                onAdd: { exercise, placement in
                    model.addExercise(exercise, placement: placement)
                    isAddingExercise = false
                }
            )
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
    private func stackedLayout(_ exercise: SessionExercise, height: CGFloat, isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            contextScroll(exercise, isCompact: isCompact, includesStatus: isCompact)
            if !isCompact {
                statusBanners
            }
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility text sizes the bar's controls outgrow the
                // space under the scroll view. A fixed bar then compresses
                // them: Log Set's label spilled over "Finish workout" and
                // covered it. Scrolling, as landscape already does, keeps
                // every control whole and reachable (critique, adapt).
                ScrollView {
                    actionBar(exercise, isCompact: isCompact)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: height * 0.6)
                .layoutPriority(1)
                .background(.bar)
            } else {
                actionBar(exercise, isCompact: isCompact)
            }
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
                    // A new lift arrives from the side, on the spring the
                    // body keys on `currentIndex`; the old one fades under it.
                    // Reduce Motion drops the slide for a plain crossfade —
                    // the exercise still visibly changes, nothing moves
                    // across the screen to get there.
                    .id(exercise.id)
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))

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
        // `heard` and `rest` are independent optionals on the model — a rest
        // can easily be running while a voice parse is awaiting confirmation.
        // These used to be `if / else if`, so the rest banner (and the
        // running clock it's the only visible face of) was hidden for as
        // long as the heard banner was up, and did not return if the rest
        // ended while it was hidden. That read as "the rest timer vanished"
        // (#173, first half) even though the timer itself was never touched.
        // Independent `if`s let both stack, the same way the logged-set
        // banner already stacks below either of them.
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
        }
        if let next = model.pendingAdvance {
            NextUpCard(
                next: next,
                isResting: model.rest != nil,
                onStay: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.stayOnCurrentExercise() } },
                onGo: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.skipRest() } }
            )
            .transition(Theme.edgeTransition(reduceMotion: reduceMotion))
        }
        if let from = model.autoAdvancedFrom {
            AutoAdvancedBanner(
                from: from,
                onBack: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.undoAutoAdvance() } }
            )
            .transition(Theme.edgeTransition(reduceMotion: reduceMotion))
        }
        if let rest = model.rest {
            RestBanner(
                rest: rest,
                onSkip: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.skipRest() } },
                onComplete: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.restDidComplete() } }
            )
            .transition(Theme.edgeTransition(reduceMotion: reduceMotion))
        }
        // No resident "Start Rest" row when nothing is running (#173's
        // control, relocated): a manual rest is a once-a-session correction,
        // so it lives in the action bar's More menu beside Extra warmup
        // instead of spending a row on every set (critique, distill).
        if let record = model.recentlyLoggedSet {
            LoggedSetBanner(
                record: record,
                personalRecord: model.recentRecord?.set.id == record.id ? model.recentRecord : nil,
                unit: gym.unit,
                onUndo: { withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.undoRecentlyLoggedSet(id: record.id) } }
            )
            .transition(Theme.edgeTransition(reduceMotion: reduceMotion))
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
                        // One line, shrinking before wrapping: at accessibility
                        // sizes "1 of 6" broke onto three lines.
                        Text(model.progressLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
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
                .accessibilityIdentifier("session.exercise.choose")
                if dynamicTypeSize.isAccessibilitySize {
                    // The slot caption can't fit beside the progress label and
                    // Finish at these sizes; it only ever truncated to "Inclin…".
                    EmptyView()
                } else if let slot = exercise.slot {
                    // The slot is the job. Naming it makes a swap legible as a
                    // substitution rather than as abandoning the day's shape.
                    Text(slot.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // No slot means this lift was added rather than planned —
                    // either from the pre-session roster (#137) or mid-session
                    // (#175). Same caption #137's roster preview already uses,
                    // so the word means the same thing in both places.
                    Text("Added for today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Only while the footer offers "Next exercise". On the last
                // lift the footer's own "Finish workout" is the forward
                // action, and two Finish controls on one screen read as two
                // different things (critique, distill). Neutral rather than
                // orange: ending early is available, not encouraged.
                // Kept at accessibility text sizes, where the scrolling action
                // bar can hold the footer's Finish out of view.
                if !model.session.isOnLastExercise || dynamicTypeSize.isAccessibilitySize {
                    Button {
                        requestFinish()
                    } label: {
                        Text("Finish")
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // contentShape makes the reserved 44pt height the real
                    // tappable and audited region (#114).
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Finish workout")
                    .accessibilityIdentifier("session.finish.header")
                }
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
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("Swap \(exercise.exercise.name)")
            .accessibilityHint("Chooses a different exercise for this slot")
            .accessibilityIdentifier("session.exercise.swap")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var exercisePicker: some View {
        NavigationStack {
            List(model.session.exercises) { exercise in
                Button {
                    withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.select(exerciseID: exercise.id) }
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
    /// The full Target / Last time card earns its space before the first
    /// set, when both lines inform the weight about to be chosen. After a
    /// working set is logged, or on a first outing where both lines would
    /// only say "nothing yet", it collapses to one line so the upper half of
    /// the screen stops reading as a form (critique, distill).
    @ViewBuilder
    private func context(_ exercise: SessionExercise, isCompact: Bool = false) -> some View {
        let isFirstOuting = exercise.prescription.isColdStart && exercise.lastPerformance == nil
        if isFirstOuting || !exercise.workingSets.isEmpty {
            collapsedContext(exercise, isFirstOuting: isFirstOuting)
        } else {
            fullContext(exercise, isCompact: isCompact)
        }
    }

    private func collapsedContext(_ exercise: SessionExercise, isFirstOuting: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isFirstOuting ? "First time on this lift" : collapsedLine(exercise))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if isFirstOuting {
                    Text("Set a weight, then log it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button {
                configuring = exercise.exercise
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure \(exercise.exercise.name)")
            .accessibilityValue(configSummary(exercise))
            .accessibilityHint("Corrects what the app assumes about this lift")
            .accessibilityIdentifier("session.exercise.configure")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func collapsedLine(_ exercise: SessionExercise) -> String {
        var parts = ["Target \(exercise.prescription.displayLine(in: gym.unit))"]
        if let last = exercise.lastPerformance {
            parts.append("Last \(last.displayLine(in: gym.unit))")
        }
        return parts.joined(separator: " · ")
    }

    private func fullContext(_ exercise: SessionExercise, isCompact: Bool) -> some View {
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
                .foregroundStyle(.secondary)
                // A caption's glyphs are 14pt, and contentShape without a
                // minimum shapes exactly that — so the route into every
                // per-lift setting was a 14pt target, in a room, mid-set. The
                // audit measured it; nobody had (#114).
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure \(exercise.exercise.name)")
            .accessibilityValue(configSummary(exercise))
            .accessibilityHint("Corrects what the app assumes about this lift")
            .accessibilityIdentifier("session.exercise.configure")

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
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(exercise.loggedSets.enumerated()), id: \.element.id) { index, set in
                    Button {
                        editingSet = ActiveSetEditTarget(
                            record: set,
                            exercise: exercise.exercise
                        )
                    } label: {
                        SetRow(number: index + 1, set: set, isRecord: model.recordSetIDs.contains(set.id))
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
                    SetRow(number: exercise.loggedSets.count, set: latest,
                           isRecord: model.recordSetIDs.contains(latest.id))
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
                                    SetRow(number: index + 1, set: set,
                                           isRecord: model.recordSetIDs.contains(set.id))
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
                    .foregroundStyle(.secondary)
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
                            onAccept: { withAnimation(Theme.quick(reduceMotion: reduceMotion)) { model.accept(suggestion) } },
                            onDismiss: { withAnimation(Theme.quick(reduceMotion: reduceMotion)) { model.dismiss(suggestion) } }
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Action below

    private func actionBar(_ exercise: SessionExercise, isCompact: Bool = false) -> some View {
        // 10 rather than 12 between rows: the bigger stepper and Log Set
        // below (task 6) are paid for here and in the row heights, so the
        // bar stays under the ceiling #205 set and its UI test enforces.
        VStack(spacing: isCompact ? 8 : 10) {
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
                isWeightUnset: !model.canLogSet,
                onTogglePlates: model.plateOptions.isEmpty ? nil : {
                    withAnimation(Theme.quick(reduceMotion: reduceMotion)) {
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
                .transition(Theme.edgeTransition(reduceMotion: reduceMotion))
            }

            // Reps and RPE, always visible, one tap per step.
            //
            // Used to be a disclosure hiding two horizontally-scrolling chip
            // rows (#205's ~130pt worry). A platform-conformance audit named
            // that a web-shaped control standing in for a native stepper: the
            // selected chip auto-centered in an extent nobody could see the
            // edges of, sighted or not, and a drag that drifted vertically
            // lost itself to the page scroll. Two `InlineStepper`s at button
            // scale answer both at once — nothing scrolls anywhere in the
            // action bar, and the ~130pt worry doesn't apply: a stepper row
            // costs about what the disclosure header alone used to, not what
            // two open chip rows did.
            //
            // Both default to the prescribed or last-used value, so `Log Set`
            // already works with neither ever touched — this row is the
            // correction path, one tap at a time, never a scroll.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    repsStepper(exercise)
                    rpeStepper
                }
            } else {
                HStack(spacing: 8) {
                    repsStepper(exercise)
                    rpeStepper
                }
            }

            Button {
                // Once this set is written the weight is settled — the next
                // set inherits it, and the plate buttons have nothing left to
                // correct until something changes. Leaving the row open just
                // pushes the set rows underneath it down for the rest of the
                // exercise (#170).
                //
                // `logSet` returns nothing, and `model.failure` isn't cleared
                // on success, so a stale failure from something unrelated
                // could make "did this call fail" unreadable from `failure`
                // alone. Comparing before/after sidesteps that: `commit` only
                // ever *sets* `failure` on its own catch, so if the string is
                // unchanged this call didn't fail, whatever the value was
                // going in.
                let failureBeforeLogging = model.failure
                withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.logSet() }
                if model.failure == failureBeforeLogging {
                    withAnimation(Theme.quick(reduceMotion: reduceMotion)) { isPlateRowExpanded = false }
                }
            } label: {
                // The values on the button, so confirming them is the same
                // glance as tapping: one look says "185 × 8, yes" and one tap
                // logs it. `Log Set` stays the accessible name (the UI tests
                // and VoiceOver both find it by that), the numbers are its
                // value.
                //
                // Near-black on the orange, not white: white measured 2.53:1
                // (and 2.23:1 for the subtitle at 85% opacity), failing even
                // large-text contrast on the most-read control in the app.
                // `minHeight`, not a fixed height, so larger text grows the
                // button instead of clipping it.
                VStack(spacing: 0) {
                    Text(logSetTitle)
                        .font(isCompact ? .title3.bold() : .title2.bold())
                    Text(model.canLogSet ? logSetSummary : "Set a weight first")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(Theme.quick(reduceMotion: reduceMotion), value: logSetSummary)
                }
                .foregroundStyle(model.canLogSet ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(minHeight: isCompact ? 56 : 62)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(!model.canLogSet)
            .accessibilityLabel(logSetTitle)
            .accessibilityValue(model.canLogSet ? logSetSummary : "Set a weight first")
            .accessibilityIdentifier("session.log-set")

            // Previous lift, a More menu, and the one forward action.
            //
            // #207 put Back, Extra warmup and Next on one row with Extra
            // warmup as physical separation between the two navigation
            // controls. A critique counted 13 tappable targets in this bar
            // against four real decisions, so the two once-a-session actions
            // (a manual rest, #173, and an extra warmup, #157) now share one
            // menu that keeps that same middle position — the separation
            // #177 asked for survives, the clutter doesn't. "Previous lift"
            // rather than "Back": the nav bar's back chevron leaves the
            // session, and one word meant both.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    forwardAction
                    HStack(spacing: 8) {
                        previousLiftButton
                        Spacer(minLength: 8)
                        moreMenu
                    }
                }
            } else {
                HStack(spacing: 8) {
                    previousLiftButton
                    Spacer(minLength: 8)
                    moreMenu
                    Spacer(minLength: 8)
                    forwardAction
                }
            }
        }
        .padding(.horizontal, isCompact ? 12 : 20)
        .padding(.top, isCompact ? 8 : 12)
        .padding(.bottom, isCompact ? 4 : 8)
        .background(.bar)
        // `.contain` keeps every child individually reachable — this isn't
        // `.combine` — while giving the bar itself a queryable frame, which
        // is what a regression test for #205's actual claim (a real pt
        // number, not a font-metrics estimate) needs to read off the
        // simulator.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.actionBar")
    }

    private func repsStepper(_ exercise: SessionExercise) -> some View {
        let reps = model.pendingReps
        let text = "\(reps) rep\(reps == 1 ? "" : "s")"
        return InlineStepper(
            identifierPrefix: "session.reps",
            caption: "Reps",
            valueText: text,
            accessibilityValue: text,
            onTapValue: {
                enteringReps = RepEntryTarget(id: exercise.id, reps: model.pendingReps)
            },
            onDecrement: { model.adjustReps(by: -1) },
            onIncrement: { model.adjustReps(by: 1) }
        )
        .frame(maxWidth: .infinity)
    }

    /// No tap-to-enter, unlike reps: RPE is a bounded, discrete scale
    /// (`RPE.sessionChips`), not an open count, so there's no "exact value
    /// outside quick reach" case for a sheet to solve.
    private var rpeStepper: some View {
        InlineStepper(
            identifierPrefix: "session.rpe",
            caption: "RPE",
            valueText: model.pendingRPE.description,
            accessibilityValue: model.pendingRPE.description,
            onDecrement: { model.adjustRPE(by: -1) },
            onIncrement: { model.adjustRPE(by: 1) }
        )
        .frame(maxWidth: .infinity)
    }

    /// "Log Warmup" while the button would log the next ramp rung: it used
    /// to say "Log Set" while quietly writing a warmup (#206's behaviour,
    /// now named on the control that does it).
    private var logSetTitle: String {
        model.isOnActiveWarmupRung ? "Log Warmup" : "Log Set"
    }

    @ViewBuilder
    private var previousLiftButton: some View {
        if model.session.currentIndex > 0 {
            Button {
                withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.goBack() }
            } label: {
                Label("Previous lift", systemImage: "chevron.backward")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("session.exercise.previous")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.startRest() }
            } label: {
                Label("Start rest", systemImage: "timer")
            }
            .disabled(model.rest != nil)
            .accessibilityIdentifier("session.more.startRest")

            Button {
                model.logSet(isWarmup: true)
            } label: {
                Label("Log extra warmup", systemImage: "flame")
            }
            .disabled(!model.canLogSet)
            .accessibilityIdentifier("session.more.extraWarmup")
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .tint(Theme.quietTint)
        .accessibilityLabel("More actions")
        .accessibilityHint("Start a rest without logging, or log an extra warmup set")
        .accessibilityIdentifier("session.more")
    }

    /// The one orange control besides Log Set: the way forward.
    @ViewBuilder
    private var forwardAction: some View {
        if !model.session.isOnLastExercise {
            Button {
                withAnimation(Theme.spring(reduceMotion: reduceMotion)) { model.advance() }
            } label: {
                Label("Next exercise", systemImage: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .accessibilityIdentifier("session.exercise.next")
        } else {
            Button(action: requestFinish) {
                Text("Finish workout")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .accessibilityIdentifier("session.finish.footer")
        }
    }

    /// What one tap of `Log Set` will write, spelled on the button itself.
    private var logSetSummary: String {
        "\(model.pendingLoad.formatted(in: gym.unit)) × \(model.pendingReps)"
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

private struct PartialFinishSheet: View {
    let onFinish: () -> Void
    let onKeepTraining: () -> Void

    var body: some View {
        // The explanation scrolls; the two answers are pinned to the bottom.
        // At accessibility text sizes the whole stack outgrew the medium
        // detent and "Finish workout" sat below the fold, unreachable — a
        // test that was meant to catch this had been launching at default
        // size because its content-size argument was misspelled.
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Finish this workout?")
                        .font(.title2.bold())
                    Text("Your logged sets stay saved. Unstarted exercises will be skipped.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button(action: onFinish) {
                    Text("Finish workout")
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("finish.confirmation.finish")

                Button(action: onKeepTraining) {
                    Text("Keep training")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .tint(Theme.quietTint)
                .accessibilityIdentifier("finish.confirmation.cancel")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finish.confirmation.sheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A short, scoped recovery action for the set that was just written (#8).
///
/// Naming the exact set answers "what will this remove?" before the tap. It
/// stays until the next set replaces it or the lift changes; older
/// corrections have a safer, explicit home in Today.
private struct LoggedSetBanner: View {
    let record: SetRecord
    /// Set when this set set one (task 2): the banner turns gold, says
    /// which record, and the phone buzzes once (see `sensoryFeedback` on
    /// the session body).
    var personalRecord: PersonalRecord? = nil
    let unit: MassUnit
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: personalRecord == nil ? "checkmark.circle.fill" : "trophy.fill")
                .foregroundStyle(personalRecord == nil ? Theme.done : Theme.record)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(personalRecord == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.record))
                Text("\(record.load.formatted(in: unit)) × \(record.reps)")
                    .font(.body.weight(.semibold))
            }

            Spacer(minLength: 8)

            Button("Undo", action: onUndo)
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Theme.quietTint)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        // `.fill.tertiary` rather than `.bar`: on `.bar` an ordinary logged
        // set was indistinguishable from the action bar beneath it.
        .background(personalRecord == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Theme.record.opacity(0.16)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), "
            + "\(record.load.formatted(in: unit)), \(record.reps) reps"
        )
        .accessibilityAction(named: "Undo logged set", onUndo)
        // No expiry timer. It used to vanish after 8 seconds — shorter than
        // the walk back from the rack, and too short to reach through
        // VoiceOver's actions menu (WCAG 2.2.1). It now stays until the next
        // set replaces it or the lift changes, both handled by the model.
    }

    private var title: String {
        guard let personalRecord else { return record.isWarmup ? "Warmup logged" : "Set logged" }
        switch personalRecord.kind {
        case .heaviest: return "Personal record · heaviest ever"
        case .reps(_, let load): return "Personal record · most reps at \(load.formatted(in: unit))"
        case .estimatedMax: return "Personal record · best estimated max"
        }
    }
}

/// The move the session is about to make on its own (task 4): shown for the
/// whole rest after the set that matched last time's count, so it is never a
/// surprise. `Stay` is the big target — it is the one that has to be easy to
/// hit when the answer is "one more".
private struct NextUpCard: View {
    let next: SessionExercise
    let isResting: Bool
    let onStay: () -> Void
    let onGo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(isResting ? "Next up when rest ends" : "Next up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(next.exercise.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Stay", action: onStay)
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Theme.quietTint)
                .controlSize(.large)
                .accessibilityHint("Keeps this lift on screen for another set")
                .accessibilityIdentifier("session.nextUp.stay")

            Button(action: onGo) {
                Image(systemName: "chevron.forward")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Go to \(next.exercise.name) now")
            .accessibilityIdentifier("session.nextUp.go")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.fill.tertiary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.nextUp")
    }
}

/// What the automatic move leaves behind: where you came from and the way
/// back. It stays until the first set on the new lift or another move — a
/// timer here meant coming back from the rack to a different exercise with
/// no trace of how it happened.
private struct AutoAdvancedBanner: View {
    let from: SessionExercise
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.done)

            VStack(alignment: .leading, spacing: 1) {
                Text("Moved on")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(from.exercise.name) done")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Go back", action: onBack)
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Theme.quietTint)
                .controlSize(.large)
                .accessibilityIdentifier("session.autoAdvanced.back")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.fill.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Moved on, \(from.exercise.name) done")
        .accessibilityAction(named: "Back to \(from.exercise.name)", onBack)
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
    var isRecord = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Text("\(set.load.formatted(in: gym.unit)) × \(set.reps)")
                .font(.title3.weight(.medium).monospacedDigit())

            if isRecord {
                Text("PR")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.recordText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.record, in: Capsule())
                    .accessibilityLabel("Personal record")
            }

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

/// Adding a lift to the running day (#175) — "the rack is free, I'll do one
/// more."
///
/// Mirrors #137's pre-session add sheet in shape: search the whole library,
/// no exercise creation here. A lift invented at the rack still has no
/// history, no increment, and no muscle tags — that's the same reasoning
/// `SwapSheet` gives for keeping its own search plain, and it applies just as
/// much to an addition as to a swap. That pre-session sheet lives as a
/// `private` type inside `ContentView.swift`, which this file doesn't own, so
/// this is a second, smaller copy rather than a shared component.
private struct AddExerciseSheet: View {
    let search: (String) -> [Exercise]
    let onAdd: (Exercise, Session.ExercisePlacement) -> Void

    @State private var query = ""
    @State private var placement: Session.ExercisePlacement = .next
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Where", selection: $placement) {
                        Text("Next").tag(Session.ExercisePlacement.next)
                        Text("End of workout").tag(Session.ExercisePlacement.end)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("session.addExercise.placement")
                }
                .listRowSeparator(.hidden)

                Section("Exercise library") {
                    let results = search(query)
                    if results.isEmpty {
                        Text(query.isEmpty ? "Nothing left to add" : "No matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(results) { exercise in
                            row(exercise)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search exercises")
            .navigationTitle("Add exercise")
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
            onAdd(exercise, placement)
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
        .accessibilityIdentifier("session.addExercise.candidate.\(exercise.name)")
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
            // Title and reason are two labels sighted readers take in at once;
            // combined they are one announcement rather than two stops.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(suggestion.title(in: gym.unit)). \(suggestion.reason)")
            .accessibilityHint("Double tap to apply this suggestion.")
            .accessibilityIdentifier("suggestion.accept")

            // A sibling of the accept button, never inside its label — a nested
            // button never receives its own taps.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    // 44pt, not 28: the audit floor, on a control tapped
                    // mid-set right beside the chip it would dismiss.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // "X mark" said nothing about which of several suggestions this
            // would discard — the glyph's meaning was entirely positional.
            .accessibilityLabel("Dismiss suggestion: \(suggestion.title(in: gym.unit))")
            .accessibilityIdentifier("suggestion.dismiss")
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

/// The warmup ramp (#15).
///
/// Collapsed by default on most exercises — the weights are obvious once
/// you've done the lift twice — but open for the first exercise of the day
/// (#157), where it's read rather than glanced at, and where being invisible
/// once cost the feature its own discoverability. Expanded, each rung is
/// tappable and logs exactly what it shows, so ramping never means dialling
/// the stepper up and back down.
private struct WarmupBlock: View {
    private var gym: GymSettings { .shared }

    let ramp: [WarmupSet]
    @Binding var isExpanded: Bool
    let breakdown: (Load) -> PlateBreakdown?
    let onLog: (WarmupSet) -> Void
    let onClear: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Clear is a sibling of the disclosure button, not nested inside its
            // label. A button inside another button's label never receives its
            // own taps — the outer gesture wins — which would make #15's "one
            // tap to clear" quietly toggle the block open instead.
            HStack(spacing: 8) {
                Button {
                    withAnimation(Theme.quick(reduceMotion: reduceMotion)) { isExpanded.toggle() }
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
                .frame(minHeight: 44)
                .accessibilityLabel("Warmup ramp")
                .accessibilityValue(isExpanded ? "Expanded, \(summary)" : "Collapsed, \(summary)")
                .accessibilityHint(isExpanded ? "Hides the suggested warmup sets" : "Shows the suggested warmup sets")
                .accessibilityIdentifier("session.warmup.disclosure")

                Button("Clear", action: onClear)
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear warmup ramp")
                    .accessibilityHint("Dismisses the remaining suggested warmup sets for this lift")
                    .accessibilityIdentifier("session.warmup.clear")
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
                    .frame(minHeight: 44)
                    .accessibilityLabel(
                        "Log warmup, \(rung.load.formatted(in: gym.unit)), \(rung.reps) reps"
                    )
                    .accessibilityIdentifier("session.warmup.log.\(rung.id)")
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
    /// Fired once when the countdown reaches zero — the clock this banner
    /// keeps is the only one the session has, so the model hears about the
    /// end of a rest from here. Fires immediately for a rest that was
    /// already over when the banner appeared (a reconciled relaunch).
    var onComplete: () -> Void = {}

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
                        .stroke(done ? Theme.done : Color.accentColor,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 0) {
                    Text(done ? "Rest complete" : "Resting")
                        .font(.caption.weight(.semibold))
                        // At accessibility sizes this hyphenated to "REST-".
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    // Fixed rather than `@ScaledMetric` (a platform audit's
                    // P3, tried and reverted): scaling this relative to
                    // `.largeTitle` measured 22pt taller even at the
                    // system's own default category, which pushed the
                    // action bar over the #205 340pt ceiling before any
                    // Dynamic Type setting was touched. `minimumScaleFactor`
                    // below already keeps this from clipping when the
                    // surrounding text grows; growing it too costs more
                    // than the audit's own "polish, low real-world impact"
                    // rating for this finding was worth chasing further.
                    Text(rest.displayTime(at: context.date))
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(done ? Theme.done : Color.primary)
                        .contentTransition(.numericText())

                    if showsTiming, let report {
                        Text(report.line)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button(action: onSkip) {
                    // Never truncated: at accessibility sizes it showed "S".
                    Text("Skip").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                    .font(.body.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Theme.quietTint)
                    .controlSize(.large)
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
        // Keyed by the whole timer rather than just `rest.setID`: a rest
        // started by hand or by voice has no set to key on (`setID` is nil,
        // #173), and two of those in a row would otherwise share the same
        // `nil` key and never re-arm this task for the second one. `startedAt`
        // always differs, so keying on the full `Hashable` value re-arms for
        // every rest, set-anchored or not, and still cancels when a set is
        // undone or the rest is skipped — the view goes away with it either way.
        .task(id: rest) {
            let deadline = rest.endsAt
            guard deadline.timeIntervalSinceNow > 0 else {
                onComplete()
                return
            }

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

            // Before the lateness guard below: that guard is about whether a
            // buzz is still worth giving, and a move that was announced for
            // the whole rest is still owed however late the clock ran.
            onComplete()

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
    /// True when no weight has been set on equipment where zero isn't a real
    /// load. The readout shows a dash rather than a "0 lb" that reads as a
    /// value (critique, harden).
    var isWeightUnset = false
    let onTogglePlates: (() -> Void)?
    let onEnterWeight: (() -> Void)?
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var repeater = StepRepeater()

    var body: some View {
        HStack(spacing: 0) {
            button("minus", caption: decrementCaption, label: decrementLabel, action: onDecrement)
            if let onTogglePlates {
                Button(action: onTogglePlates) {
                    plateReadout(detail: plates)
                        // The whole readout is the target, not the tiny
                        // chevron. It remains easy to hit with chalky hands.
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Plate controls")
                .accessibilityValue(
                    "\(isWeightUnset ? "No weight set" : load.formatted(in: gym.unit)), \(plates ?? "not an exact plate build"), "
                    + (isPlateDisclosureExpanded ? "expanded" : "collapsed")
                )
                .accessibilityHint(
                    isPlateDisclosureExpanded ? "Hides plate buttons" : "Shows plate buttons"
                )
            } else {
                Button(action: onEnterWeight ?? {}) {
                    readout(detail: adjustmentLabel, showsEntry: onEnterWeight != nil)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onEnterWeight == nil)
                .accessibilityLabel("Enter exact weight")
                .accessibilityValue(isWeightUnset ? "No weight set" : load.formatted(in: gym.unit))
                .accessibilityHint("Plus and minus remain the primary controls")
            }
            button("plus", caption: incrementCaption, label: incrementLabel, action: onIncrement)
        }
        .padding(.vertical, 4)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func plateReadout(detail: String?) -> some View {
        VStack(spacing: 1) {
            Text(displayedLoad)
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(Theme.quick(reduceMotion: reduceMotion), value: load)
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
            Text(displayedLoad)
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(Theme.quick(reduceMotion: reduceMotion), value: load)
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

    private var displayedLoad: String {
        isWeightUnset ? "—" : load.formatted(in: gym.unit)
    }

    private func button(_ symbol: String, caption: String?, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.title.weight(.semibold))
                // Dropped at accessibility sizes, where "Previous"/"Next" only
                // truncated to "Pr…"; the spoken label still says it.
                if let caption, !dynamicTypeSize.isAccessibilitySize {
                    Text(caption).font(.caption2.weight(.semibold))
                }
            }
                // Oversized on purpose: tapped with chalky hands, mid-set.
                .frame(width: 72, height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(symbol == "minus" ? "session.weight.decrement" : "session.weight.increment")
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
/// Scrollable rather than clipped, so an unusual value doesn't have to be
/// rounded to whatever fits on screen. Serves the exercise config sheet
/// (#20); the session screen's reps and RPE moved to `InlineStepper`.
struct ChoiceRow<Value: Hashable>: View {
    let caption: String
    let values: [Value]
    let isSelected: (Value) -> Bool
    let label: (Value) -> String
    let onSelect: (Value) -> Void

    /// Stable handle for UI tests, derived from the caption so a row cannot
    /// drift from its identifier the way a second hand-written string would.
    private var identifierPrefix: String { caption.lowercased() }

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
                            // Selection was carried by fill and weight alone,
                            // so every chip read identically and the current
                            // one was unfindable without sight (#114). The
                            // trait is what VoiceOver appends "selected" to.
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            // Otherwise each chip announces a bare number with
                            // no hint of what it sets — "8" in a row of "8"s.
                            .accessibilityLabel("\(caption) \(label(value))")
                            .accessibilityIdentifier("\(identifierPrefix).\(label(value))")
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

/// A compact − / value / + control for a value nudged between sets, one tap
/// per step. Replaces the reps/RPE chip rows (`ChoiceRow` still serves the
/// exercise-config sheet, where a scrolling row of *many* named values is the
/// right shape — this screen's job was always "nudge the standing value by
/// one," which a stepper answers directly with no scrolling and no extent
/// hidden past the edge of the screen.
///
/// Same − / value / + shape `WeightStepper` uses for the weight itself, held
/// to button-minimum scale because reps and RPE are the correction path; the
/// working weight is not.
private struct InlineStepper: View {
    let identifierPrefix: String
    let caption: String
    let valueText: String
    let accessibilityValue: String
    var onTapValue: (() -> Void)? = nil
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var repeater = StepRepeater()

    var body: some View {
        // No vertical padding: the step buttons take the full 52pt row
        // height themselves, so the tappable area grows from 44x44 to 52x52
        // without the row getting any taller against the #205 ceiling.
        HStack(spacing: 0) {
            stepButton("minus", label: "Decrease \(caption)", identifierSuffix: "decrement", action: onDecrement)
            valueView
            stepButton("plus", label: "Increase \(caption)", identifierSuffix: "increment", action: onIncrement)
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var valueLabel: some View {
        Text(valueText)
            .font(.title3.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .animation(Theme.quick(reduceMotion: reduceMotion), value: valueText)
            .frame(maxWidth: .infinity, minHeight: 52)
    }

    /// A button only when there is something to tap into (reps' exact
    /// entry sheet). RPE used to render as a *disabled* button, which the
    /// system dims: it measured 4.29:1 beside reps' 12.18:1 and read as
    /// unavailable while being the live value (critique, colorize).
    @ViewBuilder
    private var valueView: some View {
        if let onTapValue {
            Button(action: onTapValue) {
                valueLabel.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enter exact \(caption.lowercased())")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Plus and minus remain the primary controls")
            .accessibilityIdentifier("\(identifierPrefix).value")
        } else {
            valueLabel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(caption)
                .accessibilityValue(accessibilityValue)
                .accessibilityIdentifier("\(identifierPrefix).value")
        }
    }

    private func stepButton(
        _ symbol: String, label: String, identifierSuffix: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifierPrefix).\(identifierSuffix)")
        // Held rather than tapped repeatedly, same as the weight stepper's
        // own buttons (#77): a long move is quick, a short one stays exact.
        .onLongPressGesture(minimumDuration: 0.4, pressing: { isPressing in
            if isPressing { repeater.start(action) } else { repeater.stop() }
        }, perform: {})
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
