import XCTest
@testable import WeightTrainingCore

final class DayTemplateTests: XCTestCase {

    func testCycleOrderIsPushPullLegs() {
        XCTAssertEqual(DayKind.push.next, .pull)
        XCTAssertEqual(DayKind.pull.next, .legs)
        XCTAssertEqual(DayKind.legs.next, .push)
    }

    func testFullCycleReturnsToStart() {
        XCTAssertEqual(DayKind.push.next.next.next, .push)
    }

    func testFixedSlotAlwaysOffersItsFirstCandidate() {
        let bench = UUID(), incline = UUID()
        let slot = Slot(name: "Heavy press", candidateExerciseIDs: [bench, incline])

        for count in 0..<5 {
            XCTAssertEqual(slot.dueCandidate(completionCount: count), bench)
        }
    }

    /// Push day's fly / skull crusher pair — alternates so session length stays
    /// down without either movement losing weekly volume.
    func testRotatingSlotAlternatesAcrossSessions() {
        let fly = UUID(), skulls = UUID()
        let slot = Slot(name: "Rotating", candidateExerciseIDs: [fly, skulls], rotates: true)

        XCTAssertEqual(slot.dueCandidate(completionCount: 0), fly)
        XCTAssertEqual(slot.dueCandidate(completionCount: 1), skulls)
        XCTAssertEqual(slot.dueCandidate(completionCount: 2), fly)
        XCTAssertEqual(slot.dueCandidate(completionCount: 3), skulls)
    }

    func testEmptySlotHasNothingDue() {
        let slot = Slot(name: "Empty", candidateExerciseIDs: [])
        XCTAssertNil(slot.dueCandidate(completionCount: 0))
    }

    func testDayTemplateHoldsItsSlotsInOrder() {
        let a = Slot(name: "A", candidateExerciseIDs: [UUID()])
        let b = Slot(name: "B", candidateExerciseIDs: [UUID()])
        let day = DayTemplate(kind: .push, slots: [a, b])

        XCTAssertEqual(day.kind, .push)
        XCTAssertEqual(day.slots.map(\.name), ["A", "B"])
    }

    private func mockExercise(name: String) -> Exercise {
        Exercise(
            name: name,
            muscles: [.primary(.chest)],
            equipment: .barbell,
            progressionRule: .doubleProgression(range: RepRange(6, 10))
        )
    }

    // MARK: - DayKind past being a fixed enum (#136)

    /// `DayKind` moved from an enum to a `RawRepresentable` struct so a split
    /// could name a fifth, sixth, arbitrarily-named day. `push`/`pull`/`legs`
    /// staying `==`-comparable and switchable is what kept every existing
    /// caller — including two screens outside #136's file ownership —
    /// compiling and behaving unchanged.
    func testFixedKindsStillPatternMatchInASwitch() {
        func label(_ kind: DayKind) -> String {
            switch kind {
            case .push: return "push"
            case .pull: return "pull"
            case .legs: return "legs"
            default: return "other"
            }
        }
        XCTAssertEqual(label(.push), "push")
        XCTAssertEqual(label(.pull), "pull")
        XCTAssertEqual(label(DayKind(rawValue: "leg day")!), "other")
    }

    func testEmptyRawValueIsNotADay() {
        XCTAssertNil(DayKind(rawValue: ""))
    }

    /// `TrainingArchive` (#87) is a hand-editable backup file meant to survive
    /// for years, and an export taken before #136 has `"push"` as a bare JSON
    /// string wherever a `DayKind` sits — never `{"rawValue":"push"}`, which is
    /// the shape a plain struct's synthesized `Codable` would produce. Decoding
    /// has to keep accepting the old shape, and encoding has to keep producing
    /// it, or an old backup — and any value nested inside one — stops opening.
    func testDayKindDecodesFromTheBareStringAnEnumAlwaysWrote() throws {
        let data = Data("\"push\"".utf8)
        let decoded = try JSONDecoder().decode(DayKind.self, from: data)
        XCTAssertEqual(decoded, .push)
    }

    func testDayKindEncodesAsABareStringNotAKeyedObject() throws {
        let data = try JSONEncoder().encode(DayKind.push)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"push\"")
    }

    func testDayKindRefusesAnEmptyStringOnDecode() {
        let data = Data("\"\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DayKind.self, from: data))
    }

    /// A `DayTemplate` archived before #136 has no `"name"` key at all — the
    /// kind's own capitalized word is exactly what the app showed for it then,
    /// so that's what a missing name falls back to now.
    func testDayTemplateWithoutAStoredNameFallsBackToTheKindsWord() throws {
        let json = """
        {"id":"CB00000A-0000-4000-8000-000000000001","kind":"push","slots":[]}
        """
        let decoded = try JSONDecoder().decode(DayTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Push")
    }

    func testDayTemplateNameRoundTripsThroughEncodeAndDecode() throws {
        let day = DayTemplate(kind: DayKind(rawValue: "leg day")!, name: "Leg Day", slots: [])
        let data = try JSONEncoder().encode(day)
        let decoded = try JSONDecoder().decode(DayTemplate.self, from: data)
        XCTAssertEqual(decoded.name, "Leg Day")
        XCTAssertEqual(decoded.kind, day.kind)
    }

    // MARK: - Split shapes (#136)

    func testPushPullLegsSplitIsTheOriginalThreeDays() {
        let split = DayTemplateLibrary.split(.pushPullLegs)
        XCTAssertEqual(split.days.map(\.kind), [.push, .pull, .legs])
    }

    func testUpperLowerSplitHasTwoDays() {
        let split = DayTemplateLibrary.split(.upperLower)
        XCTAssertEqual(split.days.map(\.name), ["Upper", "Lower"])
    }

    func testFullBodySplitHasOneDay() {
        let split = DayTemplateLibrary.split(.fullBody)
        XCTAssertEqual(split.days.map(\.name), ["Full Body"])
    }

    /// A custom split starts with no days — Settings fills them in one at a
    /// time via `customDay(name:exercises:)` — rather than a placeholder day
    /// nobody asked for.
    func testCustomSplitStartsEmpty() {
        XCTAssertTrue(DayTemplateLibrary.split(.custom).days.isEmpty)
    }

    /// A custom day's identity is the exact name typed in, not a synthesized
    /// id — see `DayKind`'s doc comment: it's what lets the session title and
    /// the Live Activity, both outside #136's file ownership, already show
    /// the right thing with no changes on their end.
    func testCustomDayNameBecomesBothTheKindAndTheDisplayName() {
        let bench = mockExercise(name: "Bench Press")
        let day = DayTemplateLibrary.customDay(name: "Leg Day", exercises: [bench])

        XCTAssertEqual(day.kind.rawValue, "Leg Day")
        XCTAssertEqual(day.name, "Leg Day")
        XCTAssertEqual(day.slots.map(\.name), ["Bench Press"])
        XCTAssertEqual(day.slots.map(\.candidateExerciseIDs), [[bench.id]])
    }

    func testUniqueDayNameLeavesAFreshNameAlone() {
        XCTAssertEqual(DayTemplateLibrary.uniqueDayName("Legs", among: ["Push", "Pull"]), "Legs")
    }

    func testUniqueDayNameDisambiguatesACollision() {
        XCTAssertEqual(DayTemplateLibrary.uniqueDayName("Legs", among: ["Legs"]), "Legs 2")
        XCTAssertEqual(
            DayTemplateLibrary.uniqueDayName("Legs", among: ["Legs", "Legs 2"]), "Legs 3"
        )
    }

    /// The backstop in `template(for:)`: a kind the caller's own templates
    /// don't contain comes back as an honestly empty day rather than silently
    /// substituting push.
    func testTemplateForAnUnknownKindComesBackEmptyRatherThanAsPush() {
        let template = DayTemplateLibrary.template(for: DayKind(rawValue: "mystery")!)
        XCTAssertTrue(template.slots.isEmpty)
        XCTAssertEqual(template.name, "Mystery")
    }
}
