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
        Chart(trend.points) { point in
            // Plotted in the lifter's unit, not the stored one. An axis
            // reading 225 under a summary reading "+10 kg" describes the same
            // lift twice in two languages (#67).
            LineMark(
                x: .value("Date", point.date),
                y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
            )
            .interpolationMethod(.monotone)
            PointMark(
                x: .value("Date", point.date),
                y: .value(gym.unit.symbol, point.e1RM.value(in: gym.unit))
            )
            .symbolSize(40)
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
