//
//  HistoryView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

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
    let days: [TrainingDay]

    @State private var month: Date = Calendar.current.startOfDay(for: Date())
    @State private var selected: TrainingDay?

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
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { day in
            DayDetailView(day: day)
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
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button(action: onForward) {
                Image(systemName: "chevron.right").font(.body.weight(.semibold))
            }
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
            } else {
                square(for: nil)
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

    var body: some View {
        List {
            ForEach(day.exercises) { performed in
                Section {
                    ForEach(performed.sets, id: \.id) { set in
                        SetRow(set: set)
                    }
                } header: {
                    HStack {
                        Text(performed.exercise.name)
                        Spacer()
                        if let top = performed.topSet {
                            Text("top \(top.load) × \(top.reps)")
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
    }

    private var title: String {
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).month().day())
        guard let kind = day.kind else { return date }
        return "\(kind.rawValue.capitalized) · \(date)"
    }
}

private struct SetRow: View {
    let set: SetRecord

    var body: some View {
        HStack {
            Text("\(set.load) × \(set.reps)")
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
