//
//  ContentView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// What to train next.
///
/// The cycle is push → pull → legs and never a weekday. The app leads with the
/// day that's due — read from cycle position, not the calendar — while leaving
/// the other two a tap away, because the rack you need is sometimes busy and
/// the app suggests rather than decides.
struct ContentView: View {
    @State private var store: TrainingStore?

    /// Whether the deferred insights have landed.
    ///
    /// Distinguishes "not computed yet" from "computed and genuinely empty",
    /// which staging the launch made two different things for the first time.
    @State private var insightsLoaded = false
    @State private var startupFailure: String?
    @State private var route: DayKind?
    /// The model belongs to the route, not to one rendering of its destination.
    /// Keeping it here preserves the in-memory session while its route exists.
    /// Route dismissal now means leave unfinished; only Finish completes it.
    @State private var activeSession: SessionViewModel?
    /// A today-only roster assembled from the template but not yet started.
    @State private var plannedSession: Session?
    @State private var previewLibrary: [Exercise] = []
    @State private var workoutDraft: WorkoutDraft?
    @State private var sessionStartFailure: String?
    @State private var cycle: CyclePosition?
    @State private var volume: VolumeReport?
    @State private var showingVolume = false
    @State private var trends: [E1RMTrend] = []
    @State private var digest: Digest?
    @State private var showingDigest = false
    @State private var sync = SyncStatus()
    @State private var health = HealthReadiness()
    @State private var readiness: Readiness?
    /// Health has never been asked on this device, so recovery is offered as
    /// a card rather than taken as a launch-time prompt (#110).
    @State private var healthNeedsPermission = false
    @State private var days: [TrainingDay] = []
    @State private var showingSettings = false

    /// The rotation currently in play, used for day names and ordering
    /// (#136). Read alongside `cycle` because both come from the same
    /// `GymConfig` read and both drive the same screen.
    @State private var activeSplit: TrainingSplit?
    /// True until the split has been chosen once, on this store or a synced
    /// one — `GymConfig.trainingSplit` is `nil` for exactly that reason.
    /// Distinct from "chose push/pull/legs", which never sets this.
    @State private var needsSplitSetup = false

    var body: some View {
        // Three durable destinations, each with a home rather than a toolbar
        // button (#112). The old bar gave Train, History, Progress, Volume and
        // Settings equal weight across both sides of the title, so the app's
        // primary job looked like one option among five.
        //
        // Volume and the digest are not destinations. They are findings about
        // the training in front of you, so they stay on the Train dashboard
        // where they are read, and open from there.
        TabView {
            trainTab
                .tabItem { Label("Train", systemImage: "figure.strengthtraining.traditional") }
            historyTab
                .tabItem { Label("History", systemImage: "calendar") }
            progressTab
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
        }
        .task { await openStore() }
        // Asked once, on a store that has never had an answer — including a
        // pre-#136 install updating into this feature, which reads the same
        // as brand new (#136). Not dismissable by a swipe: the whole point is
        // that this gets answered rather than skipped past.
        .fullScreenCover(isPresented: $needsSplitSetup) {
            if let store {
                NavigationStack {
                    TrainingSplitEditorView(
                        store: store,
                        current: nil,
                        isOnboarding: true,
                        onSave: saveInitialSplit
                    )
                }
                .interactiveDismissDisabled()
            }
        }
        // Keyed on the store arriving, so this runs after SwiftUI has updated
        // for it — which is the point: Train is on screen and interactive
        // before anything reads every set ever logged.
        .task(id: store == nil) {
            guard let store else { return }
            do {
                try loadInsights(from: store)
            } catch {
                startupFailure = String(describing: error)
            }
        }
        // Recomputed on return from a session. Back leaves the draft intact;
        // explicit Finish clears it before dismissing this route.
        .onChange(of: route) { _, newValue in
            guard newValue == nil else { return }
            // Keep the live model (including rest and unlogged choices) while
            // this process is alive. A relaunch rebuilds the same route from
            // the durable draft instead.
            if workoutDraft == nil {
                activeSession = nil
            }
            plannedSession = nil
            previewLibrary = []
            sessionStartFailure = nil
            refresh()
        }
        // Rows arriving from another device are the one thing that can
        // reintroduce a duplicate after the launch-time pass — on a fresh
        // install the first import lands after the library has already been
        // seeded into an apparently empty store. Merging here means the doubled
        // state lasts seconds rather than until the next launch.
        .onChange(of: sync.lastImport) { _, _ in
            guard let store else { return }
            try? store.deduplicate()
            // A gym changed on another device arrives the same way, and has to
            // reach this device's lifts before anything renders a plate line.
            try? store.reconcileGym()
            GymSettings.shared.refresh(from: store)
            refresh()
        }
    }

    /// The week's volume, as a finding rather than a destination.
    ///
    /// Shown whether or not anything is starved: the toolbar button was the
    /// only route on a quiet week, and #112 removed it. A finding worth
    /// surfacing loudly is still worth reaching quietly.
    private func volumeRow(_ volume: VolumeReport) -> some View {
        let starved = !volume.starved.isEmpty
        return Button { showingVolume = true } label: {
            HStack(spacing: 6) {
                Image(systemName: starved ? "exclamationmark.triangle.fill" : "chart.bar")
                    .foregroundStyle(starved ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                Text(starved ? starvedSummary(volume) : "Volume this week")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !starved {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
            }
            .font(.subheadline)
            // `.orange` at subheadline size fails WCAG on the system
            // background, and this is the one line on Train that reports a
            // training problem — the case where being read matters most (#114).
            // The icon keeps the colour, so the row still reads as a warning at
            // a glance without the words depending on hue to be legible.
            .foregroundStyle(starved ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            // 44pt, not the 18pt the text happened to be. The row spans the
            // screen so it never looked hard to hit, but a control sized by its
            // font is one a shaking hand or a thumb on a rack misses — the
            // system audit named this one before a person did (#114).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trainTab: some View {
        NavigationStack {
            Group {
                if let startupFailure {
                    ContentUnavailableView(
                        "Couldn't open the training store",
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupFailure)
                    )
                } else {
                    dayPicker
                }
            }
            .navigationTitle("ChickenBreast")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .navigationDestination(isPresented: $showingSettings) {
                SettingsView(store: store, sync: sync, onRestored: refresh)
            }
            .navigationDestination(isPresented: $showingVolume) {
                if let volume {
                    VolumeView(report: volume)
                }
            }
            .navigationDestination(isPresented: $showingDigest) {
                if let digest, let store {
                    DigestView(digest: digest, store: store, onApplied: refresh)
                }
            }
            .navigationDestination(item: $route) { kind in
                sessionDestination(for: kind)
                    // A session is the one place in the app that is not
                    // navigation. The bar would sit under the thumb that
                    // reaches for Log Set, and leaving mid-set by mistiming a
                    // tap costs the set. It comes back on the way out.
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    private var historyTab: some View {
        NavigationStack {
            if let store {
                // No `insightsLoaded` gate: HistoryView loads its own days on
                // appearance now, so it is correct as soon as the store is.
                HistoryView(days: days, store: store)
            } else {
                unavailable("History")
            }
        }
    }

    private var progressTab: some View {
        NavigationStack {
            if insightsLoaded {
                TrendsView(trends: trends)
            } else {
                unavailable("Progress")
            }
        }
    }

    /// What a tab shows before its data exists — or when it never will.
    ///
    /// A tab is always tappable, so the window the staged launch opened (#115)
    /// is reachable rather than merely possible, and "nothing logged yet" would
    /// be a lie for the second it takes the insights to land. But a spinner is
    /// a promise too: if the store failed to open, `insightsLoaded` never
    /// becomes true and an unbounded spinner claims to be loading something
    /// that will never arrive. The toolbar buttons this replaced at least said
    /// so by being disabled.
    private func unavailable(_ title: String) -> some View {
        Group {
            if let startupFailure {
                ContentUnavailableView(
                    "Couldn't open the training store",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupFailure)
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        // Matching both real destinations, which are inline — otherwise the
        // placeholder shows a large title that collapses the moment data lands.
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Explains recovery before iOS is allowed to ask about it.
    ///
    /// Says what will appear and where, because "Allow ChickenBreast to read
    /// Heart Rate Variability" says neither. Dismissal is deliberately absent:
    /// the card disappears the moment Health has been answered either way, so
    /// there is nothing to dismiss that declining does not already settle.
    private var healthCard: some View {
        Button {
            Task { await connectHealth() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use recovery data")
                        .font(.subheadline.weight(.medium))
                    Text("Sleep and HRV from Health add a readiness line here. Nothing is written back.")
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            }
            // Tint on a 12% tint wash reads fine to me and fails WCAG — the
            // title and the caption under it were both tint-coloured, and the
            // caption is `.secondary` on top of that. This card is mine, from
            // #110, and the audit caught it on its first run (#114). Primary
            // for the words, tint kept for the icon and the chevron, where
            // colour is decoration rather than the thing being read.
            .foregroundStyle(.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dayPicker: some View {
        VStack(spacing: 16) {
            Spacer()

            SyncBadge(status: sync)

            if let cycle {
                Text(cycle.summary())
                    .font(.headline)
                    // Was `.secondary`, which fails contrast at this size (#114).
                    // This line is the answer to "what am I training today" —
                    // the question the screen exists for — so receding was the
                    // wrong instinct twice over.
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if healthNeedsPermission {
                healthCard
            }

            if let digest, !digest.isEmpty {
                Button { showingDigest = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text("\(digest.bullets.count) thing\(digest.bullets.count == 1 ? "" : "s") to look at")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tint)
                    }
                    // Same correction as the recovery card above: tinted words
                    // on a tint wash fail contrast, so the words go primary and
                    // the tint stays on the icons, where it decorates rather
                    // than carries meaning (#114).
                    .foregroundStyle(.primary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // The volume guard is worth nothing behind a tap nobody takes, so
            // the headline finding sits on the first screen.
            //
            // Shown whether or not anything is starved, which it was not
            // before: the toolbar button was the only route when the week
            // looked fine, and #112 removed it. A finding worth surfacing
            // loudly is still worth reaching quietly.
            // Height reserved from first paint, not claimed when the insights
            // land. Making the row unconditional put it on every launch rather
            // than only for a lifter behind on something — and it arrives after
            // Train is already tappable (#115), so the centred stack re-laid
            // out and every day button moved under a thumb already reaching for
            // one.
            Group {
                if let volume {
                    volumeRow(volume)
                }
            }
            // 44 rather than 22, matching the row's own minimum. The
            // reservation still does its #115 job — the space is claimed at
            // first paint so the day buttons never move under a thumb — but
            // reserving less than the control needs made the outer frame the
            // real hit area, which is how a full-width row ended up 18pt tall.
            .frame(height: 44)

            if let workoutDraft {
                Button {
                    resumeWorkout(workoutDraft, from: store)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resume \(dayName(for: workoutDraft.kind)) workout")
                                .font(.title3.bold())
                            Text("Your logged sets are saved")
                                .font(.subheadline)
                                // `.secondary` on the tint wash behind this
                                // card fails contrast (#114). It is also the
                                // sentence that answers "did I lose my
                                // workout?", which is not a detail to mute.
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.resume")
                .accessibilityHint("Double tap to continue where you left off.")
            } else {
                ForEach(orderedDays) { template in
                    let isNext = template.kind == cycle?.next
                    Button {
                        previewSession(template.kind, from: store)
                    } label: {
                        HStack {
                            Text(template.name)
                                .font(isNext ? .title.bold() : .title3.weight(.semibold))
                            Spacer()
                            Text(subtitle(for: template))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .frame(height: isNext ? 88 : 68)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isNext ? AnyShapeStyle(.tint.opacity(0.15))
                                             : AnyShapeStyle(.fill.tertiary))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(isNext ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.clear), lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    // "Push" is the day; the subtitle beside it is context.
                    // Combined they read as one sentence, which is right for a
                    // reader and useless as a test handle — hence the id (#114).
                    .accessibilityIdentifier("day.\(template.kind.rawValue)")
                    .accessibilityHint(isNext ? "Next in your cycle. Double tap to review it."
                                              : "Double tap to review this workout.")
                    .disabled(store == nil)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    /// Recomputes everything the home screen shows.
    private func refresh() {
        guard let store else { return }
        cycle = try? store.cyclePosition()
        activeSplit = try? store.gymConfig().effectiveTrainingSplit
        // Deliberately not surfaced: a reload after a session must not replace
        // a working screen with a startup failure.
        try? loadInsights(from: store)
    }

    /// Records the split chosen at first launch (#136).
    ///
    /// Reads the current config rather than starting from `.standard`, so
    /// this can't silently discard a gym that arrived from CloudKit before
    /// setup finished — unlikely on a genuinely fresh install, but this path
    /// is also what a pre-#136 install updating into the feature runs.
    private func saveInitialSplit(_ split: TrainingSplit) {
        guard let store else { return }
        var config = (try? store.gymConfig()) ?? .standard
        config.trainingSplit = split
        try? store.saveGymConfig(config)
        GymSettings.shared.refresh(from: store)
        needsSplitSetup = false
        refresh()
    }

    /// Everything the Train screen does not need to become usable.
    ///
    /// Ordered by how soon it is likely to be looked at: the dashboard's own
    /// volume and digest first, then the two that feed destinations nobody has
    /// opened yet and that grow fastest with a long history.
    ///
    /// Still eager rather than loaded when a destination opens, which is the
    /// last stage #115 describes and the one not done here: the toolbar
    /// disables History and Volume on these values being absent, so moving to
    /// on-demand loading changes what an empty state means. That belongs with
    /// #112, which is reconsidering those destinations anyway.
    /// Throws, so the caller decides what a failure means.
    ///
    /// At launch it means the store is broken and should say so: these reads
    /// used to sit inside `openStore`'s do/catch, and behind a `try?` a store
    /// that answered `cyclePosition()` then threw on `allSets()` opened looking
    /// healthy, with Volume and History permanently disabled and nothing to
    /// distinguish it from a fresh install.
    ///
    /// After a session it means something else entirely, and must not blank a
    /// screen someone is mid-workout on — `refresh` keeps the old `try?`.
    private func loadInsights(from store: TrainingStore) throws {
        volume = try store.volumeReport()
        digest = try store.digest()
        trends = try store.e1RMTrends()
        days = try store.trainingDays()
        insightsLoaded = true
    }

    /// Names the muscles that are behind, at most three — a list of ten is a
    /// wall of text nobody reads, and the worst three are the actionable part.
    private func starvedSummary(_ report: VolumeReport) -> String {
        let worst = report.starved.sorted { $0.sets < $1.sets }.prefix(3)
        let names = worst.map { $0.muscle.displayName.lowercased() }
        let remainder = report.starved.count - worst.count
        let list = names.joined(separator: ", ")
        return remainder > 0
            ? "Behind on \(list) and \(remainder) more"
            : "Behind on \(list)"
    }

    /// The due day first, then the rest of the active split's rotation in
    /// order (#136) — whatever its length, not always three.
    private var orderedDays: [DayTemplate] {
        let days = activeSplit?.days ?? DayTemplateLibrary.split(.pushPullLegs).days
        guard let next = cycle?.next,
              let index = days.firstIndex(where: { $0.kind == next }) else {
            return days
        }
        return Array(days[index...] + days[..<index])
    }

    private func subtitle(for template: DayTemplate) -> String {
        guard let days = cycle?.daysSince(template.kind) else {
            return "\(template.slots.count) slots"
        }
        switch days {
        case 0:  return "today"
        case 1:  return "yesterday"
        default: return "\(days) days ago"
        }
    }

    /// The active split's own name for a day, falling back to the kind's own
    /// word for a draft resumed from a split no longer active (#136) — a
    /// draft always finishes under the shape it was started with; only the
    /// label here has nothing better to read.
    private func dayName(for kind: DayKind) -> String {
        activeSplit?.days.first { $0.kind == kind }?.name ?? kind.rawValue.capitalized
    }

    @ViewBuilder
    private func sessionDestination(for kind: DayKind) -> some View {
        if let activeSession {
            SessionView(model: activeSession, onFinish: finishActiveSession)
        } else if let plannedSession {
            WorkoutPreviewView(
                session: plannedSession,
                dayName: dayName(for: plannedSession.kind),
                library: previewLibrary,
                onMove: movePlannedExercises,
                onRemove: removePlannedExercises,
                onAdd: addPlannedExercise,
                onStart: startPlannedSession
            )
        } else if let sessionStartFailure {
            ContentUnavailableView(
                "Couldn't start the session",
                systemImage: "exclamationmark.triangle",
                description: Text(sessionStartFailure)
            )
        }
    }

    /// Assembles today's editable roster without creating a durable workout.
    private func previewSession(_ kind: DayKind, from store: TrainingStore?) {
        guard route == nil, activeSession == nil, let store else { return }
        do {
            plannedSession = try store.startSession(kind: kind)
            previewLibrary = try store.exercises()
            sessionStartFailure = nil
        } catch {
            sessionStartFailure = String(describing: error)
            return
        }
        route = kind
    }

    private func movePlannedExercises(_ offsets: IndexSet, _ destination: Int) {
        plannedSession?.movePlannedExercises(fromOffsets: offsets, toOffset: destination)
    }

    private func removePlannedExercises(_ offsets: IndexSet) {
        plannedSession?.removePlannedExercises(atOffsets: offsets)
    }

    private func addPlannedExercise(_ exercise: Exercise) {
        guard var plan = plannedSession, let store else { return }
        do {
            let row = try store.sessionExercise(
                for: exercise, slot: nil, startedAt: plan.startedAt
            )
            plan.appendPlannedExercise(row)
            plannedSession = plan
        } catch {
            sessionStartFailure = String(describing: error)
        }
    }

    /// The deliberate boundary: only now does the workout get a start time and
    /// durable draft. Preview edits never touch the recurring template.
    private func startPlannedSession() {
        guard let store, let plan = plannedSession, !plan.isEmpty else { return }
        do {
            let session = plan.starting()
            let draft = WorkoutDraft(session: session)
            try store.saveWorkoutDraft(draft)
            workoutDraft = draft
            activeSession = SessionViewModel(store: store, session: session, draftID: draft.id)
            plannedSession = nil
            previewLibrary = []
            sessionStartFailure = nil
        } catch {
            sessionStartFailure = String(describing: error)
        }
    }

    private func resumeWorkout(_ draft: WorkoutDraft, from store: TrainingStore?) {
        guard route == nil, let store else { return }
        if activeSession != nil {
            route = draft.kind
            return
        }
        do {
            let session = try store.resumeSession(draft)
            activeSession = SessionViewModel(store: store, session: session, draftID: draft.id)
            sessionStartFailure = nil
            route = draft.kind
        } catch {
            sessionStartFailure = String(describing: error)
        }
    }

    private func finishActiveSession() {
        guard let activeSession, activeSession.finish() else { return }
        workoutDraft = nil
        route = nil
    }

    /// Loads recovery when Health has already been answered, and otherwise
    /// offers the card.
    ///
    /// #26 asked for zero taps and this is one, which is a deliberate trade.
    /// The silent version put a Health sheet in front of someone who had not
    /// yet seen the app, next to a notification alert doing the same (#110) —
    /// and a permission sheet with no visible cause is the one people decline,
    /// which cost #26 the data it was trying to protect.
    ///
    /// The tap is only ever paid once. After any answer — granted or refused —
    /// `needsPermission()` goes false and every later launch comes straight
    /// here, silent, exactly as before.
    private func loadReadinessIfPermitted() async {
        guard await health.needsPermission() else {
            await loadReadiness()
            return
        }
        healthNeedsPermission = true
    }

    /// Requests Health from the card, then loads.
    private func connectHealth() async {
        healthNeedsPermission = false
        await loadReadiness()
    }

    /// Reads recovery and folds it into the digest.
    ///
    /// A refusal is indistinguishable from having no data, which is fine —
    /// both mean no readiness line.
    private func loadReadiness() async {
        await health.requestAccess()
        guard let store else { return }

        // Weigh-ins first: a bodyweight lift needs one to seed from, and it
        // costs a query nobody notices (#71).
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        for weighIn in await health.bodyweights(since: cutoff) {
            try? store.record(weighIn)
        }

        guard let reading = await health.current() else { return }
        readiness = reading
        digest = try? store.digest(readiness: reading)
    }

    private func openStore() async {
        guard store == nil, startupFailure == nil else { return }
        do {
            // Shared rather than constructed here, so a set logged from the
            // lock screen (#23) and one logged on this screen go through the
            // same store. Sync is requested inside; the store falls back to a
            // local file when the entitlement doesn't allow it, so the app
            // always opens (#19).
            let opened = try AppStore.shared.store()
            // Before anything reads: a duplicate arriving from another device
            // (#19) must never be observed, even briefly. On a clean store this
            // is one fetch per entity and no writes.
            try opened.deduplicate()
            try opened.seedLibraryIfNeeded()
            try opened.seedTemplatesIfNeeded()
            // After the seeds, so a freshly seeded library lands on the gym's
            // rack rather than the pound default (#73). Also the only thing
            // that re-racks this device after another one changed the gym: the
            // gym row syncs, but what each lift inherits from it does not.
            try opened.reconcileGym()
            GymSettings.shared.refresh(from: opened)
            workoutDraft = try opened.workoutDraft()
            // Train needs the store and the cycle position. Nothing else on
            // this path is for the screen that is about to appear: volume, the
            // digest, every e1RM trend and the whole training history were all
            // computed here first, so opening the app paid for History and
            // Progress before anyone asked to see them — and that cost grows
            // with exactly the thing a working app accumulates (#115).
            cycle = try opened.cyclePosition()
            let gym = try opened.gymConfig()
            activeSplit = gym.effectiveTrainingSplit
            // Read before `store` is set, so the cover is already primed by
            // the frame Train appears — asked once, the moment there's a
            // screen underneath it to ask over (#136).
            needsSplitSetup = gym.trainingSplit == nil
            store = opened

            // Recovery arrives after the screen does. It's context, never a
            // reason to keep someone waiting on a Health query before they can
            // start a session (#26).
            Task { await loadReadinessIfPermitted() }
            // The insights load from `.task(id: storeIsOpen)` below rather
            // than from a `Task {}` here. A Task enqueued at this point is a
            // main-actor job, not a later frame: `openStore` suspends two
            // statements down at `sync.refresh`, the job drains in the same
            // run-loop iteration, and the render this staging exists to unblock
            // can still end up behind it.
            await sync.refresh(store: opened)
            // Schedules for someone who has already allowed notifications and
            // asks nobody. The request moved to Settings, where turning the
            // digest on is a thing the person just did (#110).
            await DigestNotification.scheduleIfAuthorized()
        } catch {
            startupFailure = String(describing: error)
        }
    }
}

/// The deliberate pause between choosing a day and beginning it (#137).
/// Editing is scoped to this value and its eventual draft; templates are never
/// written from here.
private struct WorkoutPreviewView: View {
    let session: Session
    /// The active split's name for this day (#136) — not derived from
    /// `session.kind.rawValue.capitalized` here, because a custom day's
    /// kind can be any typed name and this screen has its own chance to get
    /// the casing right instead of leaning on `.capitalized`.
    let dayName: String
    let library: [Exercise]
    let onMove: (IndexSet, Int) -> Void
    let onRemove: (IndexSet) -> Void
    let onAdd: (Exercise) -> Void
    let onStart: () -> Void

    @State private var showingAdd = false
    @State private var query = ""

    var body: some View {
        List {
            Section {
                ForEach(session.exercises) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.exercise.name).font(.body.weight(.semibold))
                        Text(row.slot?.name ?? "Added for today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .onMove(perform: onMove)
                .onDelete(perform: onRemove)
            } header: {
                Text("Today's exercises")
            } footer: {
                Text("Changes affect this workout only. Your recurring plan stays the same.")
            }
        }
        .navigationTitle("\(dayName) workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button("Add exercise", systemImage: "plus") { showingAdd = true }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onStart) {
                Text("Start workout")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.exercises.isEmpty)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                List(filteredCandidates) { exercise in
                    Button {
                        onAdd(exercise)
                        showingAdd = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name).foregroundStyle(.primary)
                            Text(exercise.equipment.displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .searchable(text: $query, prompt: "Exercise name")
                .navigationTitle("Add for today")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAdd = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var filteredCandidates: [Exercise] {
        let existing = Set(session.exercises.map(\.id))
        let available = library.filter { !existing.contains($0.id) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return available.sorted { $0.name < $1.name } }
        return available.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name < $1.name }
    }
}

private extension Result where Failure == Error {
    init(catching body: () throws -> Success) {
        do { self = .success(try body()) }
        catch { self = .failure(error) }
    }
}

#Preview {
    ContentView()
}
