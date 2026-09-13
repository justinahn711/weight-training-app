import XCTest
@testable import WeightTrainingCore

final class RestTimerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func timer(_ duration: TimeInterval = 180) -> RestTimer {
        RestTimer(startedAt: start, duration: duration, setID: UUID())
    }

    func testCountsDownFromTheDuration() {
        let rest = timer()
        XCTAssertEqual(rest.remaining(at: start), 180)
        XCTAssertEqual(rest.remaining(at: start.addingTimeInterval(60)), 120)
        XCTAssertEqual(rest.displayTime(at: start.addingTimeInterval(60)), "2:00")
    }

    /// The reason rest is stored as a start date rather than a ticking count:
    /// nothing has to be running for the reading to stay correct. This is the
    /// backgrounding requirement in #6, and it's the same code path as being
    /// force-quit and relaunched.
    func testReadingIsCorrectAfterAnyGap() {
        let rest = timer()
        // Simulates the app being suspended for two minutes.
        XCTAssertEqual(rest.remaining(at: start.addingTimeInterval(120)), 60)
        XCTAssertTrue(rest.isComplete(at: start.addingTimeInterval(300)))
    }

    func testRemainingFloorsAtZero() {
        XCTAssertEqual(timer().remaining(at: start.addingTimeInterval(1_000)), 0)
    }

    /// Overrun keeps counting up rather than freezing at zero — rest running
    /// long is the first sign a session is dragging, which is information.
    func testOverrunCountsUp() {
        let rest = timer()
        XCTAssertEqual(rest.overrun(at: start.addingTimeInterval(225)), 45)
        XCTAssertEqual(rest.displayTime(at: start.addingTimeInterval(225)), "+0:45")
    }

    func testCompletesExactlyOnTheBoundary() {
        let rest = timer()
        XCTAssertFalse(rest.isComplete(at: start.addingTimeInterval(179.9)))
        XCTAssertTrue(rest.isComplete(at: start.addingTimeInterval(180)))
        XCTAssertEqual(rest.displayTime(at: start.addingTimeInterval(180)), "+0:00")
    }

    func testFormatsMinutesAndSeconds() {
        let rest = timer(195)
        XCTAssertEqual(rest.displayTime(at: start), "3:15")
        XCTAssertEqual(rest.displayTime(at: start.addingTimeInterval(120)), "1:15")
        XCTAssertEqual(rest.displayTime(at: start.addingTimeInterval(190)), "0:05")
    }

    func testProgressRunsZeroToOneAndClamps() {
        let rest = timer()
        XCTAssertEqual(rest.progress(at: start), 0)
        XCTAssertEqual(rest.progress(at: start.addingTimeInterval(90)), 0.5)
        XCTAssertEqual(rest.progress(at: start.addingTimeInterval(1_000)), 1)
    }

    func testZeroDurationIsImmediatelyComplete() {
        let rest = timer(0)
        XCTAssertTrue(rest.isComplete(at: start))
        XCTAssertEqual(rest.progress(at: start), 1)
    }

    // MARK: - Optional setID (#173)

    /// A rest started by hand — no set logged, nothing to undo it against —
    /// has no `SetRecord` to point at. Before #173 the voice path papered
    /// over this by fabricating a `UUID()` that named a set which never
    /// existed; `setID` is optional now so a caller with nothing to point at
    /// can say so plainly, and every reading still works exactly the same as
    /// a set-anchored rest, since none of the clock math ever looked at it.
    func testUnanchoredRestBehavesIdenticallyToAnAnchoredOne() {
        let anchored = RestTimer(startedAt: start, duration: 180, setID: UUID())
        let unanchored = RestTimer(startedAt: start, duration: 180, setID: nil)
        XCTAssertNil(unanchored.setID)
        for offset in [TimeInterval(0), 60, 179.9, 180, 300] {
            let at = start.addingTimeInterval(offset)
            XCTAssertEqual(anchored.remaining(at: at), unanchored.remaining(at: at))
            XCTAssertEqual(anchored.isComplete(at: at), unanchored.isComplete(at: at))
            XCTAssertEqual(anchored.displayTime(at: at), unanchored.displayTime(at: at))
            XCTAssertEqual(anchored.progress(at: at), unanchored.progress(at: at))
        }
    }

    /// Two rests with the same start and duration but different `setID`s —
    /// including one that's `nil` — are different values. This is what lets
    /// a view keyed on the whole timer (rather than on `setID` alone) tell two
    /// separately started rests apart even when neither has a set to name.
    func testSetIDParticipatesInEquality() {
        let withSet = RestTimer(startedAt: start, duration: 180, setID: UUID())
        let withoutSet = RestTimer(startedAt: start, duration: 180, setID: nil)
        let alsoWithoutSet = RestTimer(startedAt: start, duration: 180, setID: nil)
        XCTAssertNotEqual(withSet, withoutSet)
        XCTAssertEqual(withoutSet, alsoWithoutSet)
    }
}

final class RestTargetTests: XCTestCase {

    private func exercise(muscles: [MuscleInvolvement], equipment: Equipment) -> Exercise {
        Exercise(
            name: "Test",
            muscles: muscles,
            equipment: equipment,
            progressionRule: .doubleProgression(range: RepRange(8, 12))
        )
    }

    func testCompoundsGetThreeMinutes() {
        let press = exercise(
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell
        )
        XCTAssertTrue(press.isCompound)
        XCTAssertEqual(press.restTarget, 180)
    }

    func testIsolationGetsNinetySeconds() {
        let raise = exercise(muscles: [.primary(.sideDelts)], equipment: .dumbbell)
        XCTAssertFalse(raise.isCompound)
        XCTAssertEqual(raise.restTarget, 90)
    }

    /// Plate-built lifts count as compound regardless of how they're tagged —
    /// a bar loaded with plates is systemically taxing even when it trains one
    /// thing.
    func testPlateBuiltCountsAsCompound() {
        let rdl = exercise(muscles: [.primary(.hamstrings)], equipment: .barbell)
        XCTAssertTrue(rdl.isCompound)
        XCTAssertEqual(rdl.restTarget, 180)
    }

    /// The whole point of #174: a gym report that the two-value heuristic
    /// has no escape hatch, so an override has to actually win.
    func testOverrideWinsOverTheHeuristic() {
        var press = exercise(
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell
        )
        XCTAssertEqual(press.restTarget, 180, "unset, this is still the compound default")
        press.restOverride = 240
        XCTAssertEqual(press.restTarget, 240)
    }

    /// #174 was explicit that the defaults must not move — this is the
    /// "done when" from the issue, checked directly against `nil`.
    func testNoOverrideIsExactlyTheOldDefault() {
        let press = exercise(
            muscles: [.primary(.chest), .secondary(.frontDelts), .secondary(.triceps)],
            equipment: .dumbbell
        )
        let raise = exercise(muscles: [.primary(.sideDelts)], equipment: .dumbbell)
        XCTAssertNil(press.restOverride)
        XCTAssertNil(raise.restOverride)
        XCTAssertEqual(press.restTarget, 180)
        XCTAssertEqual(raise.restTarget, 90)
    }

    /// Sanity-check the heuristic against the real library rather than only
    /// against invented fixtures.
    func testLibraryRestTargetsLandSensibly() {
        let byName = Dictionary(
            uniqueKeysWithValues: ExerciseLibrary.all.map { ($0.name, $0) }
        )
        XCTAssertEqual(byName["Flat Bench"]?.restTarget, 180)
        XCTAssertEqual(byName["Hack Squat"]?.restTarget, 180)
        XCTAssertEqual(byName["Incline DB Press"]?.restTarget, 180)
        XCTAssertEqual(byName["Chest-Supported T-Bar Row"]?.restTarget, 180)
        XCTAssertEqual(byName["Lateral Raise"]?.restTarget, 90)
        XCTAssertEqual(byName["Leg Extension"]?.restTarget, 90)
        XCTAssertEqual(byName["Tricep Pressdown"]?.restTarget, 90)
        XCTAssertEqual(byName["Hammer Curls"]?.restTarget, 90)
    }
}
