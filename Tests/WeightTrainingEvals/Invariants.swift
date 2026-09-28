import Foundation
@testable import WeightTrainingCore

/// Things that must hold after every session of every scenario, forever.
///
/// These aren't judgements about training — they're the promises the app makes
/// about what a number on screen means. A breach is a bug regardless of what
/// the scenario was trying to show, which is why they're checked centrally
/// rather than restated per scenario.
public enum Invariants {

    public static func check(_ trace: Trace) -> [CheckResult] {
        [
            everyProposalIsBuildable(trace),
            nothingBelowTheLightestUsableLoad(trace),
            loadClimbsOneIncrementAtATime(trace),
            deloadsGoDownAndStayPositive(trace),
            repTargetsStayInRange(trace),
            onTargetMeansOnTarget(trace)
        ]
    }

    private static func pass(_ name: String) -> CheckResult {
        CheckResult(name: name, passed: true, detail: "")
    }

    private static func fail(_ name: String, _ detail: String) -> CheckResult {
        CheckResult(name: name, passed: false, detail: detail)
    }

    /// Every weight the app proposes has to be one the equipment can make.
    ///
    /// Asked of `canBuild`, which reads the plates on a measured apparatus and
    /// the increment everywhere else. It used to be asked of
    /// `achievableTarget` — the same function that produced most targets, so
    /// the check agreed with itself by construction. On a rack without 2.5 lb
    /// plates that snaps to a 5 lb increment and passes 140 lb, which no plate
    /// set on that rack can make (#241).
    static func everyProposalIsBuildable(_ trace: Trace) -> CheckResult {
        let name = "every proposal is buildable"
        for session in trace.sessions {
            guard let target = session.stateAfter.targetLoad else { continue }
            if !trace.exercise.canBuild(target) {
                return fail(name, "session \(session.index) proposed \(target), "
                            + "which this equipment cannot build — the screen "
                            + "would show \(trace.exercise.nearestAchievable(target))")
            }
        }
        return pass(name)
    }

    /// "Back off to 0 lb and rebuild" is not a deload, it's a bug with a
    /// friendly sentence around it. Nothing may fall below what the apparatus
    /// can present empty.
    static func nothingBelowTheLightestUsableLoad(_ trace: Trace) -> CheckResult {
        let name = "nothing below the lightest usable load"
        let floor = trace.exercise.lightestUsableLoad
        for session in trace.sessions {
            if session.prescribed < floor {
                return fail(name, "session \(session.index) prescribed "
                            + "\(session.prescribed), floor is \(floor)")
            }
            if let target = session.stateAfter.targetLoad, target < floor {
                return fail(name, "session \(session.index) targets \(target), "
                            + "floor is \(floor)")
            }
        }
        return pass(name)
    }

    /// Double progression exists because equipment steps are coarse. If a
    /// single session can raise the load by more than one step, the rule has
    /// stopped doing the one thing it's for.
    ///
    /// Scoped to double progression: the RPE-targeted rule computes a
    /// percentage, and 6% of a heavy bar is legitimately more than one step.
    static func loadClimbsOneIncrementAtATime(_ trace: Trace) -> CheckResult {
        let name = "load climbs one increment at a time"
        guard case .doubleProgression = trace.exercise.progressionRule else { return pass(name) }
        let exercise = trace.exercise
        for session in trace.sessions {
            guard let target = session.stateAfter.targetLoad else { continue }
            let jump = target.pounds - session.prescribed.pounds
            // One step is the increment, or — on a measured apparatus whose
            // plates can't make the increment — the next load the rack can
            // actually build. A rack without 2.5 lb plates steps a bar by 10 lb
            // no matter what the increment says (#241).
            var step = exercise.increment.pounds
            if let loading = exercise.loading, loading.isMeasured,
               let next = loading.nextBuildable(after: session.prescribed) {
                step = max(step, next.pounds - session.prescribed.pounds)
            }
            // A hair of slack for plate snapping on a measured apparatus, where
            // one increment up may land a fraction past the nominal step.
            if jump > step + 0.001 {
                return fail(name, "session \(session.index) went "
                            + "\(session.prescribed) → \(target), a \(jump) lb jump "
                            + "on a \(step) lb step")
            }
        }
        return pass(name)
    }

    /// A deload that proposes the weight you're already failing at, or a
    /// weight at or below nothing, is worse than silence.
    static func deloadsGoDownAndStayPositive(_ trace: Trace) -> CheckResult {
        let name = "deloads go down and stay positive"
        for session in trace.sessions {
            guard let deload = session.deload else { continue }
            if deload.to >= deload.from {
                return fail(name, "session \(session.index) proposed "
                            + "\(deload.from) → \(deload.to)")
            }
            if deload.to.pounds <= 0 {
                return fail(name, "session \(session.index) proposed \(deload.to)")
            }
        }
        return pass(name)
    }

    /// A rep target outside the rule's own range is the engine arguing with
    /// itself, and it's the lifter who has to resolve it mid-set.
    static func repTargetsStayInRange(_ trace: Trace) -> CheckResult {
        let name = "rep targets stay in range"
        guard case .doubleProgression(let range, _) = trace.exercise.progressionRule else {
            return pass(name)
        }
        for session in trace.sessions {
            guard let reps = session.stateAfter.targetReps else { continue }
            if !range.contains(reps) {
                return fail(name, "session \(session.index) targets \(reps) reps, "
                            + "range is \(range.bottom)–\(range.top)")
            }
        }
        return pass(name)
    }

    /// "On target" is a claim about the effort the lifter reported, not about
    /// the load. A rule that holds because its step is too coarse and calls
    /// that "on target" tells a lifter who just reported RPE 7 against a
    /// target of 8 that they hit it — every session, while the lift never
    /// moves (#240).
    static func onTargetMeansOnTarget(_ trace: Trace) -> CheckResult {
        let name = "on target only when the effort was"
        guard case .rpeTargetedLoad(_, let target) = trace.exercise.progressionRule else {
            return pass(name)
        }
        for session in trace.sessions {
            guard case .onTarget = session.change else { continue }
            // The set the rule steers by: the heaviest one carrying an RPE.
            let reference = session.performed
                .filter { !$0.isWarmup && $0.rpe != nil }
                .max { $0.load < $1.load }
            guard let reported = reference?.rpe, reported != target else { continue }
            return fail(name, "session \(session.index) reported \(reported) against "
                        + "\(target) and was told it was on target")
        }
        return pass(name)
    }
}
