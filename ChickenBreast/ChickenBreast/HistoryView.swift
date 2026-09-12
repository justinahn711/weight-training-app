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
    let activeSetIDs: Set<UUID>
    let onSetsDeleted: () -> Void

    /// Reloaded here rather than handed down, because correcting a set (#61)
    /// changes what this screen shows and the change has to be visible without
    /// leaving it.
    @State private var days: [TrainingDay]
    @State private var month: Date = Calendar.current.startOfDay(for: Date())
    @State private var selected: TrainingDay?
    @State private var weeklyTarget = 3

    init(
        days: [TrainingDay],
        store: TrainingStore,
        activeSetIDs: Set<UUID> = [],
        onSetsDeleted: @escaping () -> Void = {}
    ) {
        self.store = store
        self.activeSetIDs = activeSetIDs
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
            DayDetailView(
                day: day,
                store: store,
                activeSetIDs: activeSetIDs,
                onChange: reload,
                onSetsDeleted: onSetsDeleted
            )
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
    let activeSetIDs: Set<UUID>
    let onChange: () -> Void
    let onSetsDeleted: () -> Void

    @State private var editing: EditTarget?
    @State private var failure: String?
    @State private var isSelecting = false
    @State private var selectedSetIDs: Set<UUID> = []
    @State private var confirmingBulkDelete = false

    /// A set, plus the lift it belongs to — the editor needs the increment to
    /// step the weight by, and the lift isn't on the record.
    struct EditTarget: Identifiable {
        /// Named `record` rather than `set`: inside a computed property, `set`
        /// reads as the start of a setter and the parser gives up.
        let record: SetRecord
        let exercise: Exercise
        var id: UUID { record.id }
    }

    var body: some View {
        List {
            ForEach(day.exercises) { performed in
                Section {
                    ForEach(performed.sets, id: \.id) { set in
                        Button {
                            if isSelecting {
                                toggleSelection(of: set.id)
                            } else {
                                editing = EditTarget(record: set, exercise: performed.exercise)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if isSelecting {
                                    Image(systemName: selectedSetIDs.contains(set.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedSetIDs.contains(set.id)
                                                         ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(.secondary))
                                        .accessibilityHidden(true)
                                }
                                SetRow(set: set)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(rowAccessibilityLabel(for: set))
                        .accessibilityHint(isSelecting
                            ? (selectedSetIDs.contains(set.id)
                               ? "Double tap to remove from selection."
                               : "Double tap to select for deletion.")
                            : "Double tap to edit this set.")
                        .accessibilityAddTraits(
                            isSelecting && selectedSetIDs.contains(set.id) ? .isSelected : []
                        )
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Cancel" : "Select") {
                    if isSelecting {
                        leaveSelectionMode()
                    } else {
                        isSelecting = true
                    }
                }
                .accessibilityIdentifier("history.selection.toggle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .sheet(item: $editing) { target in
            EditSetView(
                set: target.record,
                exercise: target.exercise,
                onSave: { corrected in
                    apply { try store.updateSet(corrected) }
                },
                onDelete: {
                    apply { try store.deleteSet(id: target.record.id) }
                }
            )
        }
        .confirmationDialog(deleteConfirmationTitle,
                            isPresented: $confirmingBulkDelete,
                            titleVisibility: .visible) {
            Button(deleteButtonTitle, role: .destructive) {
                deleteSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("Couldn't update history", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var allSetIDs: Set<UUID> {
        Set(day.exercises.flatMap(\.sets).map(\.id))
    }

    private var selectedActiveSetCount: Int {
        selectedSetIDs.intersection(activeSetIDs).count
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button(selectedSetIDs == allSetIDs ? "Deselect all" : "Select all") {
                    selectedSetIDs = selectedSetIDs == allSetIDs ? [] : allSetIDs
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("history.selection.all")
                Spacer()
                Text("\(selectedSetIDs.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(selectedSetIDs.count) sets selected")
            }

            Button(role: .destructive) {
                confirmingBulkDelete = true
            } label: {
                Text(deleteButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedSetIDs.isEmpty)
            .accessibilityIdentifier("history.selection.delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleSelection(of id: UUID) {
        if selectedSetIDs.contains(id) {
            selectedSetIDs.remove(id)
        } else {
            selectedSetIDs.insert(id)
        }
    }

    private func leaveSelectionMode() {
        selectedSetIDs = []
        isSelecting = false
        confirmingBulkDelete = false
    }

    private func deleteSelection() {
        do {
            _ = try store.deleteSets(ids: selectedSetIDs)
            leaveSelectionMode()
            onSetsDeleted()
            onChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    private var deleteButtonTitle: String {
        "Delete \(selectedSetIDs.count) \(selectedSetIDs.count == 1 ? "set" : "sets")"
    }

    private var deleteConfirmationTitle: String {
        "Delete \(selectedSetIDs.count) \(selectedSetIDs.count == 1 ? "set" : "sets") from \(confirmationDate)?"
    }

    private var deleteConfirmationMessage: String {
        var message = "This removes them from History, volume, records, and trends. Existing next targets won't change automatically."
        if selectedActiveSetCount > 0 {
            message += " \(selectedActiveSetCount == 1 ? "One set is" : "\(selectedActiveSetCount) sets are") also in your active workout and will be removed there."
        }
        return message
    }

    private var confirmationDate: String {
        day.date.formatted(.dateTime.month(.wide).day().year())
    }

    private func rowAccessibilityLabel(for set: SetRecord) -> String {
        var parts = ["\(set.load.formatted(in: GymSettings.shared.unit)), \(set.reps) reps"]
        if set.isWarmup { parts.append("warmup") }
        if let rpe = set.rpe { parts.append("RPE \(rpe)") }
        if isSelecting {
            parts.append(selectedSetIDs.contains(set.id) ? "selected" : "not selected")
        }
        return parts.joined(separator: ", ")
    }

    private func apply(_ work: () throws -> Void) {
        do {
            try work()
            onChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    private var title: String {
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).month().day())
        guard let kind = day.kind else { return date }
        return "\(kind.rawValue.capitalized) · \(date)"
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
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Stepped by the lift's own increment, so a correction
                    // can't produce a weight the equipment can't be set to
                    // (#20, #39).
                    Stepper(value: $pounds, in: 0...2000, step: exercise.increment.pounds) {
                        // Stepped in pounds because that is what is stored, but
                        // read in the unit the lifter uses (#67) — the step
                        // itself is the equipment's own, so the numbers land
                        // where the equipment does.
                        LabeledContent("Weight", value: format(pounds))
                    }
                    Stepper(value: $reps, in: 1...50) {
                        LabeledContent("Reps", value: "\(reps)")
                    }
                } header: {
                    Text(exercise.name)
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
                }
            }
            .confirmationDialog("Delete this set?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("It stops counting towards future volume, e1RM and history. A target already applied when you finished the workout does not rewind.")
            }
        }
    }

    private func format(_ pounds: Double) -> String {
        GymSettings.shared.unit.format(pounds: pounds)
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
                Text("RPE \(rpe)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
