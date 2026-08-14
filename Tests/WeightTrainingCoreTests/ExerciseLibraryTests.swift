import XCTest
@testable import WeightTrainingCore

/// Issue #2's done-when is "every lift has a muscle tag", so the tags and the
/// ids they hang off get checked as data, not as code paths.
final class ExerciseLibraryTests: XCTestCase {

    func testLibraryCoversTheThreeDays() {
        XCTAssertEqual(ExerciseLibrary.push.count, 7)
        XCTAssertEqual(ExerciseLibrary.pull.count, 7)
        XCTAssertEqual(ExerciseLibrary.legs.count, 5)
        XCTAssertEqual(ExerciseLibrary.all.count, 19)
    }

    /// The done-when, checked directly.
    func testEveryLiftHasAtLeastOnePrimaryMuscle() {
        for exercise in ExerciseLibrary.all {
            XCTAssertFalse(
                exercise.muscles.isEmpty,
                "\(exercise.name) has no muscle tags"
            )
            XCTAssertFalse(
                exercise.primaryMuscles.isEmpty,
                "\(exercise.name) has no primary mover, so it would contribute "
                + "only half sets to every muscle it touches"
            )
        }
    }

    /// Ids are literals, so a typo can only be caught here. A duplicate would
    /// be worse than a crash: two lifts would silently share one row and one
    /// progression state.
    func testIdsAreUniqueAndStable() {
        let ids = ExerciseLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate library id")

        // Pinned so a careless edit to the literals is loud. If this fails and
        // the change was deliberate, existing installs will orphan the history
        // attached to the old id.
        XCTAssertEqual(
            ExerciseLibrary.all.first?.id,
            UUID(uuidString: "CB000001-0000-4000-8000-000000000001")
        )
    }

    func testNamesAreUnique() {
        let names = ExerciseLibrary.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate exercise name")
    }

    // MARK: - Increments

    /// The increments the equipment actually offers: 5 lb on a barbell, the
    /// next dumbbell up (5 lb in each hand), and a 10 lb stack placeholder
    /// until each machine is measured (#20).
    ///
    /// Issue #2 said "dumbbell 10 lb total", which assumed a dumbbell load
    /// meant the pair. It means one hand — you tap 70 for the 70s — so the
    /// step is 5.
    func testIncrementsMatchTheEquipment() {
        for exercise in ExerciseLibrary.all {
            XCTAssertEqual(
                exercise.increment.pounds,
                exercise.equipment.defaultIncrement.pounds,
                "\(exercise.name) overrides its equipment increment"
            )
        }
        XCTAssertEqual(LoadIncrement.barbell.pounds, 5)
        XCTAssertEqual(LoadIncrement.dumbbell.pounds, 5)
        XCTAssertEqual(LoadIncrement.stackDefault.pounds, 10)
    }

    // MARK: - Progression

    /// Load progression is only viable where the equipment moves in true 5 lb
    /// steps. Everything else banks progress in reps first.
    func testOnlyFivePoundLiftsUseRPETargetedLoad() {
        let rpeTargeted = ExerciseLibrary.all.filter {
            if case .rpeTargetedLoad = $0.progressionRule { return true }
            return false
        }
        XCTAssertEqual(
            rpeTargeted.map(\.name).sorted(),
            ["Flat Bench", "Hack Squat", "RDL"]
        )
        for exercise in rpeTargeted {
            XCTAssertEqual(
                exercise.increment.pounds, 5,
                "\(exercise.name) steers by load but can't make a 5 lb jump"
            )
        }
    }

    /// A coarse increment needs a wide rep range to land in. A 10 lb jump on a
    /// 20 lb lateral raise is +50%, which an 8-12 range can't absorb.
    func testCoarseIncrementsGetWideRepRanges() {
        for exercise in ExerciseLibrary.all {
            guard case .doubleProgression(let range, _) = exercise.progressionRule else { continue }
            if exercise.increment.pounds >= 10 {
                XCTAssertGreaterThanOrEqual(
                    range.span, 4,
                    "\(exercise.name) jumps \(exercise.increment.pounds) lb into a "
                    + "\(range.bottom)-\(range.top) range"
                )
            }
        }
    }

    // MARK: - Warmups

    /// Ramps are worth generating for heavy plate-built compounds and are pure
    /// noise on a cable lateral.
    func testWarmupRampsOnlyOnPlateBuiltLifts() {
        for exercise in ExerciseLibrary.all where exercise.needsWarmupRamp {
            XCTAssertTrue(
                exercise.equipment.isPlateBuilt,
                "\(exercise.name) asks for a ramp but isn't plate-built"
            )
        }
        XCTAssertEqual(
            ExerciseLibrary.all.filter(\.needsWarmupRamp).map(\.name).sorted(),
            ["Chest-Supported T-Bar Row", "Flat Bench", "Hack Squat", "RDL"]
        )
    }

    // MARK: - Volume coverage

    /// Volume-by-muscle is only honest if the split actually trains what it
    /// reports on. Every muscle with a weekly target needs a primary mover
    /// somewhere in the library.
    func testEveryTrackedMuscleHasAPrimaryMover() {
        let covered = Set(ExerciseLibrary.all.flatMap(\.primaryMuscles))
        let uncovered = Set(Muscle.allCases).subtracting(covered)
        XCTAssertEqual(
            uncovered, [.abs, .forearms],
            "abs and forearms are the known gaps — the split has no direct "
            + "work for either, so both accumulate secondary credit only. "
            + "Every other tracked muscle needs a primary mover or its volume "
            + "chart reads as a permanent deficit."
        )
    }

    func testPushPullLegsDoNotOverlap() {
        let push = Set(ExerciseLibrary.push.map(\.id))
        let pull = Set(ExerciseLibrary.pull.map(\.id))
        let legs = Set(ExerciseLibrary.legs.map(\.id))
        XCTAssertTrue(push.isDisjoint(with: pull))
        XCTAssertTrue(pull.isDisjoint(with: legs))
        XCTAssertTrue(legs.isDisjoint(with: push))
    }
}
