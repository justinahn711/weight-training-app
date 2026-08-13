//
//  ContentView.swift
//  ChickenBreast
//

import SwiftUI
import WeightTrainingCore
import WeightTrainingStore

/// Temporary scaffolding that proves the app is wired to the package and that
/// the seeded library survives a launch. The real session screen replaces this
/// in #3.
struct ContentView: View {
    @State private var exercises: [Exercise] = []
    @State private var loadFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadFailure {
                    ContentUnavailableView(
                        "Couldn't open the training store",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadFailure)
                    )
                } else {
                    List(exercises) { exercise in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(.headline)
                            Text(exercise.primaryMuscles.map(\.rawValue).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
        .task {
            do {
                let store = try TrainingStore()
                try store.seedLibraryIfNeeded()
                exercises = try store.exercises()
            } catch {
                loadFailure = String(describing: error)
            }
        }
    }
}

#Preview {
    ContentView()
}
