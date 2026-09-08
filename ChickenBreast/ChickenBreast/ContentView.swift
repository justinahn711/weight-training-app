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
                Text(starved ? starvedSummary(volume) : "Volume this week")
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !starved {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
            }
            .font(.subheadline)
            .foregroundStyle(starved ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
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
                Image(systemName: "heart.text.square")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use recovery data")
                        .font(.subheadline.weight(.medium))
                    Text("Sleep and HRV from Health add a readiness line here. Nothing is written back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
            }
            .foregroundStyle(.tint)
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if healthNeedsPermission {
                healthCard
            }

            if let digest, !digest.isEmpty {
                Button { showingDigest = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("\(digest.bullets.count) thing\(digest.bullets.count == 1 ? "" : "s") to look at")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.tint)
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
            .frame(height: 22)

            if let workoutDraft {
                Button {
                    resumeWorkout(workoutDraft, from: store)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Resume \(workoutDraft.kind.rawValue.capitalized) workout")
                                .font(.title3.bold())
                            Text("Your logged sets are saved")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.headline)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2))
                }
                .buttonStyle(.plain)
            } else {
                ForEach(orderedDays, id: \.self) { kind in
                    let isNext = kind == cycle?.next
                    Button {
                        openSession(kind, from: store)
                    } label: {
                        HStack {
                            Text(kind.rawValue.capitalized)
                                .font(isNext ? .title.bold() : .title3.weight(.semibold))
                            Spacer()
                            Text(subtitle(for: kind))
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
        // Deliberately not surfaced: a reload after a session must not replace
        // a working screen with a startup failure.
        try? loadInsights(from: store)
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

    /// The due day first, then the rest of the cycle in order.
    private var orderedDays: [DayKind] {
        guard let next = cycle?.next else { return DayKind.allCases }
        return [next, next.next, next.next.next]
    }

    private func subtitle(for kind: DayKind) -> String {
        let slots = DayTemplateLibrary.template(for: kind).slots.count
        guard let days = cycle?.daysSince(kind) else { return "\(slots) slots" }
        switch days {
        case 0:  return "today"
        case 1:  return "yesterday"
        default: return "\(days) days ago"
        }
    }

    @ViewBuilder
    private func sessionDestination(for kind: DayKind) -> some View {
        if let activeSession {
            SessionView(model: activeSession, onFinish: finishActiveSession)
        } else if let sessionStartFailure {
            ContentUnavailableView(
                "Couldn't start the session",
                systemImage: "exclamationmark.triangle",
                description: Text(sessionStartFailure)
            )
        }
    }

    /// Assembles a session and durably marks it unfinished before navigating.
    private func openSession(_ kind: DayKind, from store: TrainingStore?) {
        guard route == nil, activeSession == nil, let store else { return }
        do {
            let session = try store.startSession(kind: kind)
            let draft = WorkoutDraft(session: session)
            try store.saveWorkoutDraft(draft)
            workoutDraft = draft
            activeSession = SessionViewModel(store: store, session: session, draftID: draft.id)
            sessionStartFailure = nil
        } catch {
            sessionStartFailure = String(describing: error)
            return
        }
        route = kind
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

private extension Result where Failure == Error {
    init(catching body: () throws -> Success) {
        do { self = .success(try body()) }
        catch { self = .failure(error) }
    }
}

#Preview {
    ContentView()
}
