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

    /// Every built-in shape, independent of which split is currently active.
    ///
    /// Used only for classifying history (#136): a lifter who trained under
    /// push/pull/legs for a year and then switched to upper/lower must not
    /// have that year's sessions stop matching anything just because the
    /// active split no longer includes a push day. `all` deliberately stays
    /// PPL-only above — it's the historical default `CycleEngine` and its
    /// tests are pinned to — this is the superset used only for labelling.
    public static let allBuiltIn: [DayTemplate] = [push, pull, legs, upper, lower, fullBody]

    public static func template(for kind: DayKind) -> DayTemplate {
        if kind == .push { return push }
        if kind == .pull { return pull }
        if kind == .legs { return legs }
        // A defensive backstop, not a real path: every ordinary caller asks
        // for a kind that's already in the templates it's working from. An
        // honestly empty day is the right answer for the rest, rather than
        // silently handing back push (#136).
        return DayTemplate(kind: kind, name: kind.rawValue.capitalized, slots: [])
    }

    /// The starting templates for one of the four built-in split shapes.
    ///
    /// `.custom` has no built-in days to hand back — its shape is whatever
    /// the person names — so it starts empty and Settings fills it in via
    /// `customDay(name:exercises:)`.
    public static func split(_ kind: TrainingSplitKind, startedAt: Date = Date()) -> TrainingSplit {
        switch kind {
        case .pushPullLegs: return TrainingSplit(kind: kind, days: all, startedAt: startedAt)
        case .upperLower: return TrainingSplit(kind: kind, days: [upper, lower], startedAt: startedAt)
        case .fullBody: return TrainingSplit(kind: kind, days: [fullBody], startedAt: startedAt)
        case .custom: return TrainingSplit(kind: kind, days: [], startedAt: startedAt)
        }
    }

    /// Builds one day of a custom split.
    ///
    /// `kind`'s raw value is the exact name typed in, not a synthesized id —
    /// see `DayKind`'s doc comment for why: it's what lets the session title
    /// and Live Activity, both outside #136's file ownership, already show
    /// the right thing with no changes on their end. One slot per exercise,
    /// none of them rotating: a custom day is a flat list the person picked
    /// by hand, not a shape with alternatives to choose between.
    public static func customDay(name: String, exercises: [Exercise]) -> DayTemplate {
        DayTemplate(
            kind: DayKind(rawValue: name) ?? DayKind(rawValue: "Day")!,
            name: name,
            slots: exercises.map { Slot(name: $0.name, candidateExerciseIDs: [$0.id]) }
        )
    }

    /// Disambiguates a proposed day name against the ones already in a
    /// custom split.
    ///
    /// Two days sharing a name would collide onto the same `DayKind` —
    /// `customDay` uses the name as the identity — silently merging their
    /// rotation and "last performed" tracking. Settings calls this before
    /// adding a day rather than allowing the collision and explaining it
    /// later.
    public static func uniqueDayName(_ proposed: String, among existing: [String]) -> String {
        guard existing.contains(proposed) else { return proposed }
        var suffix = 2
        while existing.contains("\(proposed) \(suffix)") { suffix += 1 }
        return "\(proposed) \(suffix)"
    }

    // MARK: - Upper / Lower / Full body

    /// A conventional two-day split: everything above the waist, then
    /// everything below it. One slot per lift, no rotating pairs — those exist
    /// on push day specifically to hold *that* day's length down, and there's
    /// no equivalent pressure here.
    public static let upper = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000004"),
        kind: DayKind(rawValue: "upper")!,
        slots: [
            Slot(id: id("CB00000E-0000-4000-8000-000000000001"),
                 name: "Incline press",
                 candidateExerciseIDs: [library("Incline DB Press")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000002"),
                 name: "Row",
                 candidateExerciseIDs: [library("Chest-Supported T-Bar Row")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000003"),
                 name: "Overhead press",
                 candidateExerciseIDs: [library("Seated DB OHP")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000004"),
                 name: "Vertical pull",
                 candidateExerciseIDs: [library("Lat Pulldown")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000005"),
                 name: "Side delts",
                 candidateExerciseIDs: [library("Lateral Raise")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000006"),
                 name: "Biceps",
                 candidateExerciseIDs: [library("Hammer Curls")]),
            Slot(id: id("CB00000E-0000-4000-8000-000000000007"),
                 name: "Triceps",
                 candidateExerciseIDs: [library("Tricep Pressdown")]),
        ]
    )

    public static let lower = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000005"),
        kind: DayKind(rawValue: "lower")!,
        slots: [
            Slot(id: id("CB00000F-0000-4000-8000-000000000001"),
                 name: "Squat pattern",
                 candidateExerciseIDs: [library("Hack Squat")]),
            Slot(id: id("CB00000F-0000-4000-8000-000000000002"),
                 name: "Hinge",
                 candidateExerciseIDs: [library("RDL")]),
            Slot(id: id("CB00000F-0000-4000-8000-000000000003"),
                 name: "Hamstrings",
                 candidateExerciseIDs: [library("Leg Curl")]),
            Slot(id: id("CB00000F-0000-4000-8000-000000000004"),
                 name: "Quads",
                 candidateExerciseIDs: [library("Leg Extension")]),
            Slot(id: id("CB00000F-0000-4000-8000-000000000005"),
                 name: "Calves",
                 candidateExerciseIDs: [library("Calf Raise")]),
        ]
    )

    /// A single repeating day. `CycleEngine.position` steps through a split's
    /// `days` by index modulo count, so a one-day split simply proposes the
    /// same day again every time — no special case needed for it here.
    ///
    /// The raw value is `"full body"`, with the space kept deliberately: it's
    /// what makes `kind.rawValue.capitalized` — which is what the session
    /// title and Live Activity actually render, outside this issue's reach —
    /// come out as "Full Body" rather than a hyphenated compromise.
    public static let fullBody = DayTemplate(
        id: id("CB00000A-0000-4000-8000-000000000006"),
        kind: DayKind(rawValue: "full body")!,
        name: "Full Body",
        slots: [
            Slot(id: id("CB000010-0000-4000-8000-000000000001"),
                 name: "Squat pattern",
                 candidateExerciseIDs: [library("Hack Squat")]),
            Slot(id: id("CB000010-0000-4000-8000-000000000002"),
                 name: "Press",
                 candidateExerciseIDs: [library("Incline DB Press")]),
            Slot(id: id("CB000010-0000-4000-8000-000000000003"),
                 name: "Row",
                 candidateExerciseIDs: [library("Chest-Supported T-Bar Row")]),
            Slot(id: id("CB000010-0000-4000-8000-000000000004"),
                 name: "Hinge",
                 candidateExerciseIDs: [library("RDL")]),
            Slot(id: id("CB000010-0000-4000-8000-000000000005"),
                 name: "Overhead press",
                 candidateExerciseIDs: [library("Seated DB OHP")]),
            Slot(id: id("CB000010-0000-4000-8000-000000000006"),
                 name: "Vertical pull",
                 candidateExerciseIDs: [library("Lat Pulldown")]),
        ]
    )

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
