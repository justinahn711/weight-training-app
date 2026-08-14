import Foundation

/// One line of the digest, and what tapping it does.
public struct DigestBullet: Hashable, Sendable, Identifiable {

    public enum Action: Hashable, Sendable {
        /// Write a backed-off target for this lift. The only bullet that
        /// changes anything on its own.
        case deload(exerciseID: UUID, to: Load)
        /// Nothing to apply — a fact worth reading. Tapping opens the detail.
        case review(Detail)

        public enum Detail: Hashable, Sendable {
            case volume
            case trend(exerciseID: UUID)
        }
    }

    public let text: String
    public let action: Action

    /// Higher sorts first when there are more findings than room.
    let priority: Int

    public var id: String { text }

    public init(text: String, action: Action, priority: Int = 0) {
        self.text = text
        self.action = action
        self.priority = priority
    }

    /// Whether tapping this changes training rather than just navigating.
    public var isActionable: Bool {
        if case .deload = action { return true }
        return false
    }
}

/// The weekly nudge digest.
///
/// Assembled from the same signals the in-session chips use, so the app never
/// says one thing at the rack and another on the home screen.
///
/// Hard-capped at three bullets. A digest that lists everything is a report,
/// and a report gets skimmed once and then ignored; three findings get read.
public struct Digest: Hashable, Sendable {
    public let bullets: [DigestBullet]
    public let generatedAt: Date

    public init(bullets: [DigestBullet], generatedAt: Date) {
        self.bullets = bullets
        self.generatedAt = generatedAt
    }

    public var isEmpty: Bool { bullets.isEmpty }

    /// The cap. Three is the most a notification can say without becoming
    /// something to deal with later.
    public static let maximumBullets = 3

    /// Builds the digest from what's already known.
    ///
    /// - Note: readiness data (#26) belongs here — "bench RPE up a point, sleep
    ///   averaged 5h20" beats "bench stalled" — and slots in as another signal
    ///   once HealthKit lands.
    public static func build(
        trends: [E1RMTrend],
        volume: VolumeReport,
        states: [UUID: ProgressState],
        history: [SetRecord],
        exercises: [Exercise],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Digest {
        var candidates: [DigestBullet] = []

        // Deloads first. A lift grinding at the same weight is the finding most
        // likely to change what happens next session.
        let byExercise = Dictionary(grouping: history) { $0.exerciseID }
        for exercise in exercises {
            guard let state = states[exercise.id] else { continue }
            guard let suggestion = DeloadDetector.evaluate(
                exercise: exercise, state: state,
                history: byExercise[exercise.id] ?? [], calendar: calendar
            ) else { continue }

            let reason: String
            switch suggestion.trigger {
            case .rpeCreep(let from, let to, _):
                reason = "\(exercise.name) effort creeping at the same load, \(from) → \(to)"
            case .repeatedMisses(let sessions):
                reason = "\(exercise.name) missed \(sessions) sessions running"
            }
            candidates.append(DigestBullet(
                text: "\(reason) — deload to \(suggestion.to)?",
                action: .deload(exerciseID: exercise.id, to: suggestion.to),
                priority: 100
            ))
        }

        // Then the volume hole, which is the thing flexible exercise selection
        // is most likely to have quietly created.
        if let worst = volume.starved.min(by: { $0.sets < $1.sets }) {
            candidates.append(DigestBullet(
                text: "\(worst.muscle.digestName): \(worst.displayLine) hard sets this week",
                action: .review(.volume),
                priority: 60
            ))
        }

        // Then the good news, which is the reason to keep reading the digest at
        // all — a digest that only ever nags gets silenced.
        let climbing = trends
            .filter { $0.isMeaningful && ($0.change?.pounds ?? 0) > 0 }
            .max { ($0.change?.pounds ?? 0) < ($1.change?.pounds ?? 0) }
        if let climbing, let change = climbing.change {
            let pounds = change.pounds == change.pounds.rounded()
                ? String(format: "%.0f", change.pounds)
                : String(format: "%.1f", change.pounds)
            candidates.append(DigestBullet(
                text: "\(climbing.exercise.name) e1RM +\(pounds) lb over "
                    + "\(climbing.points.count) sessions. Keep going.",
                action: .review(.trend(exerciseID: climbing.exercise.id)),
                priority: 40
            ))
        }

        let bullets = candidates
            .sorted { $0.priority > $1.priority }
            .prefix(maximumBullets)

        return Digest(bullets: Array(bullets), generatedAt: now)
    }
}

extension Muscle {
    /// `Rear delts`, for prose rather than for an identifier.
    var digestName: String {
        let spaced = rawValue.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        ).lowercased()
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
