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
                    ForEach(trends) { trend in
                        Section {
                            TrendRow(trend: trend)
                        } header: {
                            Text(trend.exercise.name)
                        }
                    }
                }
            }
        }
        .navigationTitle("Progress")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TrendRow: View {
    private var gym: GymSettings { .shared }

    /// The point under the thumb, or `nil` at rest (#101).
    ///
    /// `@GestureState` rather than `@State` on purpose. It resets itself when
    /// the gesture ends *or is interrupted*, and inside a `List` interruption
    /// is the common case: a drag that turns vertical is taken over by the
    /// enclosing scroll view, which cancels this gesture without ever calling
    /// `onEnded`. With plain `@State` that path strands a marker on the chart
    /// of a lift you have already scrolled past.
    @GestureState private var scrubbed: TrendPoint?

    let trend: E1RMTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // The headline is the one number on this screen nobody lifted,
                // and it was the only one not saying what it was — read on the
                // phone as a weight that had been on a bar. The caption sits
                // above rather than beside it so the number keeps the row, and
                // so the summary's baseline alignment is undisturbed.
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
            // Otherwise VoiceOver reads three unrelated fragments and the
            // caption labels nothing — which is the failure this issue is
            // about, in the one place it is hardest to notice.
            .accessibilityElement(children: .combine)

            if trend.isMeaningful {
                chart
            } else {
                // An honest empty state rather than a two-point line, which
                // would look like a trend no matter what the lift did.
                sparse
            }
        }
        .padding(.vertical, 6)
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
        .frame(height: 130)
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
