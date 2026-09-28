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
        [consistent, plateau, plateauIgnored, creep, grinding, benchByFeel,
         rowWithoutSmallestPlateLB, rowWithoutSmallestPlateKG,
         lightBenchByFeelLB, lightBenchByFeelKG,
         benchByFeelWithoutSmallestPlateLB, benchByFeelWithoutSmallestPlateKG,
         rdlByFeelWithoutSmallestPlateKG]
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
    /// A custom double-progression lift, placed in a gym the way the app does
    /// it: the gym's rack and unit applied to the loading, the increment
    /// re-marked only if it was still the equipment's default.
    static func customLift(
        _ name: String,
        equipment: Equipment,
        rule: ProgressionRule,
        in gym: GymConfig
    ) -> Exercise {
        var lift = Exercise(name: name, muscles: [.primary(.lats)],
                            equipment: equipment, progressionRule: rule)
        if let loading = lift.loading { lift.loading = gym.applied(to: loading) }
        lift.increment = gym.applied(to: lift.increment, for: equipment)
        return lift
    }

    /// A rack without 2.5 lb plates still has to move a bar up (#241).
    ///
    /// The 5 lb increment asks for 140 after 135, which `[45, 35, 25, 10, 5]`
    /// cannot build; the screen snaps it back to 135 and the lifter redoes the
    /// rep ladder at the same weight forever — "Earned it: 135 → 140" every six
    /// sessions, 0 lb gained in thirty. The smallest step this rack can make is
    /// 10 lb, and that is the step double progression has to take.
    public static var rowWithoutSmallestPlateLB: EvalScenario {
        let gym = GymConfig(unit: .pounds, availablePlates: [45, 35, 25, 10, 5])
        return EvalScenario(
            "barbell row, lb rack without 2.5s",
            exercise: customLift("Barbell Row", equipment: .barbell,
                                 rule: .doubleProgression(range: RepRange(8, 12)), in: gym),
            startingLoad: Load(135),
            sessions: 30,
            lifter: .consistent(at: 8),
            expectations: [
                .gains(atLeast: Load(20)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// The same loop in a kilogram gym without 1.25 kg plates: 60 → 62.5 is
    /// unbuildable, so the smallest real step is 5 kg.
    public static var rowWithoutSmallestPlateKG: EvalScenario {
        let gym = GymConfig(unit: .kilograms, availablePlates: [25, 20, 15, 10, 5, 2.5])
        return EvalScenario(
            "barbell row, kg rack without 1.25s",
            exercise: customLift("Barbell Row", equipment: .barbell,
                                 rule: .doubleProgression(range: RepRange(8, 12)), in: gym),
            startingLoad: Load(60, .kilograms),
            sessions: 30,
            lifter: .consistent(at: 8),
            expectations: [
                .gains(atLeast: Load(10, .kilograms)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    // MARK: - RPE-targeted lifts on a coarse step (#240)

    /// A library lift placed in a gym the way the app does it.
    static func libraryLift(_ name: String, in gym: GymConfig) -> Exercise {
        var lift = exercise(name)
        if let loading = lift.loading { lift.loading = gym.applied(to: loading) }
        lift.increment = gym.applied(to: lift.increment, for: lift.equipment)
        return lift
    }

    /// Three percent of 75 lb is 2.25 lb — under half the 5 lb step, so the
    /// proposal snapped back to 75 and the chip said "On target" to a lifter a
    /// full point under target. A novice bench on a standard rack stalled from
    /// the first session and never moved.
    public static var lightBenchByFeelLB: EvalScenario {
        EvalScenario(
            "light bench under target effort, standard lb rack",
            exercise: exercise("Flat Bench"),
            startingLoad: Load(75),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(25)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// The same stall in kilograms: 3% of 40 kg is 1.2 kg against a 2.5 kg
    /// step, even with 1.25s on the rack.
    public static var lightBenchByFeelKG: EvalScenario {
        EvalScenario(
            "light bench under target effort, standard kg rack",
            exercise: libraryLift("Flat Bench", in: GymConfig(unit: .kilograms)),
            startingLoad: Load(40, .kilograms),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(12.5, .kilograms)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// Without 2.5 lb plates the bar moves 10 lb, and 3% stays under half of
    /// that until ~167 lb — an ordinary intermediate bench stalled at 155.
    public static var benchByFeelWithoutSmallestPlateLB: EvalScenario {
        EvalScenario(
            "bench under target effort, lb rack without 2.5s",
            exercise: libraryLift("Flat Bench",
                                  in: GymConfig(unit: .pounds, availablePlates: [45, 35, 25, 10, 5])),
            startingLoad: Load(155),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(40)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// A kg gym without fractional plates moves a bar 5 kg, and 3% stays under
    /// half of that until ~83 kg: an 80 kg bench stalled permanently.
    public static var benchByFeelWithoutSmallestPlateKG: EvalScenario {
        EvalScenario(
            "bench under target effort, kg rack without 1.25s",
            exercise: libraryLift("Flat Bench",
                                  in: GymConfig(unit: .kilograms,
                                                availablePlates: [25, 20, 15, 10, 5, 2.5])),
            startingLoad: Load(80, .kilograms),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(20, .kilograms)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }

    /// The same rack under an 8-rep hinge: a 70 kg RDL stalled from session one.
    public static var rdlByFeelWithoutSmallestPlateKG: EvalScenario {
        EvalScenario(
            "RDL under target effort, kg rack without 1.25s",
            exercise: libraryLift("RDL",
                                  in: GymConfig(unit: .kilograms,
                                                availablePlates: [25, 20, 15, 10, 5, 2.5])),
            startingLoad: Load(70, .kilograms),
            sessions: 10,
            lifter: .reportsEffort(7),
            expectations: [
                .gains(atLeast: Load(20, .kilograms)),
                .neverDeloads,
                .alwaysKnowsWhatToDoNext
            ]
        )
    }
}
