import XCTest
@testable import WeightTrainingCore

/// A season in which the lifter changes a default rest partway through (#341).
///
/// A plan records the rest it was run at, and both the progression rule (two
/// easy sessions *at the same plan*) and the program-fatigue detector (two hot
/// sessions *at a comparable plan*) refuse to read across a different rest.
/// `TrainingBlockEvals` checks the detector at the seam. These run every lift
/// forward for weeks and ask what the change costs the lifter overall: how long
/// progress is held, which lifts it touches, and whether the blind spot it opens
/// in fatigue detection ever widens past one session.
///
/// The harness plays the app and nothing more. Each session's plan carries the
/// engine's own recommended sets and the rest `restTarget(using:)` gives under
/// that day's defaults, and keeps the previous plan's identity when nothing in
/// it changed, which is the shape `TrainingStore.activateExerciseRecommendation`
/// persists. That Store path is pinned by `RestDefaultsStoreTests`; this target
/// depends on Core only and cannot reach it.
///
/// `assertInvariants` is the hard part: a breach means the engine proposed
/// something it must never propose. Everything else in each test is an
/// expectation, a judgement about training that is revisable if the rules
/// change on purpose.
final class RestDefaultSeasonEvals: XCTestCase {

    // MARK: - Harness

    private struct Lift {
        let label: String
        let exercise: Exercise
        /// The rest recorded on the plan the season starts from. `nil` is a
        /// plan written before plans recorded rest at all.
        let firstRest: Int?
    }

    /// What the lifter was asked to do in one session, and what the engine
    /// made of it afterwards.
    private struct Step {
        let session: Int
        let plan: ExercisePlan
        let recommendation: ExerciseRecommendation
    }

    private struct Season {
        var steps: [String: [Step]] = [:]
        /// Whether the program-fatigue detector fired going into each session.
        var fatigueBefore: [Bool] = []

        func progressSessions(_ label: String) -> [Int] {
            (steps[label] ?? []).filter { [.addReps, .addLoad].contains($0.recommendation.action) }
                .map(\.session)
        }

        func timeline(_ label: String) -> [String] {
            (steps[label] ?? []).map { "\($0.recommendation.action):\($0.recommendation.sets.map(\.reps))" }
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_760_011_200)   // midday UTC (#79)

    private static func date(_ session: Int) -> Date {
        epoch.addingTimeInterval(Double(session) * 2 * 86_400)
    }

    private static func accessory(_ name: String, _ muscle: Muscle, rest: TimeInterval? = nil) -> Exercise {
        Exercise(name: name, muscles: [.primary(muscle)], equipment: .machineStack,
                 increment: LoadIncrement(5, .pounds),
                 progressionRule: .doubleProgression(range: RepRange(8, 12)), restOverride: rest)
    }

    private static let compound = Exercise(
        name: "Machine Chest Press",
        muscles: [.primary(.chest), .secondary(.triceps), .secondary(.frontDelts)],
        equipment: .machineStack, increment: LoadIncrement(5, .pounds),
        progressionRule: .doubleProgression(range: RepRange(8, 12)))

    /// Runs every lift for `sessions` sessions. `defaults(s)` is what Settings
    /// says when session `s` starts; `effort` is the RPE the lifter reports on
    /// set `set` of a plan.
    private func run(
        _ lifts: [Lift], sessions: Int,
        defaults: (Int) -> RestDefaults,
        effort: (_ session: Int, _ lift: Lift, _ plan: ExercisePlan, _ set: Int) -> RPE
    ) -> Season {
        var season = Season()
        var plans: [String: ExercisePlan] = [:]
        var history: [String: [ExerciseExposure]] = [:]
        for lift in lifts {
            plans[lift.label] = ExercisePlan(
                exercise: lift.exercise,
                sets: Array(repeating: PlannedWorkingSet(load: 100, reps: 11, rpe: .eight), count: 3),
                restSeconds: lift.firstRest)
        }

        for session in 0..<sessions {
            let start = Self.date(session)
            season.fatigueBefore.append(TrainingBlockEngine.adaptiveDeloadNeeded(
                history: history.values.flatMap { $0 }, now: start))

            for lift in lifts {
                let plan = plans[lift.label]!
                let sets = plan.sets.enumerated().map { index, target in
                    ExposureSet(record: SetRecord(
                        exerciseID: lift.exercise.id, load: target.load, reps: target.reps,
                        rpe: effort(session, lift, plan, index),
                        performedAt: start.addingTimeInterval(Double(index) * 120)
                    ), effortSource: .reported)
                }
                let finished = start.addingTimeInterval(1_800)
                history[lift.label, default: []].append(ExerciseExposure(
                    id: UUID(), exerciseID: lift.exercise.id, plan: plan, sets: sets,
                    completion: .completed, completedAt: finished))

                let recommendation = RecommendationEngine.recommend(
                    exercise: lift.exercise, plan: plan, history: history[lift.label]!,
                    policy: lift.exercise.recommendationPolicy, now: finished)
                season.steps[lift.label, default: []].append(
                    Step(session: session, plan: plan, recommendation: recommendation))

                // The next session's plan, built the way the app builds it.
                let next = recommendation.sets.isEmpty ? plan.sets : recommendation.sets
                let rest = Int(lift.exercise.restTarget(using: defaults(session + 1)))
                let same = ExercisePlan(id: plan.id, exercise: lift.exercise, sets: next, restSeconds: rest)
                plans[lift.label] = same == plan
                    ? plan
                    : ExercisePlan(exercise: lift.exercise, sets: next, restSeconds: rest)
            }
        }
        return season
    }

    /// The promises a number on screen makes, for the planned-set engine.
    /// A breach here is a bug whatever the scenario was demonstrating.
    private func assertInvariants(_ season: Season, _ lifts: [Lift], _ run: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for lift in lifts {
            let exercise = lift.exercise
            for step in season.steps[lift.label] ?? [] {
                let at = "[\(run)] \(lift.label) session \(step.session)"
                let proposed = step.recommendation.sets
                XCTAssertFalse(proposed.isEmpty, "\(at) proposed nothing: \(step.recommendation.reason)",
                               file: file, line: line)
                for target in proposed {
                    XCTAssertTrue(exercise.canBuild(target.load),
                                  "\(at) proposed \(target.load), which this equipment cannot build",
                                  file: file, line: line)
                    XCTAssertGreaterThanOrEqual(target.load, exercise.lightestUsableLoad,
                                                "\(at) went below the lightest usable load",
                                                file: file, line: line)
                    XCTAssertTrue((8...12).contains(target.reps),
                                  "\(at) targets \(target.reps) reps outside 8-12", file: file, line: line)
                    let jump = target.load.pounds - step.plan.sets[0].load.pounds
                    XCTAssertLessThanOrEqual(jump, exercise.increment.pounds + 0.001,
                                             "\(at) climbed \(jump) lb in one session",
                                             file: file, line: line)
                }
            }
        }
    }

    // MARK: - Progress across the change

    /// An easy lifter, every lift progressing, with accessories going from
    /// 1:30 to 1:00 a quarter of the way in. Compared against the same season
    /// with no change.
    ///
    /// Two easy sessions at one plan earn a rep. A plan at a new rest is a new
    /// plan, so a change that lands between those two sessions costs that lift
    /// one session of progress. It must cost no more than that, it must touch
    /// only the lifts that follow the changed default, and a plan from before
    /// plans recorded rest must pay the same one session, once.
    func testAMidSeasonAccessoryRestChangeCostsAtMostOneSessionOfProgress() {
        let lifts = [
            Lift(label: "extension", exercise: Self.accessory("Leg Extension", .quads), firstRest: 90),
            Lift(label: "curl", exercise: Self.accessory("Machine Curl", .biceps), firstRest: 90),
            Lift(label: "press", exercise: Self.compound, firstRest: 180),
            Lift(label: "pushdown", exercise: Self.accessory("Pushdown", .triceps, rest: 120), firstRest: 120),
            Lift(label: "legacy", exercise: Self.accessory("Rear Delt Fly", .rearDelts), firstRest: nil),
        ]
        XCTAssertTrue(Self.compound.isCompound)
        XCTAssertTrue(lifts.filter { $0.label != "press" }.allSatisfy { !$0.exercise.isCompound })

        let old = RestDefaults(compound: 180, accessory: 90)
        let changeAt = 5
        let easy: (Int, Lift, ExercisePlan, Int) -> RPE = { _, _, _, _ in .seven }
        let control = run(lifts, sessions: 20, defaults: { _ in old }, effort: easy)
        let changed = run(lifts, sessions: 20,
                          defaults: { $0 < changeAt ? old : .standard }, effort: easy)
        assertInvariants(control, lifts, "control")
        assertInvariants(changed, lifts, "changed")

        // Not vacuous: the change reached the plans, landed between two
        // confirming sessions, and the season got as far as a load increase.
        XCTAssertEqual(changed.steps["curl"]![changeAt - 1].plan.restSeconds, 90)
        XCTAssertEqual(changed.steps["curl"]![changeAt].plan.restSeconds, 60)
        XCTAssertEqual(control.steps["curl"]![changeAt - 1].recommendation.action, .hold,
                       "the change has to land halfway through confirming a plan, or the bound below is untested")
        XCTAssertTrue(control.steps["curl"]!.contains { $0.recommendation.action == .addLoad },
                      "the season has to reach a load increase")

        // Lifts that don't follow the accessory default don't notice it.
        for label in ["press", "pushdown"] {
            XCTAssertEqual(changed.timeline(label), control.timeline(label),
                           "\(label) changed course because the accessory default did")
            XCTAssertEqual(Set(changed.steps[label]!.map(\.plan.restSeconds)),
                           Set(control.steps[label]!.map(\.plan.restSeconds)))
        }

        // Lifts that do pay one session, and only one.
        for label in ["extension", "curl"] {
            let before = control.progressSessions(label), after = changed.progressSessions(label)
            XCTAssertGreaterThanOrEqual(after.count, before.count - 1, "\(label): \(before) vs \(after)")
            for (expected, actual) in zip(before, after) {
                XCTAssertLessThanOrEqual(actual - expected, 1,
                                         "\(label) fell more than one session behind: \(before) vs \(after)")
            }
        }

        // A plan from before rest was recorded picks up today's default on the
        // next session and pays the same one session, once, not every session.
        XCTAssertNil(control.steps["legacy"]![0].plan.restSeconds)
        XCTAssertEqual(control.steps["legacy"]![1].plan.restSeconds, 90)
        let recorded = control.progressSessions("extension"), legacy = control.progressSessions("legacy")
        XCTAssertGreaterThanOrEqual(legacy.count, recorded.count - 1)
        for (expected, actual) in zip(recorded, legacy) {
            XCTAssertLessThanOrEqual(actual - expected, 1,
                                     "a plan with no recorded rest kept costing sessions: \(recorded) vs \(legacy)")
        }
    }

    // MARK: - Fatigue detection across changes

    /// Two accessories logged one RPE above target every session, so the
    /// detector has a real signal throughout. The default goes 1:30 to 1:00
    /// and later back again.
    ///
    /// Each change blinds the detector for exactly the one session whose last
    /// two exposures straddle it. Before, between and after, the same effort
    /// at a steady rest is read as fatigue again: a change of setting is a
    /// seam, never a way to switch the signal off for good.
    func testEachRestChangeBlindsFatigueDetectionForExactlyOneSession() {
        let lifts = [
            Lift(label: "extension", exercise: Self.accessory("Leg Extension", .quads), firstRest: 90),
            Lift(label: "curl", exercise: Self.accessory("Machine Curl", .biceps), firstRest: 90),
            Lift(label: "press", exercise: Self.compound, firstRest: 180),
        ]
        let old = RestDefaults(compound: 180, accessory: 90)
        let (down, up) = (6, 11)
        let season = run(lifts, sessions: 16,
                         defaults: { ($0 >= down && $0 < up) ? .standard : old },
                         effort: { _, lift, _, _ in lift.exercise.isCompound ? .eight : .nine })
        assertInvariants(season, lifts, "hot accessories")

        XCTAssertEqual(season.steps["curl"]![down].plan.restSeconds, 60)
        XCTAssertEqual(season.steps["curl"]![up].plan.restSeconds, 90)
        XCTAssertEqual(Set(season.steps["curl"]!.map(\.plan.id)).count, 3,
                       "steady hot effort holds the plan, so only the two rest changes start a new one")

        // Two exposures are needed before anything can be read at all.
        let blind = season.fatigueBefore.indices.filter { $0 >= 2 && !season.fatigueBefore[$0] }
        XCTAssertEqual(blind, [down + 1, up + 1],
                       "fatigue detection was blind at sessions \(blind), not just after each change")
    }

    // MARK: - A shorter rest that is genuinely harder

    /// The realistic shape of the change: on target at 1:30, then at 1:00 the
    /// first set is unchanged (rest only comes before the second) and the
    /// later two run one RPE hot, for three sessions, until the lifter adapts.
    ///
    /// That is a prescription that is briefly too hard, not fatigue. The lift
    /// should hold, never back off and never be offered a deload, and progress
    /// again once the effort settles.
    func testAShorterRestThatTiresLaterSetsHoldsAndThenResumes() {
        let lifts = [
            Lift(label: "extension", exercise: Self.accessory("Leg Extension", .quads), firstRest: 90),
            Lift(label: "curl", exercise: Self.accessory("Machine Curl", .biceps), firstRest: 90),
            Lift(label: "press", exercise: Self.compound, firstRest: 180),
        ]
        let old = RestDefaults(compound: 180, accessory: 90)
        let changeAt = 6, adaptedAt = 9
        let season = run(lifts, sessions: 20, defaults: { $0 < changeAt ? old : .standard }) { session, lift, plan, set in
            guard !lift.exercise.isCompound else { return .eight }
            if session < changeAt { return .eight }
            if session < adaptedAt { return (plan.restSeconds == 60 && set > 0) ? .nine : .eight }
            return .seven
        }
        assertInvariants(season, lifts, "shorter rest")

        XCTAssertFalse(season.fatigueBefore.contains(true),
                       "a harder rest read as fatigue at sessions \(season.fatigueBefore.indices.filter { season.fatigueBefore[$0] })")
        for label in ["extension", "curl"] {
            let steps = season.steps[label]!
            XCTAssertTrue(steps[changeAt..<adaptedAt].contains { $0.recommendation.reason == .effortAboveTarget },
                          "\(label): the harder sessions have to be seen as too hard, or this proves nothing")
            XCTAssertFalse(steps.contains { [.reduce, .deload].contains($0.recommendation.action) },
                           "\(label) backed off because the rest got shorter")
            XCTAssertTrue(steps[adaptedAt...].contains { [.addReps, .addLoad].contains($0.recommendation.action) },
                          "\(label) never resumed progressing once the effort settled")
        }
    }
}
