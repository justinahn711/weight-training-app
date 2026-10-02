import XCTest
@testable import WeightTrainingCore

/// A deload target and every warmup rung on a measured plate-built lift are
/// loads the gym's plates can build (#305), still rounded *down*.
///
/// The rack is 45/25/10 with a 5 lb increment: the increment grid says 130 and
/// 50 are fine, the plates say 42.5 a side and 2.5 a side are not.
final class PlateBuiltDeloadTests: XCTestCase {

    private let coarseRack = LoadingStyle(baseWeight: Load(45), sleeves: 2,
                                          availablePlates: [45, 25, 10])

    private var bench: Exercise {
        var lift = ExerciseLibrary.all.first { $0.name == "Flat Bench" }!
        lift.loading = coarseRack
        lift.increment = LoadIncrement(pounds: 5)
        return lift
    }

    /// Every load from the empty bar to 405 that this rack can build.
    private var buildableWorkingLoads: [Load] {
        stride(from: 45.0, through: 405.0, by: 5).map { Load($0) }.filter(coarseRack.canBuild)
    }

    private func deload(from load: Load) -> DeloadSuggestion? {
        let state = ProgressState(exerciseID: bench.id, targetLoad: load,
                                  stallCount: DeloadDetector.missesBeforeDeload)
        return DeloadDetector.evaluate(exercise: bench, state: state, history: [])
    }

    func testDeloadOffACoarseRackIsBuildableAndRoundsDown() throws {
        // 145 - 10% = 130.5. The increment grid says 130, which is 42.5 a
        // side; the heaviest load at or under 130.5 this rack builds is 125.
        let suggestion = try XCTUnwrap(deload(from: Load(145)))
        XCTAssertEqual(suggestion.to, Load(125))
    }

    func testEveryDeloadTargetIsBuildable() {
        for load in buildableWorkingLoads {
            guard let suggestion = deload(from: load) else { continue }
            XCTAssertTrue(coarseRack.canBuild(suggestion.to),
                          "\(load) backs off to \(suggestion.to), which 45/25/10 can't build")
            XCTAssertLessThan(suggestion.to, load)
        }
    }

    func testEveryWarmupRungIsBuildableAndNeverHeavierThanItsFraction() {
        for working in buildableWorkingLoads {
            let ramp = WarmupRamp.generate(for: bench, workingLoad: working)
            for rung in ramp {
                XCTAssertTrue(coarseRack.canBuild(rung.load),
                              "\(working) ramp has \(rung.load), which 45/25/10 can't build")
                XCTAssertLessThan(rung.load, working)
            }
        }
    }

    func testA125RampDropsTheUnbuildable50() {
        // 40% of 125 is 50: 2.5 a side. Rounded down through the plates it is
        // the empty bar, already the first rung.
        let loads = WarmupRamp.generate(for: bench, workingLoad: Load(125)).map(\.load)
        XCTAssertFalse(loads.contains(Load(50)))
        XCTAssertEqual(loads.first, Load(45))
    }
}
