//
//  DigestView.swift
//  ChickenBreast
//

import SwiftUI
import UserNotifications
import WeightTrainingCore
import WeightTrainingStore

/// The weekly nudge digest (#27).
///
/// Every bullet comes from the same signals the in-session chips use, so the
/// app never says one thing at the rack and another here.
///
/// Applying a bullet writes a target and nothing else — the same contract as a
/// suggestion chip. Nothing is applied by arriving.
struct DigestView: View {
    let digest: Digest
    let store: TrainingStore
    var onApplied: () -> Void = {}

    @State private var applied: Set<String> = []
    @State private var failure: String?

    var body: some View {
        Group {
            if digest.isEmpty {
                ContentUnavailableView(
                    "Nothing to flag",
                    systemImage: "checkmark.circle",
                    description: Text("No stalls, no holes in your volume. Keep going.")
                )
            } else {
                List {
                    Section {
                        ForEach(digest.bullets) { bullet in
                            BulletRow(
                                bullet: bullet,
                                isApplied: applied.contains(bullet.id),
                                onApply: { apply(bullet) }
                            )
                        }
                    } footer: {
                        Text("From the last 7 days. Tapping a suggestion changes only "
                             + "your next target — nothing is applied on its own.")
                    }
                }
            }
        }
        .navigationTitle("This week")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't apply that", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func apply(_ bullet: DigestBullet) {
        guard case .deload(let exerciseID, let load) = bullet.action else { return }
        do {
            var state = try store.progressState(forExercise: exerciseID)
                ?? ProgressState(exerciseID: exerciseID)
            state.targetLoad = load
            // A deload is a fresh start at a lighter weight, so the counters
            // that led here are cleared rather than carried into it.
            state.stallCount = 0
            state.consecutiveTopHits = 0
            try store.save(state)
            applied.insert(bullet.id)
            onApplied()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct BulletRow: View {
    let bullet: DigestBullet
    let isApplied: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bullet.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if bullet.isActionable {
                Button(action: onApply) {
                    Label(isApplied ? "Applied" : "Apply",
                          systemImage: isApplied ? "checkmark" : "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(isApplied)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Schedules the digest notification.
///
/// The delivery is weekly and the content never is. #17's rule is that no
/// weekday appears anywhere the app *speaks* — a repeating reminder to sit down
/// and read something isn't a training decision, and the digest's own text is
/// tested to be weekday-free.
enum DigestNotification {

    /// Sunday evening, per the issue: a time to read, not a time to train.
    static let weekday = 1
    static let hour = 19

    static let identifier = "weekly-digest"

    /// Asks once, then schedules. Declining is remembered by the system, so
    /// this is safe to call on every launch.
    static func schedule() async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]),
              granted else { return }

        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour

        let content = UNMutableNotificationContent()
        content.title = "This week"
        // Deliberately vague: the findings are computed when the digest is
        // opened, not when it was scheduled days earlier, so the notification
        // can't promise a stale finding.
        content.body = "Your training summary is ready."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )

        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try? await center.add(request)
    }
}
