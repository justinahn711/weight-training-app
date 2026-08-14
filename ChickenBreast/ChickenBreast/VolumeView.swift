//
//  VolumeView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore

/// Trailing 7-day volume by muscle (#25).
///
/// The guard against flexible exercise selection quietly creating holes. Days
/// are shapes and slots offer choices, which is what keeps a busy rack from
/// costing a session — but it also means nobody is counting, and a lift skipped
/// three times running is invisible until something stops growing.
///
/// Starved muscles are listed first. The whole screen exists to answer one
/// question — what am I missing — so the answer shouldn't be somewhere in an
/// alphabetical list.
struct VolumeView: View {
    let report: VolumeReport

    private var ordered: [MuscleVolume] {
        report.starved.sorted { $0.sets < $1.sets }
            + report.muscles.filter { $0.standing == .onTarget }
            + report.overreaching
    }

    var body: some View {
        List {
            if !report.starved.isEmpty {
                Section {
                    ForEach(report.starved.sorted { $0.sets < $1.sets }) { volume in
                        MuscleRow(volume: volume)
                    }
                } header: {
                    Text("Behind")
                } footer: {
                    Text("Below the bottom of the band over the last 7 days.")
                }
            }

            let onTarget = report.muscles.filter { $0.standing == .onTarget }
            if !onTarget.isEmpty {
                Section("On target") {
                    ForEach(onTarget) { MuscleRow(volume: $0) }
                }
            }

            if !report.overreaching.isEmpty {
                Section {
                    ForEach(report.overreaching) { MuscleRow(volume: $0) }
                } header: {
                    Text("Above the band")
                } footer: {
                    Text("Not a problem on its own — worth seeing before it becomes one.")
                }
            }
        }
        .navigationTitle("Last 7 days")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MuscleRow: View {
    let volume: MuscleVolume

    private var tint: Color {
        switch volume.standing {
        case .starved:      return .orange
        case .onTarget:     return .green
        case .overreaching: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(volume.muscle.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(volume.displayLine)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // A bar rather than a number alone: the question is "how far off",
            // and that reads faster as a length than as arithmetic.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, proxy.size.width * volume.progress))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}

extension Muscle {
    /// `frontDelts` reads as "Front delts" rather than as an identifier.
    var displayName: String {
        rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                  options: .regularExpression)
            .lowercased()
            .prefix(1).uppercased()
        + rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                  options: .regularExpression)
            .lowercased()
            .dropFirst()
    }
}
