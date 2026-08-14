//
//  ContentView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// What to train next.
///
/// The cycle is push → pull → legs and never a weekday. The app leads with the
/// day that's due — read from cycle position, not the calendar — while leaving
/// the other two a tap away, because the rack you need is sometimes busy and
/// the app suggests rather than decides.
struct ContentView: View {
    @State private var store: TrainingStore?
    @State private var startupFailure: String?
    @State private var route: DayKind?
    @State private var cycle: CyclePosition?
    @State private var volume: VolumeReport?
    @State private var showingVolume = false

    var body: some View {
        NavigationStack {
            Group {
                if let startupFailure {
                    ContentUnavailableView(
                        "Couldn't open the training store",
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupFailure)
                    )
                } else {
                    dayPicker
                }
            }
            .navigationTitle("ChickenBreast")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Volume", systemImage: "chart.bar") { showingVolume = true }
                        .disabled(volume == nil)
                }
            }
            .navigationDestination(isPresented: $showingVolume) {
                if let volume {
                    VolumeView(report: volume)
                }
            }
            .navigationDestination(item: $route) { kind in
                sessionDestination(for: kind)
            }
        }
        .task { await openStore() }
        // Recomputed on return from a session, so finishing a push day moves
        // the home screen on to pull without a relaunch.
        .onChange(of: route) { _, newValue in
            guard newValue == nil, let store else { return }
            cycle = try? store.cyclePosition()
            volume = try? store.volumeReport()
        }
    }

    private var dayPicker: some View {
        VStack(spacing: 16) {
            Spacer()

            if let cycle {
                Text(cycle.summary())
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The volume guard is worth nothing behind a tap nobody takes, so
            // the headline finding sits on the first screen.
            if let volume, !volume.starved.isEmpty {
                Button { showingVolume = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(starvedSummary(volume))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(orderedDays, id: \.self) { kind in
                let isNext = kind == cycle?.next
                Button {
                    route = kind
                } label: {
                    HStack {
                        Text(kind.rawValue.capitalized)
                            .font(isNext ? .title.bold() : .title3.weight(.semibold))
                        Spacer()
                        Text(subtitle(for: kind))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: isNext ? 88 : 68)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isNext ? AnyShapeStyle(.tint.opacity(0.15))
                                         : AnyShapeStyle(.fill.tertiary))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(isNext ? AnyShapeStyle(.tint)
                                                 : AnyShapeStyle(.clear), lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                .disabled(store == nil)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    /// Names the muscles that are behind, at most three — a list of ten is a
    /// wall of text nobody reads, and the worst three are the actionable part.
    private func starvedSummary(_ report: VolumeReport) -> String {
        let worst = report.starved.sorted { $0.sets < $1.sets }.prefix(3)
        let names = worst.map { $0.muscle.displayName.lowercased() }
        let remainder = report.starved.count - worst.count
        let list = names.joined(separator: ", ")
        return remainder > 0
            ? "Behind on \(list) and \(remainder) more"
            : "Behind on \(list)"
    }

    /// The due day first, then the rest of the cycle in order.
    private var orderedDays: [DayKind] {
        guard let next = cycle?.next else { return DayKind.allCases }
        return [next, next.next, next.next.next]
    }

    private func subtitle(for kind: DayKind) -> String {
        let slots = DayTemplateLibrary.template(for: kind).slots.count
        guard let days = cycle?.daysSince(kind) else { return "\(slots) slots" }
        switch days {
        case 0:  return "today"
        case 1:  return "yesterday"
        default: return "\(days) days ago"
        }
    }

    @ViewBuilder
    private func sessionDestination(for kind: DayKind) -> some View {
        if let store {
            // Built here rather than in the picker so the session is assembled
            // from disk at the moment it's opened, not when the list rendered.
            switch Result(catching: { try store.startSession(kind: kind) }) {
            case .success(let session):
                SessionView(model: SessionViewModel(store: store, session: session))
            case .failure(let error):
                ContentUnavailableView(
                    "Couldn't start the session",
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: error))
                )
            }
        }
    }

    private func openStore() async {
        guard store == nil, startupFailure == nil else { return }
        do {
            let opened = try TrainingStore()
            // Before anything reads: a duplicate arriving from another device
            // (#19) must never be observed, even briefly. On a clean store this
            // is one fetch per entity and no writes.
            try opened.deduplicate()
            try opened.seedLibraryIfNeeded()
            try opened.seedTemplatesIfNeeded()
            cycle = try opened.cyclePosition()
            volume = try opened.volumeReport()
            store = opened
        } catch {
            startupFailure = String(describing: error)
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () throws -> Success) {
        do { self = .success(try body()) }
        catch { self = .failure(error) }
    }
}

#Preview {
    ContentView()
}
