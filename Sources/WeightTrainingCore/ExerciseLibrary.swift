import Foundation

/// The starting exercise library, pre-tagged so volume-by-muscle works on day
/// one without anyone hand-tagging a single lift.
///
/// These are the movements actually trained, not a general catalogue. A picker
/// listing four hundred lifts is a worse tool than one listing eighteen you
/// recognise — anything missing can be added in-app.
///
/// Every id here is a fixed literal rather than a fresh `UUID()`. Seeded rows
/// have to keep their identity across launches, reinstalls, and eventually
/// across devices via CloudKit (#19); a generated id would make the same lift
/// look like a different exercise on every device and orphan its history.
public enum ExerciseLibrary {

    /// Every seeded lift, in the order a session tends to run.
    public static let all: [Exercise] = push + pull + legs

    // MARK: - Push

    public static let push: [Exercise] = [
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000001"),
            name: "Incline DB Press",
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000002"),
            name: "Flat Bench",
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .barbell,
            // One of the three lifts that moves in true 5 lb steps, so load can
            // be steered directly by feel instead of banked through reps.
            progressionRule: .rpeTargetedLoad(reps: 5, targetRPE: .eight),
            needsWarmupRamp: true
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000003"),
            name: "Chest Fly",
            muscles: [.primary(.chest)],
            equipment: .cable,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000004"),
            name: "Seated DB OHP",
            muscles: [.primary(.frontDelts), .secondary(.sideDelts), .secondary(.triceps)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000005"),
            name: "Lateral Raise",
            muscles: [.primary(.sideDelts)],
            equipment: .dumbbell,
            // A 10 lb jump on a 20 lb lateral is +50%, so the range has to be
            // wide enough to absorb it.
            progressionRule: .doubleProgression(range: RepRange(12, 20))
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000006"),
            name: "Tricep Pressdown",
            muscles: [.primary(.triceps)],
            equipment: .cable,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        ),
        Exercise(
            id: id("CB000001-0000-4000-8000-000000000007"),
            name: "Skull Crushers",
            muscles: [.primary(.triceps)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
    ]

    // MARK: - Pull

    public static let pull: [Exercise] = [
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000001"),
            name: "Chest-Supported T-Bar Row",
            muscles: [
                .primary(.lats),
                .secondary(.rearDelts),
                .secondary(.traps),
                .secondary(.biceps),
            ],
            equipment: .plateLoaded,
            progressionRule: .doubleProgression(range: RepRange(8, 12)),
            needsWarmupRamp: true
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000002"),
            name: "Lat Pulldown",
            muscles: [.primary(.lats), .secondary(.biceps)],
            equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000003"),
            name: "Face Pull",
            muscles: [.primary(.rearDelts), .secondary(.traps)],
            equipment: .cable,
            progressionRule: .doubleProgression(range: RepRange(12, 20))
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000004"),
            name: "Reverse Fly",
            muscles: [.primary(.rearDelts)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(12, 20))
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000005"),
            name: "Shrugs",
            muscles: [.primary(.traps), .secondary(.forearms)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000006"),
            name: "Hammer Curls",
            muscles: [.primary(.biceps), .secondary(.forearms)],
            equipment: .dumbbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
        Exercise(
            id: id("CB000002-0000-4000-8000-000000000007"),
            name: "Preacher Curls",
            muscles: [.primary(.biceps)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
    ]

    // MARK: - Legs

    public static let legs: [Exercise] = [
        Exercise(
            id: id("CB000003-0000-4000-8000-000000000001"),
            name: "Hack Squat",
            muscles: [.primary(.quads), .secondary(.glutes)],
            equipment: .plateLoaded,
            progressionRule: .rpeTargetedLoad(reps: 8, targetRPE: .eight),
            needsWarmupRamp: true
        ),
        Exercise(
            id: id("CB000003-0000-4000-8000-000000000002"),
            name: "RDL",
            // Glutes are a primary mover on a hinge, not an afterthought. This
            // is the only lift in the split giving them direct credit, so
            // tagging them secondary would report a permanent glute deficit.
            muscles: [.primary(.hamstrings), .primary(.glutes), .secondary(.forearms)],
            equipment: .barbell,
            progressionRule: .rpeTargetedLoad(reps: 8, targetRPE: .eight),
            needsWarmupRamp: true
        ),
        Exercise(
            id: id("CB000003-0000-4000-8000-000000000003"),
            name: "Leg Curl",
            muscles: [.primary(.hamstrings)],
            equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        ),
        Exercise(
            id: id("CB000003-0000-4000-8000-000000000004"),
            name: "Leg Extension",
            muscles: [.primary(.quads)],
            equipment: .machineStack,
            progressionRule: .doubleProgression(range: RepRange(10, 15))
        ),
        Exercise(
            id: id("CB000003-0000-4000-8000-000000000005"),
            name: "Calf Raise",
            muscles: [.primary(.calves)],
            equipment: .machineStack,
            // Calves tolerate a coarse stack jump only across a wide range.
            progressionRule: .doubleProgression(range: RepRange(10, 20))
        ),
    ]

    /// The lifts belonging to one day of the cycle.
    ///
    /// Until day templates land (#16), the library grouping *is* the day. That
    /// keeps M1 walkable without pulling the slot-and-rotation engine forward,
    /// at the cost of custom exercises not appearing in a day until then.
    public static func exercises(for kind: DayKind) -> [Exercise] {
        switch kind {
        case .push: return push
        case .pull: return pull
        case .legs: return legs
        }
    }

    /// Parses a fixed library id.
    ///
    /// Force-style failure is correct here: these are compile-time literals, so
    /// a malformed one is a typo that should never survive the first launch,
    /// and `ExerciseLibraryTests` checks all of them.
    private static func id(_ string: String) -> UUID {
        guard let uuid = UUID(uuidString: string) else {
            preconditionFailure("malformed library id: \(string)")
        }
        return uuid
    }
}
