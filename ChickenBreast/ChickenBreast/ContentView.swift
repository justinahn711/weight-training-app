//
//  ContentView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// Pick a day and start.
///
/// The cycle is push → pull → legs and never a weekday, so this offers the
/// three days rather than a calendar. Choosing the day for you is the
/// cycle-position engine's job (#17); until then the choice is explicit.
struct ContentView: View {
    @State private var store: TrainingStore?
    @State private var startupFailure: String?
    @State private var route: DayKind?

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
            .navigationDestination(item: $route) { kind in
                sessionDestination(for: kind)
            }
        }
        .task { await openStore() }
    }

    private var dayPicker: some View {
        VStack(spacing: 16) {
            Spacer()
            ForEach(DayKind.allCases, id: \.self) { kind in
                Button {
                    route = kind
                } label: {
                    HStack {
                        Text(kind.rawValue.capitalized)
                            .font(.title2.bold())
                        Spacer()
                        Text("\(ExerciseLibrary.exercises(for: kind).count) lifts")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 72)
                    .frame(maxWidth: .infinity)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(store == nil)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
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
            try opened.seedLibraryIfNeeded()
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
