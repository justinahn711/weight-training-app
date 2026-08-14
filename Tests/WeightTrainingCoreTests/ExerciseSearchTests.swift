import XCTest
@testable import WeightTrainingCore

final class ExerciseSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    // MARK: - Staleness

    /// The question at the rack is "what haven't I done in a while".
    func testStalestComesFirst() {
        let fly = lift("Chest Fly")
        let skulls = lift("Skull Crushers")
        let ranked = ExerciseSearch.rankedByStaleness(
            [fly, skulls],
            lastPerformed: [
                fly.id: now.addingTimeInterval(-2 * 86_400),
                skulls.id: now.addingTimeInterval(-9 * 86_400),
            ]
        )
        XCTAssertEqual(ranked.map(\.name), ["Skull Crushers", "Chest Fly"])
    }

    /// A lift never performed is the stalest thing there is, and must not be
    /// buried under lifts that at least have a date.
    func testNeverPerformedSortsToTheTop() {
        let fly = lift("Chest Fly")
        let skulls = lift("Skull Crushers")
        let ranked = ExerciseSearch.rankedByStaleness(
            [fly, skulls],
            lastPerformed: [fly.id: now.addingTimeInterval(-30 * 86_400)]
        )
        XCTAssertEqual(ranked.first?.name, "Skull Crushers")
    }

    func testTiesBreakAlphabetically() {
        let fly = lift("Chest Fly")
        let skulls = lift("Skull Crushers")
        let ranked = ExerciseSearch.rankedByStaleness(
            [skulls, fly], lastPerformed: [fly.id: now, skulls.id: now]
        )
        XCTAssertEqual(ranked.map(\.name), ["Chest Fly", "Skull Crushers"])
    }

    func testNoHistoryAtAllIsAlphabetical() {
        let ranked = ExerciseSearch.rankedByStaleness(
            [lift("Skull Crushers"), lift("Chest Fly")], lastPerformed: [:]
        )
        XCTAssertEqual(ranked.map(\.name), ["Chest Fly", "Skull Crushers"])
    }

    // MARK: - Search

    /// The done-when for search: the thing you obviously meant is one tap away.
    func testTopResultIsTheObviousOne() {
        let cases: [(query: String, expected: String)] = [
            ("incline", "Incline DB Press"),
            ("Incline DB Press", "Incline DB Press"),
            ("hack", "Hack Squat"),
            ("rdl", "RDL"),
            ("calf", "Calf Raise"),
            ("preacher", "Preacher Curls"),
            ("lat pull", "Lat Pulldown"),
            ("skull", "Skull Crushers"),
        ]
        for entry in cases {
            XCTAssertEqual(
                ExerciseSearch.search(entry.query, in: ExerciseLibrary.all).first?.name,
                entry.expected,
                "query: \(entry.query)"
            )
        }
    }

    func testCaseIsIgnored() {
        XCTAssertEqual(
            ExerciseSearch.search("HACK SQUAT", in: ExerciseLibrary.all).first?.name,
            "Hack Squat"
        )
    }

    /// Partial and abbreviated typing has to work — this gets typed one-handed
    /// between sets.
    func testAbbreviationsAndScatteredTypingMatch() {
        XCTAssertEqual(
            ExerciseSearch.search("incdb", in: ExerciseLibrary.all).first?.name,
            "Incline DB Press"
        )
        XCTAssertTrue(
            ExerciseSearch.search("legext", in: ExerciseLibrary.all)
                .contains { $0.name == "Leg Extension" }
        )
    }

    /// A match at the start of a word beats letters strewn across a name.
    func testWordStartsOutrankScatteredMatches() {
        let results = ExerciseSearch.search("press", in: ExerciseLibrary.all)
        XCTAssertTrue(
            ["Incline DB Press", "Seated DB OHP", "Tricep Pressdown"].contains(results[0].name),
            "got \(results[0].name)"
        )
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(ExerciseSearch.search("zzzzq", in: ExerciseLibrary.all).isEmpty)
    }

    /// An empty field shows the whole library rather than an unhelpful blank.
    func testEmptyQueryReturnsEverythingAlphabetically() {
        let results = ExerciseSearch.search("   ", in: ExerciseLibrary.all)
        XCTAssertEqual(results.count, ExerciseLibrary.all.count)
        XCTAssertEqual(results.map(\.name), results.map(\.name).sorted())
    }

    func testExactNameOutranksEverything() {
        XCTAssertEqual(
            ExerciseSearch.search("RDL", in: ExerciseLibrary.all).first?.name,
            "RDL"
        )
    }

    /// Search only ever returns lifts that already exist. Creating one mid-set
    /// would produce an exercise with no history, no increment, and no muscle
    /// tags, polluting volume tracking permanently.
    func testSearchOnlyEverReturnsExistingLifts() {
        let known = Set(ExerciseLibrary.all.map(\.id))
        for query in ["press", "curl", "squat", "z", ""] {
            for result in ExerciseSearch.search(query, in: ExerciseLibrary.all) {
                XCTAssertTrue(known.contains(result.id))
            }
        }
    }
}

final class SessionSwapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    private func sessionExercise(_ name: String, slot: Slot?, target: Load?) -> SessionExercise {
        let exercise = lift(name)
        let state = ProgressState(exerciseID: exercise.id, targetLoad: target, targetReps: 10)
        return SessionExercise(
            exercise: exercise,
            slot: slot,
            prescription: Prescription(exercise: exercise, state: state)
        )
    }

    private var rotatingSlot: Slot {
        DayTemplateLibrary.push.slots.first(where: \.rotates)!
    }

    /// #18's done-when: the slot survives and the new lift brings its own
    /// target.
    func testSwapPreservesTheSlotAndLoadsTheNewTarget() throws {
        let slot = rotatingSlot
        var session = Session(kind: .push, exercises: [
            sessionExercise("Chest Fly", slot: slot, target: Load(50))
        ])

        session.replaceCurrent(with: sessionExercise("Skull Crushers", slot: slot,
                                                     target: Load(65)))

        let current = try XCTUnwrap(session.current)
        XCTAssertEqual(current.exercise.name, "Skull Crushers")
        XCTAssertEqual(current.slot?.id, slot.id, "the job stays")
        XCTAssertEqual(current.prescription.load, Load(65), "its own target, not the old one")
    }

    func testSwapKeepsThePositionInTheDay() {
        let slot = rotatingSlot
        var session = Session(kind: .push, exercises: [
            sessionExercise("Incline DB Press", slot: nil, target: Load(70)),
            sessionExercise("Chest Fly", slot: slot, target: Load(50)),
            sessionExercise("Lateral Raise", slot: nil, target: Load(20)),
        ])
        session.advance()
        session.replaceCurrent(with: sessionExercise("Skull Crushers", slot: slot,
                                                     target: Load(65)))

        XCTAssertEqual(session.exercises.count, 3)
        XCTAssertEqual(session.currentIndex, 1)
        XCTAssertEqual(session.exercises.map(\.exercise.name),
                       ["Incline DB Press", "Skull Crushers", "Lateral Raise"])
    }

    /// Sets already logged against the old lift happened, and belong to it.
    func testSwappingLeavesEarlierExercisesUntouched() {
        let slot = rotatingSlot
        var session = Session(kind: .push, exercises: [
            sessionExercise("Incline DB Press", slot: nil, target: Load(70)),
            sessionExercise("Chest Fly", slot: slot, target: Load(50)),
        ])
        let incline = lift("Incline DB Press")
        session.log(SetRecord(exerciseID: incline.id, load: Load(70), reps: 10,
                              rpe: RPE(8), performedAt: now))
        session.advance()
        session.replaceCurrent(with: sessionExercise("Skull Crushers", slot: slot,
                                                     target: Load(65)))

        XCTAssertEqual(session.exercises[0].loggedSets.count, 1)
        XCTAssertEqual(session.allLoggedSets.count, 1)
    }

    /// Swapping to what's already there would silently discard sets logged
    /// against it this session.
    func testSwappingToTheSameLiftIsANoOp() {
        let slot = rotatingSlot
        var session = Session(kind: .push, exercises: [
            sessionExercise("Chest Fly", slot: slot, target: Load(50))
        ])
        let fly = lift("Chest Fly")
        session.log(SetRecord(exerciseID: fly.id, load: Load(50), reps: 12,
                              rpe: RPE(8), performedAt: now))

        session.replaceCurrent(with: sessionExercise("Chest Fly", slot: slot, target: Load(50)))
        XCTAssertEqual(session.current?.loggedSets.count, 1, "sets must survive")
    }

    func testReplacingOutOfRangeIsIgnored() {
        var session = Session(kind: .push, exercises: [
            sessionExercise("Chest Fly", slot: rotatingSlot, target: Load(50))
        ])
        session.replace(at: 7, with: sessionExercise("Skull Crushers", slot: nil, target: nil))
        XCTAssertEqual(session.exercises.count, 1)
        XCTAssertEqual(session.current?.exercise.name, "Chest Fly")
    }

    /// A lift never performed swaps in cold rather than inheriting a target
    /// from whatever it replaced.
    func testSwappingToAColdLiftKeepsItCold() throws {
        var session = Session(kind: .push, exercises: [
            sessionExercise("Chest Fly", slot: rotatingSlot, target: Load(50))
        ])
        session.replaceCurrent(with: sessionExercise("Skull Crushers",
                                                     slot: rotatingSlot, target: nil))
        let current = try XCTUnwrap(session.current)
        XCTAssertTrue(current.prescription.isColdStart)
        XCTAssertEqual(current.prescription.displayLine, "First time — just log it")
    }
}
