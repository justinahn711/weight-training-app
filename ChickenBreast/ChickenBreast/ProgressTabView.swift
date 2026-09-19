//
//  ProgressTabView.swift
//  ChickenBreast
//
//  The Progress tab: this week's rings, volume over the last twelve weeks,
//  and every lift's trend, grouped by the muscle it trains.
//

import Charts
import SwiftUI
import WeightTrainingCore

struct ProgressTabView: View {
    let trends: [E1RMTrend]
    let summary: WeeklySummary?
    let weekly: [WeeklyVolumePoint]
    let days: [TrainingDay]
    let consistency: WeeklyConsistency

    private var hasAnything: Bool {
        !trends.isEmpty || weekly.contains { $0.hardSetCount > 0 }
    }

    var body: some View {
        Group {
            if hasAnything {
                ScrollView {
                    // Lazy at the top level and again inside `liftsSection`
                    // (task: platform audit, performance) — the four cards
                    // here are fixed, but the lift list below scales with
                    // the exercise library, which an eager `VStack` would
                    // build in full on first render regardless of how much
                    // of it is ever scrolled to.
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let summary {
                            WeeklyRingsCard(summary: summary, consistency: consistency)
                        }
                        VolumeChartCard(weekly: weekly)
                        ConsistencyCard(cells: ConsistencyGrid.cells(days: days))
                        liftsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                ContentUnavailableView(
                    "Nothing logged yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Rings, volume and trends appear once you've trained.")
                )
            }
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var liftsSection: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(group.trends) { trend in
                            NavigationLink {
                                TrendDetailView(trend: trend)
                            } label: {
                                TrendSummaryRow(trend: trend)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if trend.id != group.trends.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    /// Lifts grouped by the muscle they primarily train, push then pull then
    /// legs. Grouped on the muscle rather than the day kind, because day
    /// membership lives on a mutable `DayTemplate`: a year of history would
    /// move when a template is edited. The muscle is a fact about the lift.
    ///
    /// A presentation ordering, deliberately not a `Muscle.dayKind` in Core.
    /// Day kinds there are derived from logged sets, not from taxonomy.
    private var groups: [(title: String, trends: [E1RMTrend])] {
        let byMuscle = Dictionary(grouping: trends) { $0.primaryMuscle }
        return Self.muscleOrder.compactMap { muscle in
            guard let group = byMuscle[muscle], !group.isEmpty else { return nil }
            return (muscle.displayName, group.sorted { $0.exercise.name < $1.exercise.name })
        } + (byMuscle[nil].map { [("Other", $0.sorted { $0.exercise.name < $1.exercise.name })] } ?? [])
    }

    private static let muscleOrder: [Muscle] = [
        .chest, .frontDelts, .sideDelts, .triceps,
        .lats, .traps, .rearDelts, .biceps, .forearms,
        .quads, .hamstrings, .glutes, .calves,
        .abs,
    ]
}

private extension E1RMTrend {
    var primaryMuscle: Muscle? {
        exercise.muscles.first { $0.role == .primary }?.muscle
    }
}

// MARK: - Rings

/// One ring's worth of colour. Fixed per ring, never by rank: the sessions
/// ring is always the accent, whatever it currently reads. Teal and indigo
/// beside the rust accent, because orange sat next to it read as the same
/// ring twice — and would to anyone with red–green colour vision.
private enum RingPalette {
    // The app's category colours, not the accent: a ring says which measure
    // this is, the same job a day kind does on the calendar. Spending the
    // action colour on one of them made the sessions ring look tappable.
    static let sessions = Theme.categories[0]
    static let sets = Theme.categories[1]
    static let muscles = Theme.categories[2]
}

private struct WeeklyRingsCard: View {
    let summary: WeeklySummary
    let consistency: WeeklyConsistency

    /// The one window name every ring below answers for (#214). Sourced from
    /// the summary itself rather than hard-coded, so this label can never say
    /// something the rings' own math doesn't back up.
    private var windowLabel: String { "Last \(summary.windowDays) days" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(windowLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .center, spacing: 20) {
                ActivityRings(rings: [
                    .init(progress: summary.sessionProgress, color: RingPalette.sessions),
                    .init(progress: summary.setProgress ?? 0, color: RingPalette.sets),
                    .init(progress: summary.muscleProgress, color: RingPalette.muscles),
                ])
                .frame(width: 132, height: 132)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    legend(RingPalette.sessions, "Sessions",
                           "\(summary.sessions) of \(summary.sessionTarget)")
                    // Literal, not muscle-credited: one logged hard set reads
                    // as one here (#214). `MuscleVolume.sets`, reachable from
                    // the muscle detail screen, is the weighted number.
                    legend(RingPalette.sets, "Hard sets", setsLine,
                           note: summary.usualHardSets == nil ? "usual after a week" : nil)
                    legend(RingPalette.muscles, "Muscles fed",
                           "\(summary.musclesOnTarget) of \(summary.muscleCount)")
                }
                Spacer(minLength: 0)
            }

            Label(streakLine, systemImage: "calendar.badge.checkmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(windowLabel): \(summary.sessions) of \(summary.sessionTarget) sessions, "
            + "\(setsLine) hard sets, \(summary.musclesOnTarget) of \(summary.muscleCount) muscles fed. "
            + streakLine
        )
        .accessibilityIdentifier("progress.rings")
    }

    private func legend(_ color: Color, _ title: String, _ value: String,
                        note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.semibold).monospacedDigit())
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var setsLine: String {
        let sets = "\(summary.hardSets)"
        guard let usual = summary.usualHardSets else { return sets }
        return "\(sets) of usual \(Self.count(usual))"
    }

    private var streakLine: String {
        guard consistency.weeks > 0 else { return "Hit the target this week to start a streak" }
        return "\(consistency.weeks) week\(consistency.weeks == 1 ? "" : "s") running"
    }

    private static func count(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

/// Concentric rings, outermost first. Draws in with a spring on first
/// appearance — the one animation in this tab, on the one thing that changes
/// day to day.
private struct ActivityRings: View {
    struct Ring: Hashable {
        let progress: Double
        let color: Color
    }

    let rings: [Ring]
    var lineWidth: CGFloat = 12
    var gap: CGFloat = 3

    @State private var revealed = false

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                let inset = CGFloat(index) * (lineWidth + gap)
                Circle()
                    .stroke(ring.color.opacity(0.18), lineWidth: lineWidth)
                    .padding(inset + lineWidth / 2)
                Circle()
                    .trim(from: 0, to: revealed ? ring.progress : 0)
                    .stroke(ring.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset + lineWidth / 2)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.18)) { revealed = true }
        }
    }
}

// MARK: - Volume over time

private struct VolumeChartCard: View {
    let weekly: [WeeklyVolumePoint]

    @State private var region: MuscleRegion?
    @State private var selectedWeek: Date?

    private var calendar: Calendar { .current }

    /// Whether the "All" chip is selected, so every value on the card is a
    /// literal count of hard sets logged that week — no muscle can double-
    /// count a set here, because none is singled out (#214).
    private var isLiteral: Bool { region == nil }

    /// Literal hard-set counts with "All" selected; muscle-credit volume in
    /// one region otherwise. The two are never mixed on one bar — picking a
    /// region is what turns "count" into "credit", because a set that trains
    /// two regions has no honest literal total to give just one of them.
    private var points: [(week: Date, sets: Double)] {
        weekly.map { point in
            let sets = isLiteral ? Double(point.hardSetCount) : point.muscleCredit(in: region)
            return (point.weekStart, sets)
        }
    }

    /// The mean of completed weeks with something in them. The current week
    /// is left out — it is still being written.
    private var average: Double? {
        let done = points.dropLast().filter { $0.sets > 0 }
        guard !done.isEmpty else { return nil }
        return done.reduce(0) { $0 + $1.sets } / Double(done.count)
    }

    private var selected: (week: Date, sets: Double)? {
        guard let selectedWeek else { return nil }
        return points.min {
            abs($0.week.timeIntervalSince(selectedWeek)) < abs($1.week.timeIntervalSince(selectedWeek))
        }
    }

    private var title: String {
        isLiteral ? "Hard sets per week" : "\(region!.displayName) volume per week"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(headline)
                        .font(.title2.bold().monospacedDigit())
                        .contentTransition(.numericText())
                    Text(headlineCaption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // A region total is muscle-credit volume, not a literal set
                // count — a bench press can count toward both chest and
                // arms. Said here so filtering never makes a weighted number
                // look like it was counted on fingers (#214).
                if !isLiteral {
                    Text("Secondary muscle work counts as half a set")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)

            chart
                .frame(height: 150)

            RegionFilterRow(selection: $region)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("progress.volume")
    }

    private var headline: String {
        if let selected { return Self.count(selected.sets) }
        return Self.count(points.last?.sets ?? 0)
    }

    private var headlineCaption: String {
        if let selected {
            return "week of \(selected.week.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if let average { return "this week · avg \(Self.count(average))" }
        return "this week"
    }

    private var chart: some View {
        Chart {
            ForEach(points, id: \.week) { point in
                BarMark(
                    x: .value("Week", point.week, unit: .weekOfYear),
                    y: .value("Sets", point.sets),
                    width: .ratio(0.6)
                )
                // The colour the Hard sets ring already uses, because this
                // chart is that same measure over time. The accent stays on
                // things that can be tapped.
                .foregroundStyle(RingPalette.sets)
                // The week in progress is a partial bar, and reads as one.
                .opacity(point.week == points.last?.week ? 0.45 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(point.week.formatted(.dateTime.month(.abbreviated).day()))
                .accessibilityValue(
                    isLiteral
                        ? "\(Self.count(point.sets)) hard sets"
                        : "\(Self.count(point.sets)) credited sets"
                )
            }

            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg \(Self.count(average))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
            }

            if let selected {
                RuleMark(x: .value("Week", selected.week, unit: .weekOfYear))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .chartXSelection(value: $selectedWeek)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2)
            }
        }
    }

    private static func count(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

// MARK: - Consistency

/// Twelve weeks of days, one square each, darker the more working sets the
/// day had (task 7). A sequential ramp of the one accent hue: magnitude,
/// not identity, so one hue light-to-dark and nothing else. Days after
/// today are blank rather than "rest", and today carries a ring.
private struct ConsistencyCard: View {
    let cells: [ConsistencyCell]

    private var calendar: Calendar { .current }
    private var columns: [[ConsistencyCell]] {
        stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }
    private var trainedDays: Int { cells.filter { $0.intensity != .none }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Consistency")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(trainedDays)")
                        .font(.title2.bold().monospacedDigit())
                    Text("days trained in 12 weeks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { cell in
                            square(cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Consistency grid")

            HStack(spacing: 4) {
                Text("Less")
                ForEach(TrainingIntensity.allCases, id: \.rawValue) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(level))
                        .frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("progress.consistency")
    }

    private func square(_ cell: ConsistencyCell) -> some View {
        let isToday = calendar.isDateInToday(cell.date)
        return RoundedRectangle(cornerRadius: 3)
            .fill(cell.isFuture ? AnyShapeStyle(.clear) : AnyShapeStyle(fill(cell.intensity)))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                }
            }
            .accessibilityLabel(cell.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            .accessibilityValue(
                cell.isFuture ? "upcoming"
                    : cell.workingSets == 0 ? "rest"
                    : "\(cell.workingSets) working sets"
            )
            .accessibilityHidden(cell.isFuture)
    }

    private func fill(_ level: TrainingIntensity) -> AnyShapeStyle {
        switch level {
        case .none: return AnyShapeStyle(.fill.tertiary)
        // One hue, light to dark — a sequential ramp for a magnitude, in the
        // same colour as the sets chart above it, since both count sets.
        case .light: return AnyShapeStyle(RingPalette.sets.opacity(0.32))
        case .moderate: return AnyShapeStyle(RingPalette.sets.opacity(0.58))
        case .heavy: return AnyShapeStyle(RingPalette.sets.opacity(0.8))
        case .full: return AnyShapeStyle(RingPalette.sets)
        }
    }
}

/// One row of chips above the chart: all, then the six regions in a fixed
/// order. Picking one never recolours the bars — the series is "hard sets"
/// whatever the filter, so the hue stays put.
private struct RegionFilterRow: View {
    @Binding var selection: MuscleRegion?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All")
                ForEach(MuscleRegion.allCases, id: \.self) { region in
                    chip(region, region.displayName)
                }
            }
        }
        .accessibilityIdentifier("progress.volume.filter")
    }

    private func chip(_ value: MuscleRegion?, _ title: String) -> some View {
        let isSelected = selection == value
        return Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("progress.volume.filter.\(value?.rawValue ?? "all")")
    }
}
