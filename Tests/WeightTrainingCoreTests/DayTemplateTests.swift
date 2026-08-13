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
}
