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
    let trend: E1RMTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let latest = trend.latest {
                    Text(latest.e1RM.rounded.description)
                        .font(.title2.bold().monospacedDigit())
                }
                Text(trend.summary(in: GymSettings.shared.unit))
                    .font(.subheadline)
                    .foregroundStyle(trend.isMeaningful ? .secondary : .tertiary)
            }

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
            LineMark(
                x: .value("Date", point.date),
                y: .value("e1RM", point.e1RM.pounds)
            )
            .interpolationMethod(.monotone)
            PointMark(
                x: .value("Date", point.date),
                y: .value("e1RM", point.e1RM.pounds)
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
