import Foundation
@testable import WeightTrainingCore

/// The catalog.
///
/// Scenarios live here rather than inline in the test bodies so the same
/// definition can be asserted on in CI and printed as a timeline when you're
/// trying to understand what the engine actually did. A scenario you can't
/// read the trace of is a scenario you can only trust or distrust wholesale.
public enum Scenarios {

    static func exercise(_ name: String) -> Exercise {
        ExerciseLibrary.all.first { $0.name == name }!
    }

    public static var all: [EvalScenario] {
        [consistent, plateau, plateauIgnored, creep, grinding, benchByFeel]
    }

    /// Thirty sessions of doing exactly what was asked has to produce real
    /// weight on the bar. If reps climb, the top gets banked, and the load
    /// still doesn't move, double progression is decorative.
    public static var consistent: EvalScenario {
        EvalScenario(
            "consistent lifter, incline DB press",
            exercise: exercise("Incline DB Press"),
            startingLoad: Load(50),
            sessions: 30,
            lifter: .consistent(at: 8),
            expectations: [
                .gains(atLeast: Load(15)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// A lifter who can't make 70 lb must not be asked for 75, 80, 85. The
    /// load has to stop climbing and come back down, and within a few sessions
    /// — a deload that arrives after two months of failure is one nobody
    /// needed by then.
    public static var plateau: EvalScenario {
        let press = exercise("Incline DB Press")
        return EvalScenario(
            "plateau at 65 lb",
            exercise: press,
            startingLoad: Load(50),
            sessions: 34,
            lifter: .stallsAbove(Load(65)),
            expectations: [
                .deloads(within: 34),
                .neverExceeds(Load(65) + Load(press.increment.pounds)),
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// The chip is a proposal, not an instruction. A lifter who ignores every
    /// deload must not push the app into proposing something impossible, and
    /// the offer has to keep standing rather than being made once and dropped.
    public static var plateauIgnored: EvalScenario {
        let press = exercise("Incline DB Press")
        return EvalScenario(
            "plateau at 65 lb, every chip dismissed",
            exercise: press,
            startingLoad: Load(50),
            sessions: 34,
            lifter: .stallsAbove(Load(65)),
            takesDeloads: false,
            expectations: [
                .offersDeload(within: 34),
                .neverExceeds(Load(65) + Load(press.increment.pounds))
            ]
        )
    }

    /// Nothing about the reps looks wrong when effort creeps — that's the
    /// point. If this never produces a deload, the app is blind to the only
    /// stall signal that arrives early.
    public static var creep: EvalScenario {
        EvalScenario(
            "effort creeping at a fixed load",
            exercise: exercise("Incline DB Press"),
            startingLoad: Load(50),
            sessions: 12,
            lifter: .creeping(from: 7),
            expectations: [
                .deloads(within: 8),
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// Twelve reps at RPE 9.5 is not a hit to bank. A lifter grinding out the
    /// top every session should be held there, not rewarded with more weight
    /// for surviving.
    public static var grinding: EvalScenario {
        EvalScenario(
            "grinding the top of the range",
            exercise: exercise("Incline DB Press"),
            startingLoad: Load(50),
            sessions: 10,
            lifter: .grinding(),
            expectations: [
                .neverExceeds(Load(50)),
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// Flat bench steers load by feel rather than banking reps. A lifter
    /// consistently a point under target should be walking into heavier
    /// weight, session over session.
    public static var benchByFeel: EvalScenario {
        EvalScenario(
            "bench under target effort",
            exercise: exercise("Flat Bench"),
            startingLoad: Load(185),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(10)),
                .alwaysKnowsWhatToDoNext
            ]
        )
    }
}
