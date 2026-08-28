import XCTest
@testable import WeightTrainingCore

/// Each case asks a question a unit test can't: not "is this value right" but
/// "does a season of these decisions add up to sensible coaching". The
/// scenarios themselves live in `Scenarios`; add one there and assert it here.
final class ProgressionEvals: XCTestCase {

    func testConsistentLifterKeepsProgressing() {
        Evaluator.assertPasses(Scenarios.consistent)
    }

    func testPlateauIsCaughtAndBackedOff() {
        Evaluator.assertPasses(Scenarios.plateau)
    }

    func testIgnoringEveryDeloadStillBehaves() {
        Evaluator.assertPasses(Scenarios.plateauIgnored)
    }

    func testRisingEffortAtAnUnchangedLoadIsCaught() {
        Evaluator.assertPasses(Scenarios.creep)
    }

    func testGrindingTheTopEarnsNothing() {
        Evaluator.assertPasses(Scenarios.grinding)
    }

    func testRPETargetedLoadFollowsTheEffortReported() {
        Evaluator.assertPasses(Scenarios.benchByFeel)
    }
}

/// Prints every scenario's session-by-session trace, and the scoreboard.
///
/// Off by default because a green run should be quiet. Set `EVAL_VERBOSE=1`
/// when you want to read what the engine actually decided rather than only
/// whether it stayed legal:
///
///     EVAL_VERBOSE=1 swift test --filter WeightTrainingEvals
///
/// This is also the guard against a scenario that passes vacuously — a
/// plateau eval that never actually reaches the plateau is green and worthless,
/// and the timeline is the only place that shows up.
final class EvalReportCard: XCTestCase {

    func testScoreboard() {
        let reports = Scenarios.all.map(Evaluator.evaluate)
        guard ProcessInfo.processInfo.environment["EVAL_VERBOSE"] != nil else { return }

        for report in reports {
            print("\n=== \(report.scenario) — \(report.lifter) ===")
            print(report.timeline)
            let checks = report.invariants + report.expectations
            for check in checks {
                let mark = check.passed ? "PASS" : "FAIL"
                let detail = check.detail.isEmpty ? "" : " — \(check.detail)"
                print("  [\(mark)] \(check.name)\(detail)")
            }
            print(String(format: "  score %.0f%%", report.score * 100))
        }
    }
}
