import Foundation

/// The shape of each training day.
///
/// Days are shapes rather than fixed lists: a slot names a job to be done and
/// offers candidates, and which lift fills it is decided at the gym. That's what
/// keeps a busy rack from costing a session.
///
/// Template and slot ids are fixed literals for the same reason exercise ids
/// are (#2) — a slot has to keep its identity across launches and devices, or
/// the rotation state attached to it is meaningless.
public enum DayTemplateLibrary {

    public static let all: [DayTemplate] = [push, pull, legs]

    public static func template(for kind: DayKind) -> DayTemplate {
        switch kind {
        case .push: return push
        case .pull: return pull
        case .legs: return legs
        }
    }

    // MARK: - Push

    /// Five fixed slots plus one rotating pair.
    ///
    /// Chest fly and skull crushers alternate rather than both being trained
    /// every push day: it holds session length down without giving up weekly
    /// volume on either.
    public static let push = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000001"),
        kind: .push,
        slots: [
            Slot(id: id("CB00000B-0000-4000-8000-000000000001"),
                 name: "Incline press",
                 candidateExerciseIDs: [library("Incline DB Press")]),
            Slot(id: id("CB00000B-0000-4000-8000-000000000002"),
                 name: "Flat press",
                 candidateExerciseIDs: [library("Flat Bench")]),
            Slot(id: id("CB00000B-0000-4000-8000-000000000003"),
                 name: "Overhead press",
                 candidateExerciseIDs: [library("Seated DB OHP")]),
            Slot(id: id("CB00000B-0000-4000-8000-000000000004"),
                 name: "Side delts",
                 candidateExerciseIDs: [library("Lateral Raise")]),
            Slot(id: id("CB00000B-0000-4000-8000-000000000005"),
                 name: "Triceps",
                 candidateExerciseIDs: [library("Tricep Pressdown")]),
            Slot(id: id("CB00000B-0000-4000-8000-000000000006"),
                 name: "Chest fly / skull crushers",
                 candidateExerciseIDs: [
                     library("Chest Fly"),
                     library("Skull Crushers"),
                 ],
                 rotates: true),
        ]
    )

    // MARK: - Pull

    /// Six slots. Face pull and reverse fly share one — they're different
    /// movements loading the same rear delts, which is what makes them
    /// alternatives rather than two separate jobs. This is where the extra lift
    /// from splitting the library's "face pull/reverse fly" entry (#2) lands.
    public static let pull = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000002"),
        kind: .pull,
        slots: [
            Slot(id: id("CB00000C-0000-4000-8000-000000000001"),
                 name: "Row",
                 candidateExerciseIDs: [library("Chest-Supported T-Bar Row")]),
            Slot(id: id("CB00000C-0000-4000-8000-000000000002"),
                 name: "Vertical pull",
                 candidateExerciseIDs: [library("Lat Pulldown")]),
            Slot(id: id("CB00000C-0000-4000-8000-000000000003"),
                 name: "Rear delts",
                 candidateExerciseIDs: [
                     library("Face Pull"),
                     library("Reverse Fly"),
                 ]),
            Slot(id: id("CB00000C-0000-4000-8000-000000000004"),
                 name: "Traps",
                 candidateExerciseIDs: [library("Shrugs")]),
            Slot(id: id("CB00000C-0000-4000-8000-000000000005"),
                 name: "Biceps",
                 candidateExerciseIDs: [library("Hammer Curls")]),
            Slot(id: id("CB00000C-0000-4000-8000-000000000006"),
                 name: "Biceps, stretched",
                 candidateExerciseIDs: [library("Preacher Curls")]),
        ]
    )

    // MARK: - Legs

    public static let legs = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000003"),
        kind: .legs,
        slots: [
            Slot(id: id("CB00000D-0000-4000-8000-000000000001"),
                 name: "Squat pattern",
                 candidateExerciseIDs: [library("Hack Squat")]),
            Slot(id: id("CB00000D-0000-4000-8000-000000000002"),
                 name: "Hinge",
                 candidateExerciseIDs: [library("RDL")]),
            Slot(id: id("CB00000D-0000-4000-8000-000000000003"),
                 name: "Hamstrings",
                 candidateExerciseIDs: [library("Leg Curl")]),
            Slot(id: id("CB00000D-0000-4000-8000-000000000004"),
                 name: "Quads",
                 candidateExerciseIDs: [library("Leg Extension")]),
            Slot(id: id("CB00000D-0000-4000-8000-000000000005"),
                 name: "Calves",
                 candidateExerciseIDs: [library("Calf Raise")]),
        ]
    )

    /// Looks a seeded lift up by name.
    ///
    /// Names rather than raw ids so the templates stay readable; the lookup is
    /// checked by a test that every slot resolves.
    private static func library(_ name: String) -> UUID {
        guard let exercise = ExerciseLibrary.all.first(where: { $0.name == name }) else {
            preconditionFailure("no seeded exercise named \(name)")
        }
        return exercise.id
    }

    private static func id(_ string: String) -> UUID {
        guard let uuid = UUID(uuidString: string) else {
            preconditionFailure("malformed template id: \(string)")
        }
        return uuid
    }
}
