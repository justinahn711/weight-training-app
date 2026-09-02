//
//  TrendsView.swift
//  ChickenBreast
//

import Charts
import SwiftUI
import WeightTrainingCore

/// e1RM trend per lift (#24) — the "am I actually progressing" view.
///
/// RPE-adjusted, so the same weight moved more easily reads as progress rather
/// than as a flat week. That adjustment is the reason this chart is worth
/// drawing at all: raw top-set weight would show a plateau through exactly the
/// stretch where the lift got stronger.
struct TrendsView: View {
    let trends: [E1RMTrend]

    var body: some View {
        Group {
            if trends.isEmpty {
                ContentUnavailableView(
                    "Nothing logged yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Trends appear once you've trained a lift.")
                )
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.trends) { trend in
                                NavigationLink {
                                    TrendDetailView(trend: trend)
                                } label: {
                                    TrendSummaryRow(trend: trend)
                                }
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
            }
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Lifts grouped by the muscle they primarily train.
    ///
    /// A chart per lift in one list is right at three lifts and wrong at
    /// twenty-five: the screen you open to answer one question makes you scroll
    /// past every other. `E1RMTrendBuilder` already omits lifts with no history
    /// for the same reason — "sixteen of them empty buries the three that have
    /// something to say" — but that filter stops helping once they all have
    /// history, which is exactly when the app has been working.
    ///
    /// Grouped on the primary muscle rather than the day kind, because day
    /// membership lives on a mutable `DayTemplate`: grouping a year of history
    /// by it would move when a template is edited, and a lift dropped from a
    /// template would lose its home while keeping its history. The muscle is a
    /// fact about the lift.
    private var groups: [(title: String, trends: [E1RMTrend])] {
        let byMuscle = Dictionary(grouping: trends) { $0.primaryMuscle }
        return Self.muscleOrder.compactMap { muscle in
            guard let group = byMuscle[muscle], !group.isEmpty else { return nil }
            return (muscle.displayName, group.sorted { $0.exercise.name < $1.exercise.name })
        } + (byMuscle[nil].map { [("Other", $0.sorted { $0.exercise.name < $1.exercise.name })] } ?? [])
    }

    /// Push, then pull, then legs — the order the training is thought about.
    ///
    /// Deliberately a presentation ordering rather than a `Muscle.dayKind` in
    /// Core. Day kinds here are *derived from logged sets*, not from muscle
    /// taxonomy, so asserting a fixed muscle-to-day relationship in the domain
    /// would state something the engine does not believe.
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

/// One line in the list: enough to see which lifts are moving without opening
/// any of them, and no more.
private struct TrendSummaryRow: View {
    private var gym: GymSettings { .shared }

    let trend: E1RMTrend

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trend.exercise.name)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let latest = trend.latest {
                        Text(latest.e1RM.rounded.formatted(in: gym.unit))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(trend.summary(in: gym.unit))
                        .font(.caption)
                        .foregroundStyle(trend.isMeaningful ? .secondary : .tertiary)
                }
            }
            Spacer(minLength: 0)
            // Shape only, and only once there is a shape to show: the same
            // three-session floor the full chart uses, for the same reason —
            // two points always make a straight line.
            if trend.isMeaningful { sparkline }
        }
        .accessibilityElement(children: .combine)
    }

    private var sparkline: some View {
        Chart(trend.points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
            )
            .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(width: 64, height: 26)
        .accessibilityHidden(true)
    }
}

/// One lift, on its own screen.
///
/// The chart owns this screen rather than sharing a scrolling list with two
/// dozen others, which is what makes the scrub gesture unambiguous: there is
/// no vertical scroll competing for the same drag (#104, #105).
struct TrendDetailView: View {
    private var gym: GymSettings { .shared }

    /// The point under the thumb, or `nil` at rest (#101).
    ///
    /// `@GestureState` rather than `@State` on purpose: it resets itself when
    /// the gesture ends *or is interrupted*, so no path can strand a marker on
    /// a chart nobody is touching.
    ///
    /// That mattered more when this chart lived inside the Trends list, where a
    /// drag turning vertical was taken over by the scroll view and cancelled
    /// without ever calling `onEnded`. On its own screen the competition is
    /// gone — which is the point of #105 — but interruption is still possible
    /// and the cheaper primitive is still the right one.
    @GestureState private var scrubbed: TrendPoint?

    let trend: E1RMTrend

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                // The headline is the one number on this screen nobody lifted,
                // and it was the only one not saying what it was — read on the
                // phone as a weight that had been on a bar.
                //
                // "Latest", not "Estimated 1RM" flat, because the number is
                // `points.last` and `best` is a different value that exists
                // right beside it. After a deload the plain caption would read
                // "Estimated 1RM · 190" while the lifter's best estimate is
                // 225 — asserting a current maximum on precisely the weeks
                // someone is most anxious about that number. The bare figure
                // was merely ambiguous; a confident wrong label is worse.
                //
                // `.secondary`, not `.tertiary`: two lines down this view uses
                // tertiary to mean "too thin to trust yet", so rendering the
                // one element whose whole job is to be read in that style says
                // the opposite of what it is for.
                //
                // It lives here, on the detail screen, and NOT on the compact
                // list row — that row is already titled with the lift's name
                // and carries a smaller, secondary figure, so a caption there
                // would be noise repeated twenty-five times.
                if trend.latest != nil {
                    Text("Latest estimated 1RM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    if let latest = trend.latest {
                        Text(latest.e1RM.rounded.formatted(in: gym.unit))
                            .font(.title2.bold().monospacedDigit())
                    }
                    Text(trend.summary(in: gym.unit))
                        .font(.subheadline)
                        .foregroundStyle(trend.isMeaningful ? .secondary : .tertiary)
                }
                }
                // Grouped so VoiceOver reads the caption and the number as one
                // thing. Bound to the headline pair specifically, not to the
                // whole card — sweeping the chart in would undo the per-point
                // labels that make it readable without the scrub gesture.
                .accessibilityElement(children: .combine)

                if trend.isMeaningful {
                    chart
                } else {
                    // An honest empty state rather than a two-point line, which
                    // would look like a trend no matter what the lift did.
                    sparse
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(trend.exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chart: some View {
        Chart {
            ForEach(trend.points) { point in
                // Plotted in the lifter's unit, not the stored one. An axis
                // reading 225 under a summary reading "+10 kg" describes the same
                // lift twice in two languages (#67).
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
                )
                .interpolationMethod(.monotone)
                .accessibilityHidden(true)
                PointMark(
                    x: .value("Date", point.date),
                    y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
                )
                .symbolSize(40)
                // The scrub gesture is the feature, and a VoiceOver user cannot
                // perform it. Labelling the points is the same reading by
                // another route, so the acceptance criterion — every plotted
                // value legible without leaving the screen — holds for both.
                .accessibilityLabel(point.date.formatted(.dateTime.month(.abbreviated).day()))
                .accessibilityValue(readout(for: point))
            }

            // Nothing is added at rest, so the chart draws exactly what it drew
            // before this change.
            if let scrubbed {
                marker(for: scrubbed)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            // Sessions, not weekdays — the cycle drifts against the calendar
            // and a weekday label would imply a schedule that doesn't exist.
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        // Taller than it was as a list row. 130pt was a compromise with two
        // dozen charts stacked in one scroll; on its own screen the plot can
        // have the room, which also gives the callout somewhere to sit that
        // is not on top of the curve.
        .frame(height: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(scrub(proxy: proxy, geometry: geometry))
            }
        }
    }

    // MARK: - Scrubbing (#101)

    /// Touch and drag to read a point; release to return to rest.
    ///
    /// `minimumDistance: 0` so the first touch already reads, rather than
    /// requiring a wiggle before the chart answers. The list still scrolls: a
    /// drag that goes vertical is claimed by the scroll view, which cancels
    /// this gesture, and `@GestureState` puts the chart back at rest.
    private func scrub(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($scrubbed) { drag, state, _ in
                state = point(under: drag.location, proxy: proxy, geometry: geometry)
            }
    }

    /// The plotted point the touch is reading, or `nil` if it is reading none.
    ///
    /// Unknown means silent. Outside the plot area, or past either end of the
    /// series, there is no answer — so the marker disappears rather than
    /// pinning itself to whichever session happens to be closest. Snapping the
    /// last point to a finger dragged off the right edge would report a date
    /// the lifter is not pointing at.
    ///
    /// Within the plot the vertical position is ignored on purpose. The marker
    /// is a full-height column, so anywhere in that column is on the point, and
    /// a thumb dragged across a 130pt chart wanders far more in y than the
    /// series does.
    private func point(
        under location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> TrendPoint? {
        guard let anchor = proxy.plotFrame else { return nil }
        let plot = geometry[anchor]

        guard location.x >= plot.minX, location.x <= plot.maxX,
              location.y >= 0, location.y <= geometry.size.height,
              let touched = proxy.value(atX: location.x - plot.minX, as: Date.self)
        else { return nil }

        return trend.points.min {
            abs($0.date.timeIntervalSince(touched)) < abs($1.date.timeIntervalSince(touched))
        }
    }

    @ChartContentBuilder
    private func marker(for point: TrendPoint) -> some ChartContent {
        // Declared before the rule, because later marks paint over earlier ones
        // and an annotation does not escape that: with the dot declared last, a
        // point near the top of the range covered the callout describing it.
        // Found on the phone — the plot is 130pt tall, so "near the top" is
        // most of a rising lift.
        PointMark(
            x: .value("Date", point.date),
            y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
        )
        .symbolSize(110)
        .accessibilityHidden(true)

        RuleMark(x: .value("Date", point.date))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .accessibilityHidden(true)
            // Drawn inside the plot rather than in a row above it: a callout
            // that appears in the layout would push the chart down under the
            // thumb that summoned it, and reserving the space permanently
            // would change the resting screen for a state it is rarely in.
            .annotation(
                position: .top,
                alignment: .center,
                spacing: 2,
                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
            ) {
                callout(for: point)
            }

    }

    private func callout(for point: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(point.e1RM.rounded.formatted(in: gym.unit))
                    .font(.footnote.bold().monospacedDigit())
                // Month and day, matching the axis. No weekday, for the reason
                // the axis gives.
                Text(point.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // The set is what happened; the estimate above it is arithmetic.
            // Without this line the curve is a number nobody can reconcile with
            // their logbook — and because e1RM is RPE-adjusted, two identical
            // sets at different RPE sit at different heights, which reads as a
            // bug until the RPE is on screen next to them.
            Text(origin(of: point.topSet))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// `from 185 lb × 5 @ RPE 8`, in the gym's unit.
    private func origin(of set: SetRecord) -> String {
        let performed = "from \(set.load.formatted(in: gym.unit)) × \(set.reps)"
        guard let rpe = set.rpe else { return performed }
        return "\(performed) @ \(rpe)"
    }

    /// What a point says, in one phrase — the callout, read aloud.
    private func readout(for point: TrendPoint) -> String {
        "\(point.e1RM.rounded.formatted(in: gym.unit)), \(origin(of: point.topSet))"
    }

    private var sparse: some View {
        HStack(spacing: 10) {
            ForEach(0..<E1RMTrend.minimumSessions, id: \.self) { index in
                Capsule()
                    .fill(index < trend.points.count ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(height: 6)
            }
        }
        .padding(.vertical, 8)
    }
}

private extension Load {
    /// Whole pounds for display — an estimate carrying a decimal implies a
    /// precision it doesn't have.
    var rounded: Load { Load(pounds.rounded()) }
}
