import Foundation
import XCTest
@testable import WeightTrainingCore

// The harness. A scenario declares a lifter and lets the real engine drive
// them for N sessions; nothing here reimplements a rule, because an eval that
// carries its own copy of the logic can only ever agree with itself.

// MARK: - What the lifter does

/// One set as it was actually performed — the load comes from what the app
/// proposed, so a lifter chooses only effort and reps.
public struct Attempt {
    public var reps: Int
    public var rpe: RPE?

    public init(_ reps: Int, _ rpe: Double? = nil) {
        self.reps = reps
        self.rpe = rpe.flatMap(RPE.init)
    }
}

/// How a body responds to what it's asked to do.
///
/// Deliberately a closure rather than a table of fixtures: the interesting
/// scenarios are the ones where the response *depends* on the load the engine
/// arrived at, which isn't known until the run reaches that session.
public struct Lifter {
    public let name: String
    let perform: (_ session: Int, _ load: Load, _ reps: Int, _ exercise: Exercise) -> [Attempt]

    public init(
        _ name: String,
        perform: @escaping (Int, Load, Int, Exercise) -> [Attempt]
    ) {
        self.name = name
        self.perform = perform
    }
}

// MARK: - What happened

public struct SessionTrace {
    public let index: Int
    public let prescribed: Load
    public let prescribedReps: Int
    public let performed: [SetRecord]
    public let change: ProgressionChange
    public let stateAfter: ProgressState
    public let deload: DeloadSuggestion?
    public let tookDeload: Bool
}

public struct Trace {
    public let scenario: String
    public let exercise: Exercise
    public let sessions: [SessionTrace]

    /// The last load the app proposed, which is the number the lifter would
    /// walk into the gym with.
    public var finalTarget: Load? { sessions.last?.stateAfter.targetLoad }

    public var deloads: [SessionTrace] { sessions.filter { $0.tookDeload } }

    /// Every load the app put in front of the lifter, in order.
    public var loadPath: [Load] { sessions.map(\.prescribed) }
}

// MARK: - Scoring

public struct CheckResult {
    public let name: String
    public let passed: Bool
    public let detail: String
}

/// A judgement about training, checked against a finished run.
///
/// Separate from an invariant because the two fail for different reasons. An
/// invariant fails when the engine proposed something it must never propose;
/// an expectation fails when the engine behaved legally but unhelpfully, and
/// reasonable people can disagree about where that line sits.
public struct Expectation {
    public let name: String
    let check: (Trace) -> CheckResult

    public init(_ name: String, check: @escaping (Trace) -> CheckResult) {
        self.name = name
        self.check = check
    }

    static func result(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String) -> CheckResult {
        CheckResult(name: name, passed: passed, detail: passed ? "" : detail())
    }

    /// The load must climb by at least this much over the whole run.
    public static func gains(atLeast delta: Load) -> Expectation {
        Expectation("gains at least \(delta)") { trace in
            guard let first = trace.loadPath.first, let last = trace.finalTarget else {
                return result("gains at least \(delta)", false, "no sessions ran")
            }
            let gained = last - first
            return result("gains at least \(delta)", gained >= delta,
                          "gained \(gained) (\(first) → \(last))")
        }
    }

    /// The load must not climb past this, which is how a plateau scenario
    /// proves the engine stopped pushing rather than marching into a wall.
    public static func neverExceeds(_ ceiling: Load) -> Expectation {
        Expectation("never proposes more than \(ceiling)") { trace in
            let worst = trace.loadPath.max() ?? .zero
            return result("never proposes more than \(ceiling)", worst <= ceiling,
                          "proposed \(worst)")
        }
    }

    /// A deload must arrive, and arrive before the lifter has spent months
    /// failing at the same weight.
    public static func deloads(within sessions: Int) -> Expectation {
        Expectation("deloads within \(sessions) sessions") { trace in
            guard let first = trace.deloads.first else {
                return result("deloads within \(sessions) sessions", false, "never deloaded")
            }
            return result("deloads within \(sessions) sessions", first.index < sessions,
                          "first deload at session \(first.index)")
        }
    }

    public static var neverDeloads: Expectation {
        Expectation("never deloads") { trace in
            result("never deloads", trace.deloads.isEmpty,
                   "deloaded at \(trace.deloads.map(\.index))")
        }
    }

    /// Every session must end with the lifter knowing what to do next.
    public static var alwaysKnowsWhatToDoNext: Expectation {
        Expectation("always proposes a next target") { trace in
            let blind = trace.sessions.filter { $0.stateAfter.targetLoad == nil }
            return result("always proposes a next target", blind.isEmpty,
                          "silent after sessions \(blind.map(\.index))")
        }
    }
}

// MARK: - The scenario

public struct EvalScenario {
    public let name: String
    public let exercise: Exercise
    public let startingLoad: Load
    public let sessions: Int
    public let lifter: Lifter
    public let expectations: [Expectation]

    /// Whether the lifter takes the deload when one is offered.
    ///
    /// Both answers are real: the app proposes and the lifter decides, so a
    /// scenario where the offer is ignored is testing something that actually
    /// happens rather than a hypothetical.
    public let takesDeloads: Bool

    public init(
        _ name: String,
        exercise: Exercise,
        startingLoad: Load,
        sessions: Int,
        lifter: Lifter,
        takesDeloads: Bool = true,
        expectations: [Expectation]
    ) {
        self.name = name
        self.exercise = exercise
        self.startingLoad = startingLoad
        self.sessions = sessions
        self.lifter = lifter
        self.takesDeloads = takesDeloads
        self.expectations = expectations
    }
}

// MARK: - The runner

public enum EvalRunner {

    /// Sessions land two days apart at midday.
    ///
    /// Midday because the store groups sets by calendar day, so a fixture built
    /// from `Date()` with minute offsets straddles midnight and splits one
    /// session into two — which failed for real at 23:56 (#79). Two days apart
    /// because deload triggers count sessions of this exercise, and a run where
    /// two sessions share a date would silently collapse them.
    static let epoch = Date(timeIntervalSince1970: 1_760_000_000)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(forSession index: Int) -> Date {
        let midday = calendar.startOfDay(for: epoch).addingTimeInterval(12 * 3600)
        return midday.addingTimeInterval(Double(index) * 2 * 86_400)
    }

    public static func run(_ scenario: EvalScenario) -> Trace {
        let exercise = scenario.exercise
        // Snapped up front so a scenario author's round number can't fail an
        // invariant that is about the engine, not about them.
        var state = ProgressState(exerciseID: exercise.id)
        var history: [SetRecord] = []
        var traces: [SessionTrace] = []
        var pendingStart = exercise.achievableTarget(echoing: scenario.startingLoad)

        for index in 0..<scenario.sessions {
            let when = date(forSession: index)

            // What the app would put on screen: the engine's target, or the
            // cold-start load on the very first visit.
            var load = state.targetLoad ?? pendingStart
            let reps = state.targetReps ?? exercise.progressionRule.displayRepTarget

            // The deload chip is offered before the set is performed, which is
            // when a lifter would actually see it.
            let offered = DeloadDetector.evaluate(
                exercise: exercise, state: state, history: history, calendar: calendar
            )
            var took = false
            if let offered, scenario.takesDeloads, offered.to != load {
                load = offered.to
                took = true
            }

            let performed = scenario.lifter
                .perform(index, load, reps, exercise)
                .map { attempt in
                    SetRecord(exerciseID: exercise.id, load: load, reps: attempt.reps,
                              rpe: attempt.rpe, performedAt: when)
                }

            history.append(contentsOf: performed)
            let result = ProgressionEngine.advance(
                exercise: exercise, state: state, performed: performed, now: when
            )
            state = result.state
            pendingStart = load

            traces.append(SessionTrace(
                index: index, prescribed: load, prescribedReps: reps,
                performed: performed, change: result.change, stateAfter: state,
                deload: offered, tookDeload: took
            ))
        }

        return Trace(scenario: scenario.name, exercise: exercise, sessions: traces)
    }
}

// MARK: - Reporting

public struct EvalReport {
    public let scenario: String
    public let lifter: String
    public let invariants: [CheckResult]
    public let expectations: [CheckResult]
    public let trace: Trace

    public var invariantFailures: [CheckResult] { invariants.filter { !$0.passed } }
    public var expectationFailures: [CheckResult] { expectations.filter { !$0.passed } }

    public var score: Double {
        guard !expectations.isEmpty else { return 1 }
        return Double(expectations.count - expectationFailures.count) / Double(expectations.count)
    }

    /// One line per session, in the terms the domain uses.
    ///
    /// Printed on failure rather than an assertion line, because "session 7:
    /// 185 lb × 8 → held after miss" is a thing a lifter can recognise and an
    /// index into an array is not.
    public var timeline: String {
        trace.sessions.map { session in
            let reps = session.performed.filter { !$0.isWarmup }.map { String($0.reps) }
                .joined(separator: "/")
            let deload = session.tookDeload ? "  ⟵ took deload" : ""
            return String(format: "  %2d  %-9@ × %-8@ %@%@",
                          session.index, session.prescribed.description as NSString,
                          reps as NSString,
                          ProgressionResult(state: session.stateAfter, change: session.change)
                              .summary as NSString,
                          deload as NSString)
        }.joined(separator: "\n")
    }
}

public enum Evaluator {

    public static func evaluate(_ scenario: EvalScenario) -> EvalReport {
        let trace = EvalRunner.run(scenario)
        return EvalReport(
            scenario: scenario.name,
            lifter: scenario.lifter.name,
            invariants: Invariants.check(trace),
            expectations: scenario.expectations.map { $0.check(trace) },
            trace: trace
        )
    }

    /// Runs a scenario and fails the test on any invariant breach, then on any
    /// unmet expectation. Invariants first: an engine that proposed an
    /// impossible weight makes every judgement above it meaningless.
    public static func assertPasses(
        _ scenario: EvalScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = evaluate(scenario)

        for failure in report.invariantFailures {
            XCTFail("""
                [\(report.scenario)] invariant broken — \(failure.name)
                \(failure.detail)
                \(report.timeline)
                """, file: file, line: line)
        }

        for failure in report.expectationFailures {
            XCTFail("""
                [\(report.scenario)] \(failure.name) — \(failure.detail)
                \(report.timeline)
                """, file: file, line: line)
        }
    }
}
