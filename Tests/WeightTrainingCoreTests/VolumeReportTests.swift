import XCTest
@testable import WeightTrainingCore

final class VolumeReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func lift(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    /// `count` hard sets of a lift, `daysAgo` back.
    private func sets(
        _ name: String,
        count: Int,
        daysAgo: Double,
        rpe: RPE? = RPE(8),
        warmup: Bool = false
    ) -> [SetRecord] {
        let exercise = lift(name)
        return (0..<count).map { index in
            SetRecord(
                exerciseID: exercise.id, load: Load(100), reps: 10, rpe: rpe,
                isWarmup: warmup,
                performedAt: now.addingTimeInterval(-daysAgo * 86_400 + Double(index) * 300)
            )
        }
    }

    private func report(_ history: [SetRecord]) -> VolumeReport {
        VolumeReport.trailing(history: history, exercises: ExerciseLibrary.all, now: now)
    }

    private func volume(_ report: VolumeReport, _ muscle: Muscle) -> MuscleVolume {
        report.muscles.first { $0.muscle == muscle }!
    }

    // MARK: - The done-when

    /// #25's done-when: removing face pulls from a history flags rear delts as
    /// starved. This is the guard against flexible exercise selection quietly
    /// creating holes — it caught zero rear delt work during design.
    func testRemovingFacePullsStarvesRearDelts() {
        // A full-ish week with rear delt work.
        let withFacePulls =
            sets("Face Pull", count: 4, daysAgo: 5)
            + sets("Face Pull", count: 4, daysAgo: 2)
            + sets("Chest-Supported T-Bar Row", count: 4, daysAgo: 5)
            + sets("Chest-Supported T-Bar Row", count: 4, daysAgo: 2)

        XCTAssertEqual(volume(report(withFacePulls), .rearDelts).standing, .onTarget)

        // The same week with the face pulls skipped — the rows alone leave rear
        // delts on secondary credit only.
        let withoutFacePulls =
            sets("Chest-Supported T-Bar Row", count: 4, daysAgo: 5)
            + sets("Chest-Supported T-Bar Row", count: 4, daysAgo: 2)

        let starved = report(withoutFacePulls)
        XCTAssertEqual(volume(starved, .rearDelts).standing, .starved)
        XCTAssertTrue(starved.starved.contains { $0.muscle == .rearDelts })
    }

    // MARK: - Counting

    func testPrimaryCountsFullAndSecondaryCountsHalf() {
        // Incline DB Press: chest primary, front delts and triceps secondary.
        let report = report(sets("Incline DB Press", count: 4, daysAgo: 1))
        XCTAssertEqual(volume(report, .chest).sets, 4)
        XCTAssertEqual(volume(report, .frontDelts).sets, 2)
        XCTAssertEqual(volume(report, .triceps).sets, 2)
    }

    func testWarmupsAreNotVolume() {
        let report = report(sets("Incline DB Press", count: 5, daysAgo: 1, warmup: true))
        XCTAssertEqual(volume(report, .chest).sets, 0)
    }

    /// Junk volume must not paper over a hole, which is the entire point of
    /// counting hard sets rather than sets.
    func testSetsBelowRPESevenAreNotHardSets() {
        let easy = report(sets("Incline DB Press", count: 10, daysAgo: 1, rpe: RPE(6.5)))
        XCTAssertEqual(volume(easy, .chest).sets, 0)

        let hard = report(sets("Incline DB Press", count: 10, daysAgo: 1, rpe: RPE(7)))
        XCTAssertEqual(volume(hard, .chest).sets, 10)
    }

    /// A set logged without an RPE counts, since the alternative is silently
    /// discarding real work.
    func testUnscoredSetsStillCount() {
        let report = report(sets("Incline DB Press", count: 3, daysAgo: 1, rpe: nil))
        XCTAssertEqual(volume(report, .chest).sets, 3)
    }

    // MARK: - The window

    func testTheWindowRollsRatherThanSnappingToAWeek() {
        let inside = report(sets("Incline DB Press", count: 4, daysAgo: 6.5))
        XCTAssertEqual(volume(inside, .chest).sets, 4)

        let outside = report(sets("Incline DB Press", count: 4, daysAgo: 7.5))
        XCTAssertEqual(volume(outside, .chest).sets, 0, "older than the window")
    }

    func testFutureSetsAreExcluded() {
        let report = report(sets("Incline DB Press", count: 3, daysAgo: -2))
        XCTAssertEqual(volume(report, .chest).sets, 0)
    }

    func testTheWindowLengthIsAdjustable() {
        let history = sets("Incline DB Press", count: 4, daysAgo: 10)
        let week = VolumeReport.trailing(history: history, exercises: ExerciseLibrary.all,
                                         now: now)
        let fortnight = VolumeReport.trailing(days: 14, history: history,
                                              exercises: ExerciseLibrary.all, now: now)
        XCTAssertEqual(week.muscles.first { $0.muscle == .chest }?.sets, 0)
        XCTAssertEqual(fortnight.muscles.first { $0.muscle == .chest }?.sets, 4)
    }

    // MARK: - Standing

    func testStandingAgainstTheBand() {
        // Chest targets 10-20.
        XCTAssertEqual(volume(report(sets("Chest Fly", count: 4, daysAgo: 1)), .chest).standing,
                       .starved)
        XCTAssertEqual(volume(report(sets("Chest Fly", count: 12, daysAgo: 1)), .chest).standing,
                       .onTarget)
        XCTAssertEqual(volume(report(sets("Chest Fly", count: 25, daysAgo: 1)), .chest).standing,
                       .overreaching)
    }

    func testBandBoundariesAreInclusive() {
        XCTAssertEqual(volume(report(sets("Chest Fly", count: 10, daysAgo: 1)), .chest).standing,
                       .onTarget, "the bottom of the band is on target")
        XCTAssertEqual(volume(report(sets("Chest Fly", count: 20, daysAgo: 1)), .chest).standing,
                       .onTarget, "so is the top")
    }

    /// A muscle missing from the report is exactly the hole being looked for,
    /// so it must not be missing from the list.
    func testEveryTrackedMuscleAppearsEvenOnZero() {
        let report = report([])
        XCTAssertEqual(report.muscles.count, Muscle.allCases.count)
        XCTAssertTrue(report.muscles.allSatisfy { $0.sets == 0 })
        XCTAssertEqual(report.starved.count, Muscle.allCases.count,
                       "an empty week starves everything")
    }

    // MARK: - Display

    func testDisplayLine() {
        let report = report(sets("Incline DB Press", count: 5, daysAgo: 1))
        XCTAssertEqual(volume(report, .chest).displayLine, "5 of 10–20")
        XCTAssertEqual(volume(report, .triceps).displayLine, "2.5 of 8–16",
                       "half sets are shown, not rounded away")
    }

    func testProgressClampsAtFull() {
        let report = report(sets("Chest Fly", count: 40, daysAgo: 1))
        XCTAssertEqual(volume(report, .chest).progress, 1)
    }

    /// A set whose exercise is no longer in the library can't be attributed, and
    /// must not crash the report.
    func testSetsForUnknownExercisesAreSkipped() {
        let orphan = [SetRecord(exerciseID: UUID(), load: Load(100), reps: 10,
                                rpe: RPE(8), performedAt: now)]
        XCTAssertEqual(report(orphan).muscles.count, Muscle.allCases.count)
    }

    // MARK: - Against a real week

    /// A single legs day inside the window genuinely leaves the legs short of
    /// a 10-20 set band, and the report says so. That's the guard doing its
    /// job, not a false alarm: at 3-4 sessions a week a full cycle takes 5-7
    /// days, so any given seven days may only contain one of each.
    func testASingleLegsDayInTheWindowFlagsTheLegs() {
        var history: [SetRecord] = []
        for name in ["Hack Squat", "RDL", "Leg Curl", "Leg Extension", "Calf Raise"] {
            history += sets(name, count: 3, daysAgo: 2)
        }

        let starvedMuscles = Set(report(history).starved.map(\.muscle))
        XCTAssertTrue(starvedMuscles.contains(.quads), "6 sets against a 10-20 band")
        XCTAssertTrue(starvedMuscles.contains(.hamstrings))
    }

    /// Two full cycles inside the window is what actually clears the bands, and
    /// the muscles the split trains directly land on target together.
    func testTwoFullCyclesPutTheMainMoversOnTarget() {
        var history: [SetRecord] = []
        let push = ["Incline DB Press", "Flat Bench", "Seated DB OHP",
                    "Lateral Raise", "Tricep Pressdown", "Chest Fly"]
        let pull = ["Chest-Supported T-Bar Row", "Lat Pulldown", "Face Pull",
                    "Shrugs", "Hammer Curls", "Preacher Curls"]
        let legs = ["Hack Squat", "RDL", "Leg Curl", "Leg Extension", "Calf Raise"]

        for (day, names) in [(6.0, push), (5.0, pull), (4.0, legs),
                             (2.0, push), (1.0, pull), (0.5, legs)] {
            for name in names {
                history += sets(name, count: 3, daysAgo: day)
            }
        }

        let built = report(history)
        for muscle in [Muscle.chest, .quads, .lats, .hamstrings, .rearDelts, .sideDelts] {
            XCTAssertNotEqual(volume(built, muscle).standing, .starved,
                              "\(muscle.rawValue) should be covered")
        }

        // Abs are the one true hole: nothing in the split trains them at all,
        // directly or otherwise, so no amount of training closes it.
        let starvedMuscles = Set(built.starved.map(\.muscle))
        XCTAssertTrue(starvedMuscles.contains(.abs))

        // Forearms have no direct work either, but shrugs, hammer curls and
        // RDL grip accumulate enough secondary credit at this volume to clear
        // a 4-12 band — which is the honest answer, not a loophole.
        XCTAssertFalse(starvedMuscles.contains(.forearms))
    }
}
