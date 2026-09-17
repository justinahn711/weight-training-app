//
//  HistoryView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// What you actually did, on a calendar (#63).
///
/// Every other screen is derived — Trends fits curves to e1RM, Volume counts
/// muscles, the Digest draws conclusions. This shows the record itself.
///
/// A month grid rather than a list, because the questions asked of history are
/// "what was Thursday" and "have I been consistent", and both are answered by
/// position on a page. A list answers the first one only by scrolling, and
/// scrolling gets worse every week you train.
struct HistoryView: View {
    let store: TrainingStore

    /// Told whenever a delete *or a correction* lands on disk, so a session
    /// still open in the Train tab can catch up (#199, #218). History writes
    /// through the store directly rather than through the session — Today
    /// and History are different tabs, and this is the seam between them.
    /// Defaulted to a no-op so every existing call site (including tests and
    /// previews that predate #199) keeps compiling without naming a session
    /// that usually isn't there.
    ///
    /// The name is a holdover from #199, which only had deletes to worry
    /// about — `reconcilePersistedSetsAfterHistoryEdit()`, what this is wired
    /// to in `ContentView`, was already named for the general case. #218
    /// found the wiring here had never caught up: correcting a set's weight,
    /// reps or RPE only reloaded History's own list, so a set inside a still
    /// -open session read stale until something unrelated happened to resume
    /// it. Left named `onSetsDeleted` rather than renamed, because the
    /// argument label is shared with `ContentView.swift`, which this file
    /// does not own.
    let onSetsDeleted: () -> Void

    /// Reloaded here rather than handed down, because correcting a set (#61)
    /// changes what this screen shows and the change has to be visible without
    /// leaving it.
    @State private var days: [TrainingDay]
    @State private var month: Date = Calendar.current.startOfDay(for: Date())
    @State private var selected: TrainingDay?
    @State private var weeklyTarget = 3

    init(days: [TrainingDay], store: TrainingStore, onSetsDeleted: @escaping () -> Void = {}) {
        self.store = store
        self.onSetsDeleted = onSetsDeleted
        _days = State(initialValue: days)
    }

    private var calendar: Calendar { .current }

    /// Trained days, keyed by midnight, so a cell is one lookup.
    private var byDay: [Date: TrainingDay] {
        Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.date), $0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WeeklyStreakCard(
                    consistency: TrainingHistory.weeklyConsistency(
                        days: days, target: weeklyTarget, calendar: calendar
                    )
                )

                MonthHeader(
                    month: month,
                    canGoForward: canGoForward,
                    onBack: { shift(by: -1) },
                    onForward: { shift(by: 1) }
                )

                MonthGrid(
                    month: month,
                    byDay: byDay,
                    calendar: calendar,
                    onSelect: { selected = $0 }
                )

                if days.isEmpty {
                    Text("Sessions appear here once you've trained.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    Legend()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // Reloaded on every appearance, not just when the view is first
        // created. `State(initialValue:)` is honoured only when an identity is
        // installed, and as a tab this view is created once and kept for the
        // life of the app — so a session finished, an import landed or a backup
        // restored after the first visit left today unmarked until relaunch.
        // The same shape as #98, resurfaced by changing how this is presented.
        //
        // It also means History loads its own data when opened, which is the
        // stage #115 deferred.
        .task { reload() }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { day in
            DayDetailView(day: day, store: store, onChange: reload, onSetsDeleted: onSetsDeleted)
        }
    }

    /// Re-reads history and re-points the open day at its corrected self.
    ///
    /// A day that lost its last set disappears, which closes the detail screen
    /// rather than leaving it showing a session that no longer exists.
    private func reload() {
        days = (try? store.trainingDays()) ?? []
        weeklyTarget = (try? store.gymConfig().weeklySessionTarget) ?? 3
        if let open = selected {
            let sameDay = Calendar.current.startOfDay(for: open.date)
            selected = days.first { Calendar.current.startOfDay(for: $0.date) == sameDay }
        }
    }

    /// Nothing to see past the current month.
    private var canGoForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { return false }
        return next <= Date()
    }

    private func shift(by months: Int) {
        guard let moved = calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = moved
    }
}

private struct WeeklyStreakCard: View {
    let consistency: WeeklyConsistency

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.weeklyStreak")
    }

    private var title: String {
        guard consistency.weeks > 0 else { return "Build your weekly streak" }
        let unit = consistency.weeks == 1 ? "week" : "weeks"
        return "\(consistency.weeks) \(unit) running"
    }

    private var progress: String {
        if consistency.currentWeekMeetsTarget {
            return "Target met · \(consistency.currentWeekDays)/\(consistency.target) training days this week"
        }
        return "\(consistency.currentWeekDays)/\(consistency.target) training days this week"
    }
}

private struct MonthHeader: View {
    let month: Date
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            // The glyph is 17pt; the tap target it sat in was exactly that,
            // in a row flanked by 20pt of horizontal padding either side —
            // salvaged from #153, which main never had a hit-area fix for (#114).
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Previous month")
            .accessibilityIdentifier("history.month.previous")
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button(action: onForward) {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Next month")
            .accessibilityIdentifier("history.month.next")
            .disabled(!canGoForward)
        }
        .padding(.top, 8)
    }
}

private struct MonthGrid: View {
    let month: Date
    let byDay: [Date: TrainingDay]
    let calendar: Calendar
    let onSelect: (TrainingDay) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                // Blanks so the first of the month lands on its real weekday.
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 44)
                }
                ForEach(daysInMonth, id: \.self) { date in
                    DayCell(
                        date: date,
                        day: byDay[calendar.startOfDay(for: date)],
                        isToday: calendar.isDateInToday(date),
                        onTap: { day in onSelect(day) }
                    )
                }
            }
        }
    }

    /// Weekday initials starting on the locale's first day, so the columns line
    /// up with the grid below them.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var daysInMonth: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    private var leadingBlanks: Int {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return 0 }
        let weekday = calendar.component(.weekday, from: first)
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

/// One square. Trained days are filled and tappable; the rest are just numbers.
private struct DayCell: View {
    let date: Date
    let day: TrainingDay?
    let isToday: Bool
    let onTap: (TrainingDay) -> Void

    var body: some View {
        Group {
            if let day {
                Button { onTap(day) } label: { square(for: day) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double tap to open this workout.")
            } else {
                square(for: nil)
            }
        }
        // Read as one thing saying a real date and what was trained, rather
        // than a number and a letter: "14" then "P" is not a day, and the
        // letter's meaning is entirely in a colour legend a reader cannot
        // see (#114).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("history.day.\(Self.identifierFormatter.string(from: date))")
    }

    private var accessibilityLabel: String {
        var sentence = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if isToday { sentence += ", today" }
        if let day {
            sentence += day.kind.map { ", \($0.rawValue) day" } ?? ", trained"
        } else {
            sentence += ", no workout"
        }
        return sentence
    }

    /// Stable and locale-independent, unlike the visible label — a UI test
    /// looking for a cell must not depend on the tester's region format.
    private static let identifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func square(for day: TrainingDay?) -> some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.footnote.weight(day == nil ? .regular : .semibold))
                .foregroundStyle(day == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            if let day {
                // Deliberately fixed rather than Dynamic Type-aware (a
                // platform audit's lowest-priority finding): this sits
                // inside a fixed 44pt grid cell shared by a whole week's row,
                // and letting it grow risks clipping or breaking that row's
                // height at a larger reading size. It is decorative besides
                // — the cell's own accessibility label already states the
                // day kind in full, so nothing is lost if this letter stays
                // small.
                Text(initial(for: day))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(day == nil ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(tint(for: day!)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear),
                              lineWidth: 1.5)
        )
    }

    /// A letter rather than a colour alone, so the day kind survives a
    /// colourblind reader and a greyscale screenshot.
    private func initial(for day: TrainingDay) -> String {
        guard let kind = day.kind else { return "•" }
        return String(kind.rawValue.prefix(1)).uppercased()
    }

    private func tint(for day: TrainingDay) -> Color {
        switch day.kind {
        case .push:  return .blue
        case .pull:  return .green
        case .legs:  return .orange
        case nil:    return .gray
        // `DayKind` stopped being a closed push/pull/legs enum in #136 so a
        // split could name upper/lower, full body, and custom days, and a
        // switch over it can no longer be proven exhaustive. Indigo keeps
        // every other day kind visibly distinct from both the fixed three
        // and "untrained" (gray).
        default: return .indigo
        }
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.blue, "Push")
            item(.green, "Pull")
            item(.orange, "Legs")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(colour).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

/// One day's training, in the order it happened.
struct DayDetailView: View {
    let day: TrainingDay
    let store: TrainingStore
    let onChange: () -> Void
    /// See `HistoryView.onSetsDeleted` (#199) — passed straight through so
    /// both delete paths this screen owns, the single-set one and the
    /// selection one, reach the same session-reconcile call.
    var onSetsDeleted: () -> Void = {}

    @State private var editing: EditTarget?
    @State private var failure: String?

    /// Correcting a bad import or an accidental day one set at a time is the
    /// only path #61 left; selection mode is the fast one (#168). Off by
    /// default so the ordinary tap-to-correct flow it's layered over — which
    /// the acceptance criteria require to keep working — is never in its way.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmingBatchDelete = false

    /// A set, plus the lift it belongs to — the editor needs the increment to
    /// step the weight by, and the lift isn't on the record.
    struct EditTarget: Identifiable {
        /// Named `record` rather than `set`: inside a computed property, `set`
        /// reads as the start of a setter and the parser gives up.
        let record: SetRecord
        let exercise: Exercise
        var id: UUID { record.id }
    }

    /// Every set on the day, in the order the list shows them — what "Select
    /// all" selects and what a full selection is measured against.
    private var allSetIDs: [UUID] {
        day.exercises.flatMap { $0.sets.map(\.id) }
    }

    private var allSelected: Bool {
        !allSetIDs.isEmpty && selectedIDs.count == allSetIDs.count
    }

    var body: some View {
        List {
            ForEach(day.exercises) { performed in
                Section {
                    ForEach(performed.sets, id: \.id) { set in
                        row(for: set, exercise: performed.exercise)
                    }
                } header: {
                    HStack {
                        Text(performed.exercise.name)
                        Spacer()
                        if let top = performed.topSet {
                            Text("top \(top.load.formatted(in: GymSettings.shared.unit)) × \(top.reps)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textCase(nil)
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // A bottom bar rather than another toolbar item: the destructive
        // action for a selection needs its own visual weight, and a lifter
        // scrolled deep into a long day shouldn't have to scroll back up to
        // find it.
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                deleteBar
            }
        }
        .sheet(item: $editing) { target in
            EditSetView(
                set: target.record,
                exercise: target.exercise,
                onSave: { corrected in
                    // Routed like the delete below rather than through
                    // `apply` (#218): a correction changes a row a running
                    // session may hold too, and `onSetsDeleted()` is the only
                    // seam that tells it to catch up (#199). `apply` only
                    // called `onChange()`, which reloads History's own list
                    // and nothing else.
                    do {
                        try store.updateSet(corrected)
                        onChange()
                        onSetsDeleted()
                    } catch {
                        failure = error.localizedDescription
                    }
                },
                onDelete: {
                    // Not routed through `apply`: that helper only calls
                    // `onChange()`, and a failed delete must not tell the
                    // session anything changed. Single-set delete goes
                    // through the same reconcile call as the batch path below
                    // (#199) — a set removed one at a time can strand a
                    // running session's undo banner or rest exactly as easily
                    // as a selection can.
                    do {
                        try store.deleteSet(id: target.record.id)
                        onChange()
                        onSetsDeleted()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            )
        }
        .alert("Couldn't save that", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "set" : "sets") from \(dayLabel)?",
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "set" : "sets")",
                   role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("They stop counting towards volume, e1RM and your next target. This can't be undone.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                // Cancel exits without changing data — selection is cleared,
                // nothing store-side was ever touched to undo.
                Button("Cancel") {
                    isSelecting = false
                    selectedIDs = []
                }
                .accessibilityIdentifier("dayDetail.cancelSelection")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selectedIDs = allSelected ? [] : Set(allSetIDs)
                }
                .accessibilityIdentifier("dayDetail.selectAll")
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") {
                    isSelecting = true
                }
                .accessibilityIdentifier("dayDetail.select")
            }
        }
    }

    /// One row, in whichever of the two modes is live. Selecting swaps the
    /// tap target from "open the corrector" to "toggle this set" rather than
    /// running both — a tap has to mean one thing.
    @ViewBuilder
    private func row(for set: SetRecord, exercise: Exercise) -> some View {
        if isSelecting {
            let selected = selectedIDs.contains(set.id)
            Button {
                toggle(set.id)
            } label: {
                HStack(spacing: 12) {
                    checkbox(selected: selected)
                    SetRow(set: set)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: set))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(selected ? "Double tap to deselect" : "Double tap to select")
        } else {
            Button {
                editing = EditTarget(record: set, exercise: exercise)
            } label: {
                SetRow(set: set)
            }
            .buttonStyle(.plain)
        }
    }

    /// A checkbox glyph alone isn't a hit target — `.frame` without
    /// `.contentShape` leaves the tappable area at the glyph's own rendered
    /// size, which is exactly the mistake that shipped four 18pt buttons
    /// in #114. `.contentShape` is what actually makes the 44pt square real.
    private func checkbox(selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func accessibilityLabel(for set: SetRecord) -> String {
        var text = "\(set.load.formatted(in: GymSettings.shared.unit)) times \(set.reps)"
        if set.isWarmup { text += ", warmup" }
        // `historyRPEText` already reads "RPE 8" (#218) — a literal "RPE "
        // in front of it read "RPE RPE 8" to VoiceOver.
        if let rpe = set.rpe { text += ", \(historyRPEText(rpe))" }
        return text
    }

    private var deleteBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button(role: .destructive) {
                confirmingBatchDelete = true
            } label: {
                Text(deleteLabel)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .contentShape(Rectangle())
            .disabled(selectedIDs.isEmpty)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .accessibilityIdentifier("dayDetail.deleteSelected")
    }

    private var deleteLabel: String {
        selectedIDs.isEmpty
            ? "Delete sets"
            : "Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "set" : "sets")"
    }

    /// Deletes the selection as one store call (#168) and leaves selection
    /// mode only once that succeeds — a failure keeps the picks intact so
    /// there's something to retry rather than a screen that silently forgot
    /// what was chosen.
    private func deleteSelected() {
        let ids = selectedIDs
        do {
            try store.deleteSets(ids: ids)
            onChange()
            // See `onDelete` above (#199) — same reconcile call, same rule
            // that it only fires once the delete has actually landed.
            onSetsDeleted()
            selectedIDs = []
            isSelecting = false
        } catch {
            failure = error.localizedDescription
        }
    }

    private var dayLabel: String {
        day.date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    private var title: String {
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).month().day())
        guard let kind = day.kind else { return date }
        return "\(kind.rawValue.capitalized) · \(date)"
    }
}


/// The text a set's RPE reads as, wherever History shows one.
///
/// A free function rather than inlined into each `Text(...)`, so a
/// regression can be caught by `swift test` without booting a simulator.
/// `RPE.description` (#4, #5) already spells out "RPE 8" — `SetRow` below
/// used to wrap it in a second literal "RPE ", which read "RPE RPE 8" on
/// every row and in VoiceOver's description of it (#218). Not `private`,
/// so `ChickenBreastTests` can reach it via `@testable import`.
func historyRPEText(_ rpe: RPE) -> String {
    rpe.description
}

/// What typing `text` into History's exact-weight field means for `exercise`,
/// given what the field last agreed with `pounds` about (`committed`).
///
/// Pulled out of `EditSetView` so the interaction between it and
/// `TypedWeight.resolve` (#99) — which already owns parsing and buildability
/// — can be checked by `swift test` without instantiating SwiftUI (#218).
/// `EditSetView` itself only holds state and renders; this is where "does the
/// typed value snap to what the equipment can build" actually gets decided.
enum HistoryWeightEdit: Equatable {
    /// Nothing to act on: either untouched, or a prior edit already folded
    /// back into `pounds` (see `EditSetView.commit`).
    case unedited
    /// Parses and is buildable outright — safe for `pounds` to adopt.
    case exact(Load)
    /// Parses, but this exercise's equipment cannot be set to it. The
    /// nearest weight it *can* build is offered, never substituted (#218).
    case unbuildable(requested: Load, achievable: Load)
    /// Not a number at all, or ambiguous in the way `TypedWeight.parse` (#99)
    /// deliberately refuses to guess at.
    case unparseable
}

func resolveHistoryWeightEdit(
    text: String, committed: String, unit: MassUnit, exercise: Exercise
) -> HistoryWeightEdit {
    guard text != committed else { return .unedited }
    guard let resolution = TypedWeight.resolve(text, in: unit, for: exercise) else {
        return .unparseable
    }
    switch resolution {
    case .exact(let load):
        return .exact(load)
    case .nearest(let requested, let achievable):
        return .unbuildable(requested: requested, achievable: achievable)
    }
}

/// Whether Save should be live given the exact-weight field's current state.
/// Save stays explicit either way (#218) — this only gates the button, and
/// only for the weight field: an unresolved typed number must block Save
/// rather than be silently dropped in favour of whatever `pounds` still
/// holds.
func canSaveHistoryWeightEdit(_ edit: HistoryWeightEdit) -> Bool {
    switch edit {
    case .unedited, .exact: return true
    case .unbuildable, .unparseable: return false
    }
}

/// Corrects one logged set (#61).
///
/// Deliberately narrow. Weight, reps, RPE and whether it was a warmup are what
/// gets mislogged; the lift and the moment are not editable, because a set on
/// the wrong exercise or the wrong day is a different set and deleting it is
/// the honest fix.
private struct EditSetView: View {
    let set: SetRecord
    let exercise: Exercise
    let onSave: (SetRecord) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pounds: Double
    @State private var reps: Int
    @State private var rpe: RPE?
    @State private var isWarmup: Bool
    @State private var confirmingDelete = false

    /// The exact-entry field's text, and the text `pounds` was last known to
    /// agree with. Comparing the two is how "hasn't resolved to anything yet"
    /// is told apart from "already matches what's stored" without a third
    /// piece of state to keep in sync (#218: 45 lb -> 135 lb was 18 taps at a
    /// 5 lb step, and the stepper alone is what made it that slow).
    @State private var weightText: String
    @State private var committedText: String

    init(set: SetRecord, exercise: Exercise,
         onSave: @escaping (SetRecord) -> Void, onDelete: @escaping () -> Void) {
        self.set = set
        self.exercise = exercise
        self.onSave = onSave
        self.onDelete = onDelete
        _pounds = State(initialValue: set.load.pounds)
        _reps = State(initialValue: set.reps)
        _rpe = State(initialValue: set.rpe)
        _isWarmup = State(initialValue: set.isWarmup)
        let text = Self.text(for: set.load.pounds)
        _weightText = State(initialValue: text)
        _committedText = State(initialValue: text)
    }

    /// What the typed field currently means — delegated to
    /// `resolveHistoryWeightEdit` (top of this file) so the actual decision
    /// is covered by `swift test` rather than only by this view rendering
    /// correctly (#218).
    private var weightEdit: HistoryWeightEdit {
        resolveHistoryWeightEdit(
            text: weightText, committed: committedText,
            unit: GymSettings.shared.unit, exercise: exercise
        )
    }

    private var canSave: Bool { canSaveHistoryWeightEdit(weightEdit) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Stepped by the lift's own increment, so a correction
                    // can't produce a weight the equipment can't be set to
                    // (#20, #39).
                    Stepper(value: poundsBinding, in: 0...2000, step: exercise.increment.pounds) {
                        // Stepped in pounds because that is what is stored, but
                        // read in the unit the lifter uses (#67) — the step
                        // itself is the equipment's own, so the numbers land
                        // where the equipment does.
                        LabeledContent("Weight", value: format(pounds))
                    }
                    // Direct entry beside the stepper rather than behind
                    // another sheet (#218) — a big correction is common
                    // enough (a wrong unit typed at the rack, a set logged
                    // against the wrong day's weight) that hiding the fast
                    // path a tap away from where it's needed would only help
                    // someone who already knew it existed.
                    HStack {
                        TextField("Exact weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospacedDigit())
                        Text(GymSettings.shared.unit.symbol)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Exact weight")
                    if case .unparseable = weightEdit {
                        Text("Enter a number, like 135 or 135.5.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Stepper(value: $reps, in: 1...50) {
                        LabeledContent("Reps", value: "\(reps)")
                    }
                } header: {
                    Text(exercise.name)
                }

                if case .unbuildable(let requested, let achievable) = weightEdit {
                    Section {
                        Text("\(requested.formatted(in: GymSettings.shared.unit)) cannot be set on this equipment.")
                        Button("Use \(achievable.formatted(in: GymSettings.shared.unit))") {
                            commit(achievable)
                        }
                        .font(.body.weight(.semibold))
                    } header: {
                        Text("Not available")
                    } footer: {
                        Text("The nearest achievable weight is offered, never substituted silently.")
                    }
                }

                Section {
                    Picker("RPE", selection: $rpe) {
                        Text("—").tag(RPE?.none)
                        ForEach(RPE.sessionChips, id: \.self) { value in
                            Text(String(describing: value)).tag(RPE?.some(value))
                        }
                    }
                    Toggle("Warmup", isOn: $isWarmup)
                } footer: {
                    Text(isWarmup
                         ? "Warmups are recorded but never counted as work."
                         : "Counted in volume, e1RM and progression.")
                }

                Section {
                    Button("Delete this set", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
            .navigationTitle("Correct set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var corrected = set
                        corrected.load = Load(pounds)
                        corrected.reps = reps
                        // A warmup is never scored, so an RPE left on one would
                        // be recorded and never read.
                        corrected.rpe = isWarmup ? nil : rpe
                        corrected.isWarmup = isWarmup
                        onSave(corrected)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete this set?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("It stops counting towards volume, e1RM and your next target.")
            }
            // Every keystroke is checked, not just a final commit — the same
            // reason `TypedWeight` itself treats an empty field as "not yet"
            // rather than an error while a paste or a clear is mid-flight.
            // The moment typing resolves to a real, buildable weight it's
            // folded into `pounds` immediately, so the stepper below and the
            // eventual Save both act on it without a separate confirm step.
            .onChange(of: weightText) { _, newValue in
                guard case .exact(let load) = resolveHistoryWeightEdit(
                    text: newValue, committed: committedText,
                    unit: GymSettings.shared.unit, exercise: exercise
                ) else { return }
                pounds = load.pounds
                committedText = newValue
            }
        }
    }

    /// The stepper's own binding, routed through here so a tap on it also
    /// keeps the typed field's text in sync (#218) — without this, stepping
    /// down after typing a big correction would leave the text field showing
    /// a number `pounds` had already moved past.
    private var poundsBinding: Binding<Double> {
        Binding(
            get: { pounds },
            set: { commit(Load($0)) }
        )
    }

    /// Accepts a resolved weight from any source — the stepper, a typed exact
    /// value, or the nearest-achievable offer — and makes it the one thing
    /// every control agrees on.
    private func commit(_ load: Load) {
        pounds = load.pounds
        let text = Self.text(for: load.pounds)
        weightText = text
        committedText = text
    }

    private func format(_ pounds: Double) -> String {
        GymSettings.shared.unit.format(pounds: pounds)
    }

    /// The exact-entry field's text for a given weight: native precision, no
    /// unit symbol (the symbol sits beside the field instead), matching how
    /// `WeightEntrySheet` in `SessionView.swift` reads its own initial text —
    /// that sheet is the pattern this reuses rather than a second parser
    /// (#218).
    private static func text(for pounds: Double) -> String {
        let unit = GymSettings.shared.unit
        return unit.format(unit.value(fromPounds: pounds), withSymbol: false)
    }
}

private struct SetRow: View {
    let set: SetRecord

    var body: some View {
        HStack {
            Text("\(set.load.formatted(in: GymSettings.shared.unit)) × \(set.reps)")
                .font(.body.monospacedDigit())
                .foregroundStyle(set.isWarmup ? .secondary : .primary)
            if set.isWarmup {
                Text("warmup")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let rpe = set.rpe {
                // `historyRPEText` (top of this file) already reads "RPE 8"
                // (`RPE.description`, added in #4/#5, before this row
                // existed) — wrapping it in another literal "RPE " here read
                // "RPE RPE 8" (#218). `SessionView.swift`'s equivalent row
                // already gets this right with the same `Text(rpe.description)`,
                // which is the pattern this matches.
                Text(historyRPEText(rpe))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
