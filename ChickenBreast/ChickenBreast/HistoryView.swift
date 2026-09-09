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

    /// Reloaded here rather than handed down, because correcting a set (#61)
    /// changes what this screen shows and the change has to be visible without
    /// leaving it.
    @State private var days: [TrainingDay]
    @State private var month: Date = Calendar.current.startOfDay(for: Date())
    @State private var selected: TrainingDay?

    init(days: [TrainingDay], store: TrainingStore) {
        self.store = store
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
            DayDetailView(day: day, store: store, onChange: reload)
        }
    }

    /// Re-reads history and re-points the open day at its corrected self.
    ///
    /// A day that lost its last set disappears, which closes the detail screen
    /// rather than leaving it showing a session that no longer exists.
    private func reload() {
        days = (try? store.trainingDays()) ?? []
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
            .frame(minWidth: 44, minHeight: 44)
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fullDate)
                    .accessibilityValue(trainingDescription(day))
                    .accessibilityHint("Shows this workout")
                    .accessibilityIdentifier(dayIdentifier)
            } else {
                square(for: nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fullDate)
                    .accessibilityValue(isToday ? "Today, no workout" : "No workout")
                    .accessibilityIdentifier(dayIdentifier)
            }
        }
    }

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
        .frame(minHeight: 44)
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

    private var fullDate: String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    private var dayIdentifier: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "history.day.%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func trainingDescription(_ day: TrainingDay) -> String {
        let workout = day.kind?.rawValue.capitalized ?? "Workout"
        let sets = day.exercises.reduce(0) { $0 + $1.sets.count }
        let setLabel = sets == 1 ? "set" : "sets"
        return "\(workout), \(sets) \(setLabel)"
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

    @State private var editing: EditTarget?
    @State private var failure: String?

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
                            editing = EditTarget(record: set, exercise: performed.exercise)
                        } label: {
                            SetRow(set: set)
                        }
                        .buttonStyle(.plain)
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
        .alert("Couldn't save that", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
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
                Text("It stops counting towards volume, e1RM and your next target.")
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
