import XCTest
import WeightTrainingCore
@testable import WeightTrainingStore

/// Tidying a lift keeps its plan (#349).
///
/// #346 taught the engine that a lift renamed, re-tagged, given a warmup ramp
/// or its own rest is still the lift its plan was written for. The Store
/// still decided otherwise in two places: it minted a new plan id whenever the
/// plan's saved copy of the lift differed, which restarted the count of easy
/// workouts, and it refused any proposal whose copy of the lift differed from
/// the stored one, which made Dismiss on a deload proposal fail.
///
/// A season here is the way a workout runs it: activate the suggestion, log
/// every set at RPE 7 with effort reported, finish. Each test that compares a
/// tidied lift with an untouched one also spells out what the untouched season
/// is, so two seasons that are wrong in the same way cannot pass.
///
/// Dates are anchored to midday (#79).
@MainActor
final class LiftEditPlanTests: XCTestCase {
    private var store: TrainingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TrainingStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    /// Every other day, from midday on 10 March 2026.
    private func midday(_ workout: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10 + workout * 2
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private let renamed = "Flat Bench Press"

    private func bench() -> Exercise {
        Exercise(name: "Bench", muscles: [.primary(.chest)], equipment: .barbell,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    /// An accessory: it becomes a compound only by gaining a third muscle.
    private func lateralRaise() -> Exercise {
        Exercise(name: "Lateral Raise", muscles: [.primary(.sideDelts)], equipment: .dumbbell,
                 progressionRule: .doubleProgression(range: RepRange(8, 12)))
    }

    private func sets(_ reps: Int..., load: Double = 100) -> [PlannedWorkingSet] {
        reps.map { PlannedWorkingSet(load: Load(load), reps: $0) }
    }

    private func perform(
        _ store: TrainingStore, _ plan: ExercisePlan, workout: UUID, at start: Date, rpe: RPE = .seven
    ) throws {
        for (index, target) in plan.sets.enumerated() {
            try store.logWorkoutSet(
                SetRecord(exerciseID: plan.exercise.id, load: target.load, reps: target.reps, rpe: rpe,
                          performedAt: start.addingTimeInterval(Double(index + 1) * 180)),
                workoutID: workout, startedAt: start, effortReported: true)
        }
        try store.finishExerciseSessions(workoutID: workout, at: start.addingTimeInterval(1_800))
    }

    // MARK: - A season, with and without an edit

    /// What a workout was told and what plan it ran under.
    private struct Workout: Equatable, CustomStringConvertible {
        let action: ExerciseRecommendation.Action
        let reason: ExerciseRecommendation.Reason
        let sets: [PlannedWorkingSet]
        let restSeconds: Int?
        /// Numbered by first appearance, workout 0's plan being 0, so a `0`
        /// again means the plan was reused and a new number means a new plan.
        let plan: Int?

        var description: String {
            let targets = sets.map { "\($0.load.pounds)x\($0.reps)" }.joined(separator: ",")
            return "\(action) \(reason) [\(targets)] rest=\(restSeconds.map(String.init) ?? "nil") plan=\(plan.map(String.init) ?? "nil")"
        }
    }

    /// Workout 0 is an accepted plan, easy. Then workouts 1... are each run as
    /// suggested at RPE 7, with `edit` applied to the stored lift (and
    /// `changeGym` to the gym) just before `editBefore`.
    private func season(
        lift: Exercise, firstSets: [PlannedWorkingSet], workouts: Int = 4, editBefore: Int = 1,
        changeGym: ((inout GymConfig) -> Void)? = nil, edit: ((inout Exercise) -> Void)? = nil
    ) throws -> [Workout] {
        let store = try TrainingStore.inMemory()
        try store.upsert(lift)
        let firstWorkout = UUID()
        let first = try store.acceptExercisePlan(
            ExercisePlan(exercise: lift, sets: firstSets,
                         restSeconds: Int(lift.restTarget(using: try store.gymConfig().restDefaults))),
            workoutID: firstWorkout, startedAt: midday(0), now: midday(0))
        try perform(store, first, workout: firstWorkout, at: midday(0))

        var lineage: [UUID: Int] = [first.id: 0]
        var log: [Workout] = []
        for index in 1...workouts {
            if index == editBefore {
                if let changeGym {
                    var gym = try store.gymConfig()
                    changeGym(&gym)
                    try store.saveGymConfig(gym)
                }
                if let edit {
                    var current = try XCTUnwrap(store.exercise(id: lift.id))
                    edit(&current)
                    try store.upsert(current)
                }
            }
            let current = try XCTUnwrap(store.exercise(id: lift.id))
            let workout = UUID()
            let recommendation = try store.recommendation(
                for: current, excluding: workout, now: midday(index))
            let plan = try store.activateExerciseRecommendation(
                recommendation, workoutID: workout, startedAt: midday(index), now: midday(index))
            let number = plan.map { plan -> Int in
                if let known = lineage[plan.id] { return known }
                lineage[plan.id] = lineage.count
                return lineage.count - 1
            }
            log.append(Workout(action: recommendation.action, reason: recommendation.reason,
                               sets: recommendation.sets, restSeconds: plan?.restSeconds, plan: number))
            if let plan { try perform(store, plan, workout: workout, at: midday(index)) }
        }
        return log
    }

    private func benchSeason(
        changeGym: ((inout GymConfig) -> Void)? = nil, edit: ((inout Exercise) -> Void)? = nil
    ) throws -> [Workout] {
        try season(lift: bench(), firstSets: sets(10, 10, 9), changeGym: changeGym, edit: edit)
    }

    /// The issue's case. Written out, not computed, so it can't agree with a
    /// tidied season by being wrong the same way.
    private var untouchedBenchSeason: [Workout] {
        let confirm = ExerciseRecommendation.Reason.confirmEasyWorkouts(completed: 1, required: 2)
        return [
            Workout(action: .hold, reason: confirm, sets: sets(10, 10, 9), restSeconds: 180, plan: 0),
            Workout(action: .addReps, reason: .addedRep(set: 3), sets: sets(10, 10, 10), restSeconds: 180, plan: 1),
            Workout(action: .hold, reason: confirm, sets: sets(10, 10, 10), restSeconds: 180, plan: 1),
            Workout(action: .addReps, reason: .addedRep(set: 1), sets: sets(11, 10, 10), restSeconds: 180, plan: 2),
        ]
    }

    func testAnUntouchedSeasonIsTheOneTheIssueDescribes() throws {
        XCTAssertEqual(try benchSeason(), untouchedBenchSeason)
    }

    func testRenamingALiftKeepsItsSuggestionsAndItsPlan() throws {
        XCTAssertEqual(try benchSeason(edit: { $0.name = self.renamed }), untouchedBenchSeason)
    }

    func testSwitchingTheWarmupRampKeepsItsSuggestionsAndItsPlan() throws {
        XCTAssertEqual(try benchSeason(edit: { $0.needsWarmupRamp.toggle() }), untouchedBenchSeason)
    }

    /// A barbell is compound whatever its muscles, so the default rest cannot
    /// move with this edit.
    func testAMusclesEditThatKeepsTheDefaultRestKeepsItsSuggestionsAndItsPlan() throws {
        let tagged = try benchSeason(edit: {
            $0.muscles = [.primary(.chest), .secondary(.triceps), .secondary(.frontDelts)]
        })
        XCTAssertEqual(tagged, untouchedBenchSeason)

        // An accessory that gains a second muscle is still an accessory.
        let untouched = try season(lift: lateralRaise(), firstSets: sets(10, 10, 9, load: 20))
        let tidied = try season(lift: lateralRaise(), firstSets: sets(10, 10, 9, load: 20), edit: {
            $0.muscles = [.primary(.sideDelts), .secondary(.rearDelts)]
        })
        XCTAssertEqual(untouched.map(\.restSeconds), [60, 60, 60, 60], "control: an accessory rests 60")
        XCTAssertEqual(tidied, untouched)
    }

    func testSeveralEditsInARowStillKeepTheSeason() throws {
        let tidied = try benchSeason(edit: {
            $0.name = self.renamed
            $0.needsWarmupRamp = true
            $0.muscles = [.primary(.chest), .secondary(.triceps)]
        })
        XCTAssertEqual(tidied, untouchedBenchSeason)
    }

    // MARK: - A rest change is a different demand

    /// #341: a different rest is a different demand, so it is a new plan and
    /// the count of easy workouts restarts. These are the edits that must not
    /// be mistaken for tidying.
    private func assertRestChangeStartsANewPlan(
        _ season: [Workout], rest: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let confirm = ExerciseRecommendation.Reason.confirmEasyWorkouts(completed: 1, required: 2)
        XCTAssertEqual(season.first?.restSeconds, rest, "the new rest is the plan's", file: file, line: line)
        XCTAssertEqual(season.first?.plan, 1, "a different rest is a new plan", file: file, line: line)
        XCTAssertEqual(season.first?.reason, confirm, "same suggestion at the seam", file: file, line: line)
        XCTAssertEqual(season.dropFirst().first?.reason, confirm,
                       "one session of evidence is lost, by design", file: file, line: line)
        XCTAssertEqual(season.dropFirst().first?.plan, 1, "and the new plan then repeats", file: file, line: line)
    }

    func testALiftsOwnRestStartsANewPlan() throws {
        let owned = try benchSeason(edit: { $0.restOverride = 150 })
        assertRestChangeStartsANewPlan(owned, rest: 150)
    }

    func testChangingTheDefaultRestStartsANewPlan() throws {
        let changed = try benchSeason(changeGym: { $0.restDefaults.compound = 150 })
        assertRestChangeStartsANewPlan(changed, rest: 150)
    }

    func testAMusclesEditThatMovesALiftBetweenCompoundAndAccessoryStartsANewPlan() throws {
        let promoted = try season(lift: lateralRaise(), firstSets: sets(10, 10, 9, load: 20), edit: {
            $0.muscles = [.primary(.sideDelts), .secondary(.frontDelts), .secondary(.rearDelts)]
        })
        assertRestChangeStartsANewPlan(promoted, rest: 180)
    }

    /// A rename alongside a rest change is still a rest change.
    func testARenameAlongsideARestChangeStillStartsANewPlan() throws {
        let both = try benchSeason(edit: { $0.name = self.renamed; $0.restOverride = 150 })
        assertRestChangeStartsANewPlan(both, rest: 150)
    }

    // MARK: - The apparatus and the rule still reset

    private struct ApparatusEdit {
        let label: String
        let edit: (inout Exercise) -> Void
    }

    private var apparatusEdits: [ApparatusEdit] {
        [
            ApparatusEdit(label: "equipment") { $0.equipment = .plateLoaded },
            ApparatusEdit(label: "increment") { $0.increment = LoadIncrement(pounds: 2.5) },
            ApparatusEdit(label: "loading") { $0.loading?.availablePlates = [45, 25, 10, 5, 2.5] },
            ApparatusEdit(label: "rule") { $0.progressionRule = .doubleProgression(range: RepRange(6, 10)) },
        ]
    }

    /// Everything a stale sheet might still hold: workout 0's plan, as it was
    /// saved, with the lift as it was then.
    private func firstWorkout(in store: TrainingStore, lift: Exercise) throws -> ExercisePlan {
        try store.upsert(lift)
        let workout = UUID()
        let plan = try store.acceptExercisePlan(
            ExercisePlan(exercise: try XCTUnwrap(store.exercise(id: lift.id)), sets: sets(10, 10, 9),
                         restSeconds: 180),
            workoutID: workout, startedAt: midday(0), now: midday(0))
        try perform(store, plan, workout: workout, at: midday(0))
        return plan
    }

    func testChangingTheApparatusOrTheRuleStillResetsTheSuggestion() throws {
        for change in apparatusEdits {
            let store = try TrainingStore.inMemory()
            let first = try firstWorkout(in: store, lift: bench())
            var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
            change.edit(&current)
            XCTAssertNotEqual(current, first.exercise, "\(change.label): the edit has to change the lift")
            XCTAssertFalse(current.isPlanCompatible(with: first.exercise),
                           "\(change.label): #346 settled that this is a different apparatus or rule")
            try store.upsert(current)

            let workout = UUID()
            let recommendation = try store.recommendation(
                for: current, excluding: workout, now: midday(1))
            XCTAssertEqual(recommendation.reason, .equipmentChanged, change.label)
            XCTAssertTrue(recommendation.sets.isEmpty, "\(change.label): no target to carry over")
            XCTAssertNil(try store.activateExerciseRecommendation(
                recommendation, workoutID: workout, startedAt: midday(1), now: midday(1)), change.label)
        }
    }

    func testChangingTheApparatusOrTheRuleStillRejectsAStaleProposal() throws {
        for change in apparatusEdits {
            let store = try TrainingStore.inMemory()
            let first = try firstWorkout(in: store, lift: bench())
            var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
            change.edit(&current)
            try store.upsert(current)

            // The sheet was opened on the lift as it was, and the edit landed
            // before Save. Its copy of the lift is a different apparatus now.
            let stale = ExercisePlan(exercise: first.exercise, sets: sets(10, 10, 10), restSeconds: 180)
            XCTAssertThrowsError(try store.acceptExercisePlan(
                stale, workoutID: UUID(), startedAt: midday(1), now: midday(1)), change.label) {
                XCTAssertEqual($0 as? PlanStoreError, .exerciseChanged, change.label)
            }
            // Dismiss on a deload proposal passes the stored plan, which is the
            // same stale copy.
            XCTAssertThrowsError(try store.acceptExercisePlan(
                first, workoutID: UUID(), startedAt: midday(1), now: midday(1)), change.label) {
                XCTAssertEqual($0 as? PlanStoreError, .exerciseChanged, change.label)
            }
            XCTAssertEqual(try store.exerciseSessions().count, 1,
                           "\(change.label): a rejected proposal saves nothing")
        }
    }

    /// A plan the lifter does set after changing the apparatus is a new plan,
    /// even when its sets are the old ones: the old plan was written for
    /// something else.
    func testAPlanSetAfterAnApparatusChangeIsANewPlanEvenWithTheSameSets() throws {
        for change in apparatusEdits {
            let store = try TrainingStore.inMemory()
            let first = try firstWorkout(in: store, lift: bench())
            var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
            change.edit(&current)
            try store.upsert(current)
            let stored = try XCTUnwrap(store.exercise(id: current.id))

            let accepted = try store.acceptExercisePlan(
                ExercisePlan(exercise: stored, sets: first.sets, restSeconds: first.restSeconds),
                workoutID: UUID(), startedAt: midday(1), now: midday(1))
            XCTAssertNotEqual(accepted.id, first.id, change.label)
            XCTAssertEqual(accepted.exercise, stored, "\(change.label): and it carries the lift as it is")
        }
    }

    // MARK: - Use

    /// "Use Plan" on the suggestion after a rename: the plan the view builds
    /// is the suggestion's sets on the lift as it is now.
    func testUsingTheSuggestionAfterARenameKeepsThePlan() throws {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        current.name = renamed
        try store.upsert(current)

        let workout = UUID()
        let suggestion = try store.recommendation(for: current, excluding: workout, now: midday(1))
        XCTAssertEqual(suggestion.sets, first.sets, "control: a hold repeats the plan")
        let used = try store.acceptExercisePlan(
            ExercisePlan(exercise: current, sets: suggestion.sets, restSeconds: 180),
            workoutID: workout, startedAt: midday(1), displayedRecommendation: suggestion, now: midday(1))

        XCTAssertEqual(used.id, first.id)
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: current.id)?.plan?.id, first.id)
    }

    // MARK: - Edit set plan

    /// What the plan sheet saves: the plan it was opened on, with the sets
    /// the lifter set. It keeps the opened plan's copy of the lift.
    private func sheetSave(_ opened: ExercisePlan, sets: [PlannedWorkingSet]) -> ExercisePlan {
        ExercisePlan(id: opened.id, exercise: opened.exercise, sets: sets, restSeconds: opened.restSeconds,
                     techniqueRevision: opened.techniqueRevision, isDeload: opened.isDeload)
    }

    /// The plan the sheet opens on, the way `SessionViewModel.planProposal`
    /// finds it: the session's accepted plan.
    private func openedPlan(_ lift: Exercise, workout: UUID, at start: Date) throws -> ExercisePlan {
        try XCTUnwrap(store.sessionExercise(
            for: lift, slot: nil, startedAt: start, workoutID: workout).acceptedPlan)
    }

    /// The activated plan outlives the rename here: it is the previous plan,
    /// kept whole with its copy of the lift. Saving an edit to it must work,
    /// and the edited plan must carry the lift as it is, never the copy it was
    /// opened on.
    func testEditSetPlanSavesOnAPlanKeptAcrossARename() throws {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        current.name = renamed
        try store.upsert(current)

        let workout = UUID()
        let suggestion = try store.recommendation(for: current, excluding: workout, now: midday(1))
        let activated = try XCTUnwrap(try store.activateExerciseRecommendation(
            suggestion, workoutID: workout, startedAt: midday(1), now: midday(1)))
        XCTAssertEqual(activated.id, first.id, "control: the plan is the one kept across the rename")

        let opened = try openedPlan(current, workout: workout, at: midday(1))
        let edited = sets(10, 10, 10)
        let saved = try store.acceptExercisePlan(
            sheetSave(opened, sets: edited), workoutID: workout, startedAt: midday(1),
            displayedRecommendation: suggestion, now: midday(1))

        XCTAssertEqual(saved.sets, edited)
        XCTAssertNotEqual(saved.id, first.id, "an edited plan is a new plan")
        XCTAssertEqual(saved.exercise, current, "and it carries the lift as it is now")
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: current.id)?.plan, saved)
        XCTAssertEqual(try store.exercise(id: current.id), current, "the lift itself is untouched")

        // Save with nothing changed keeps the plan it opened on.
        let reopened = try openedPlan(current, workout: workout, at: midday(1))
        let unchanged = try store.acceptExercisePlan(
            sheetSave(reopened, sets: edited), workoutID: workout, startedAt: midday(1), now: midday(1))
        XCTAssertEqual(unchanged, saved)
    }

    /// The same sheet, opened before the lift was tidied (a lift's settings
    /// are reachable from the workout): Save still works.
    func testEditSetPlanSavesWhenTheLiftWasTidiedAfterTheSheetOpened() throws {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))

        let workout = UUID()
        let suggestion = try store.recommendation(for: current, excluding: workout, now: midday(1))
        _ = try store.activateExerciseRecommendation(
            suggestion, workoutID: workout, startedAt: midday(1), now: midday(1))
        let opened = try openedPlan(current, workout: workout, at: midday(1))

        current.name = renamed
        current.needsWarmupRamp = true
        current.muscles = [.primary(.chest), .secondary(.triceps)]
        current.restOverride = 120
        try store.upsert(current)

        let edited = sets(10, 10, 10)
        let saved = try store.acceptExercisePlan(
            sheetSave(opened, sets: edited), workoutID: workout, startedAt: midday(1),
            displayedRecommendation: suggestion, now: midday(1))
        XCTAssertEqual(saved.sets, edited)
        XCTAssertEqual(saved.exercise, current, "the plan carries the lift as it is now")
        XCTAssertEqual(try store.exercise(id: current.id), current)
    }

    // MARK: - Dismiss on a deload proposal

    private struct Dismissal {
        let first: ExercisePlan
        let proposal: ExerciseRecommendation
        let restored: ExercisePlan
        let workout: UUID
    }

    /// Workout 0 is an accepted plan, easy; then the lift is tidied; then the
    /// scheduled week-4 deload is proposed and the lifter taps Dismiss, which
    /// hands `acceptExercisePlan` the plan `latestNonDeloadExercisePlan`
    /// returns, along with the proposal, as `dismissRecoveryProposal` does.
    private func dismissDeload(afterEditing edit: (inout Exercise) -> Void) throws -> Dismissal {
        let store = try TrainingStore.inMemory()
        let first = try firstWorkout(in: store, lift: bench())
        var config = try store.gymConfig()
        config.trainingBlock = TrainingBlockConfig(
            startedAt: midday(0).addingTimeInterval(-21 * 86_400), accumulationWeeks: 3)
        try store.saveGymConfig(config)

        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        edit(&current)
        try store.upsert(current)

        let workout = UUID()
        let proposal = try store.recommendation(for: current, excluding: workout, now: midday(1))
        XCTAssertEqual(proposal.action, .deload)
        XCTAssertEqual(proposal.reason, .scheduledDeload(week: 4))
        let fallback = try XCTUnwrap(try store.latestNonDeloadExercisePlan(for: current.id, excluding: workout))
        let restored = try store.acceptExercisePlan(
            fallback, workoutID: workout, startedAt: midday(1),
            displayedRecommendation: proposal, now: midday(1))
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: current.id)?.plan, restored)
        return Dismissal(first: first, proposal: proposal, restored: restored, workout: workout)
    }

    func testDismissingADeloadWithNoEditRestoresThePreviousPlan() throws {
        let dismissal = try dismissDeload(afterEditing: { _ in })
        XCTAssertEqual(dismissal.restored.id, dismissal.first.id)
        XCTAssertEqual(dismissal.restored.sets, sets(10, 10, 9))
        XCTAssertFalse(dismissal.restored.isDeload)
    }

    func testDismissingADeloadAfterAHarmlessEditRestoresThePreviousPlan() throws {
        let edits: [(String, (inout Exercise) -> Void)] = [
            ("rename", { $0.name = self.renamed }),
            ("warmup ramp", { $0.needsWarmupRamp.toggle() }),
            ("muscles", { $0.muscles = [.primary(.chest), .secondary(.triceps), .secondary(.frontDelts)] }),
            ("own rest", { $0.restOverride = 150 }),
        ]
        for (label, edit) in edits {
            let dismissal = try dismissDeload(afterEditing: edit)
            XCTAssertEqual(dismissal.restored.id, dismissal.first.id, label)
            XCTAssertEqual(dismissal.restored.sets, sets(10, 10, 9), label)
            XCTAssertEqual(dismissal.restored.restSeconds, 180,
                           "\(label): Dismiss restores the plan that was, rest and all")
            XCTAssertFalse(dismissal.restored.isDeload, label)
        }
    }

    // MARK: - What the kept copy of the lift can reach

    /// A kept plan goes on carrying the lift as it was. That is the point:
    /// `RecommendationEngine` compares whole plans across workouts, so a fresh
    /// copy would read every older workout as a different plan. These are the
    /// places that copy could have leaked from.
    func testTheKeptCopyOfTheLiftIsNotWhatTheLifterSeesOrWhatIsSaved() throws {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        current.name = renamed
        current.needsWarmupRamp = true
        try store.upsert(current)

        let workout = UUID()
        let suggestion = try store.recommendation(for: current, excluding: workout, now: midday(1))
        let activated = try XCTUnwrap(try store.activateExerciseRecommendation(
            suggestion, workoutID: workout, startedAt: midday(1), now: midday(1)))
        XCTAssertEqual(activated, first, "the plan is kept as it was, copy of the lift included")
        XCTAssertEqual(activated.exercise.name, "Bench", "which is why nothing may read a name from it")

        // What the session screen is built from.
        let loaded = try store.sessionExercise(for: current, slot: nil, startedAt: midday(1), workoutID: workout)
        XCTAssertEqual(loaded.exercise.name, renamed)
        XCTAssertEqual(loaded.exercise.needsWarmupRamp, true)
        XCTAssertEqual(loaded.acceptedPlan?.id, first.id)
        // Its target is the plan's sets, which a kept copy cannot change.
        XCTAssertEqual(loaded.prescription.reps, 10)

        // Saved back from the sheet with a set changed, and the lift in the library is still as it was edited.
        let opened = try XCTUnwrap(loaded.acceptedPlan)
        _ = try store.acceptExercisePlan(
            sheetSave(opened, sets: sets(10, 10, 10)), workoutID: workout, startedAt: midday(1), now: midday(1))
        XCTAssertEqual(try store.exercise(id: current.id), current)
        XCTAssertEqual(try store.exercises().filter { $0.id == current.id }.count, 1)
    }

    /// `sameProposal` and the trace both read the plan's id, not its copy.
    func testTheTraceOfAKeptPlanStillDescribesTheProposalItWasActivatedFrom() throws {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        current.name = renamed
        try store.upsert(current)

        let workout = UUID()
        let suggestion = try store.recommendation(for: current, excluding: workout, now: midday(1))
        XCTAssertEqual(suggestion.basedOnPlanID, first.id)
        let activated = try XCTUnwrap(try store.activateExerciseRecommendation(
            suggestion, workoutID: workout, startedAt: midday(1), now: midday(1)))

        let session = try XCTUnwrap(try store.exerciseSession(workoutID: workout, exerciseID: current.id))
        let trace = try XCTUnwrap(session.recommendationTrace)
        XCTAssertEqual(trace.decision, .automaticallyActivated)
        XCTAssertEqual(trace.displayedRecommendation, suggestion)
        XCTAssertEqual(trace.displayedRecommendation?.basedOnPlanID, activated.id,
                       "the proposal was based on the plan it activated")

        // Reviewing the same proposal afterwards is not a stale one.
        XCTAssertNoThrow(try store.acceptExercisePlan(
            sheetSave(activated, sets: activated.sets), workoutID: workout, startedAt: midday(1),
            displayedRecommendation: suggestion, now: midday(1)))
        let report = try store.recommendationFeedbackReport(now: midday(2))
        XCTAssertEqual(report.automaticActivations, 1)
    }

    // MARK: - Identity still compares the rest of the plan

    /// A renamed lift whose plan from workout 0 is repeated by workout 1: the
    /// plan kept across the rename, which workout 2's proposal is compared
    /// with. Repeating it is the control for both tests below, so they cannot
    /// pass by the plan never being reusable in the first place.
    private func renamedLiftWithAKeptPlan() throws -> (lift: Exercise, first: ExercisePlan) {
        let first = try firstWorkout(in: store, lift: bench())
        var current = try XCTUnwrap(store.exercise(id: first.exercise.id))
        current.name = renamed
        try store.upsert(current)
        let repeated = try store.acceptExercisePlan(
            ExercisePlan(exercise: current, sets: first.sets, restSeconds: first.restSeconds),
            workoutID: UUID(), startedAt: midday(1), now: midday(1))
        XCTAssertEqual(repeated.id, first.id, "control: the same plan on the renamed lift is the plan kept")
        return (current, first)
    }

    /// Adjust on a recovery proposal, with the sets put back to the normal
    /// ones, is a deload with exactly the normal plan's sets. It is still a
    /// deload, and the plan it is compared with is not.
    func testADeloadWithThePlansExactSetsIsNotThePlanAfterARename() throws {
        let (current, first) = try renamedLiftWithAKeptPlan()

        let workout = UUID()
        let deload = try store.acceptExercisePlan(
            ExercisePlan(exercise: current, sets: first.sets, restSeconds: first.restSeconds, isDeload: true),
            workoutID: workout, startedAt: midday(2), now: midday(2))

        XCTAssertTrue(deload.isDeload)
        XCTAssertNotEqual(deload.id, first.id, "a deload is not the normal plan, whatever its sets")
        XCTAssertEqual(deload.sets, first.sets)
        XCTAssertEqual(deload.exercise, current, "a new plan carries the lift as it is now")
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: current.id)?.plan, deload)
        XCTAssertEqual(try store.latestNonDeloadExercisePlan(for: current.id, excluding: workout)?.id, first.id,
                       "and the normal plan it came from is still the one to resume")
    }

    /// A plan under another technique is a different comparison, so the
    /// evidence of the old one must not count toward it.
    func testAChangedTechniqueRevisionIsNotThePlanAfterARename() throws {
        let (current, first) = try renamedLiftWithAKeptPlan()

        let workout = UUID()
        let revised = try store.acceptExercisePlan(
            ExercisePlan(exercise: current, sets: first.sets, restSeconds: first.restSeconds,
                         techniqueRevision: "paused reps"),
            workoutID: workout, startedAt: midday(2), now: midday(2))

        XCTAssertEqual(revised.techniqueRevision, "paused reps")
        XCTAssertNotEqual(revised.id, first.id, "a changed technique is not the plan kept, whatever its sets")
        XCTAssertEqual(revised.sets, first.sets)
        XCTAssertEqual(revised.exercise, current, "a new plan carries the lift as it is now")
        XCTAssertEqual(try store.exerciseSession(workoutID: workout, exerciseID: current.id)?.plan, revised)
    }
}
