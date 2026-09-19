# Recommendation engine implementation

This work begins the [recommendation engine plan](recommendation-engine-plan.md) in an isolated worktree on `feat/recommendation-engine`, based on the locally available `origin/main` commit `43f4714`.

## Current milestone: accepted plans, live logging, and persisted evidence

Implemented in `WeightTrainingCore`:

- `ExercisePlan`: an accepted prescription with individual working-set targets and an exercise configuration snapshot. Its ID is the prescription revision; repeat it across workouts until the user accepts a change.
- `ExerciseExposure`: one explicitly identified exercise/session, its actual ordered sets, the accepted plan, completion reason, and optional technique-change report. Workout identity is independent of calendar dates.
- `ExposureSet`: records whether effort was explicitly reported. Existing or prefilled RPE values must enter as `unknown` unless their provenance is known.
- `RecommendationEngine`: a pure function returning one explained recommendation, evidence status, supporting exposure IDs, and a rule version. Repeated reads do not consume evidence.
- `RecommendationPolicy`: configurable rep range, repeated-workout threshold, RPE slack, maximum load increase, and history freshness.

The policy increases one total rep after two consecutive easy workouts on the same accepted plan. At the rep ceiling it proposes the next achievable load within the configured increase limit and resets reps. It holds for missing effort, interrupted workouts, unexpectedly difficult sets, stale history, changed execution, and coarse equipment increments. It can suggest a local load reduction after two comparable full workouts miss the rep floor. Pain suspends progression; an accepted deload blocks increases, and deload history cannot earn progression after resuming.

The policy is currently for straight sets with external loads. Bodyweight, assistance, unmeasured plate-built equipment, and mixed top/back-off prescriptions require explicit policies before support. An unavailable reduction returns a hold with an explanation rather than forcing a large equipment step.

Historical duplicates are collapsed by exposure ID only when identical. Conflicting duplicates or reused working-set IDs prevent progression. Actual records remain the source of truth: rebuilding exposures after a correction or deletion recomputes the recommendation.

## App and persistence integration

The workout now exposes a **Review set plan** action before the first working
set. The editor lets the lifter review or change the set count, achievable load,
per-set reps, and target RPE. Accepting it records user intent; no recommendation
changes a workout automatically. The screen advances through the accepted
per-set targets and still permits early stops or extra work.

`StoredExerciseSession` persists one plan/completion record per exercise and
workout. `SetRecord` carries optional workout, plan-revision, and reported-effort
provenance. All new CloudKit fields are optional or defaulted. Archive version 2
includes exercise sessions while version-1 backups remain readable.

Actual sets remain the source of truth. Exposures are rebuilt from current set
rows, so correction, deletion, restore, and deduplication immediately change the
recommendation. Equal-time plan conflicts become unknown rather than choosing an
arbitrary success. Older duplicate sets and backups cannot erase newer known
workout or effort provenance.

RPE targets are displayed but never stored as actual effort until the lifter
selects an RPE or speaks one. Live Activity logging records weight and reps with
unknown effort. This prevents a one-tap target log from manufacturing an “easy”
workout.

The legacy progression engine remains active only for exercises that have never
adopted an accepted plan. Planned exercises use the new engine for next-workout
targets, while the in-session path retains only a conservative downward response
to explicitly reported high effort.

The remaining sequence is:

1. Add an explicit early-completion reason UI for time, fatigue, and pain. The
   store and domain values already support these states; Finish currently marks
   exact plan-count completion and leaves other outcomes unknown.
2. Extend muscle-volume reporting with reported/unknown effort, distinct exercise
   counts, personalized budgets, and remaining planned work. Add weekly set
   allocation only after these inputs exist.
3. Add optional tonnage/block targets and scheduled/adaptive deload coordination.
   The current core respects an accepted deload but does not create a whole-program
   schedule or infer fatigue from wearable scores.

## Calling convention

```swift
let recommendation = RecommendationEngine.recommend(
    exercise: exercise,
    plan: acceptedPlan,
    history: exposuresRebuiltFromCurrentLogs,
    policy: RecommendationPolicy(repRange: RepRange(8, 12)),
    context: RecommendationContext(recovery: .unknown),
    now: evaluationDate
)
```

Supply a stable `now` for replays. Construct a new `ExercisePlan` only when the user accepts a changed prescription or deliberately starts a new comparison baseline. Preserve the ID when repeating a prescription. Keep exercise identity specific to the apparatus/variant; context changes such as materially different rest or technique belong in the plan.

## Verification

The new unit coverage includes repeated-easy gates, hardest-set effort, planned completion, missing/provenance-unknown effort, equipment rounding, kg loads, stale history, rest/technique changes, duplicate and corrected logs, explicit session identity, deload boundaries, and local load resets.

The new replay scenarios feed recommendations back into subsequent workouts. They cover steady progression, an effort-limited plateau, alternating missing effort, and repeated misses followed by rebuilding. These simulations verify behavior; they do not establish physiological effectiveness.

Run the repository ladder from this worktree:

```sh
swift test
sh hooks/run-evals.sh
sh hooks/check-core-purity.sh
xcodebuild -project ChickenBreast/ChickenBreast.xcodeproj \
  -scheme ChickenBreast -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Physical-device validation remains required for the integrated workout flow.

Validation for the integrated milestone on 2026-09-18:

| Check | Result |
|---|---|
| Swift domain/store suite, including persistence and sync conflicts (710 tests) | PASS |
| Repository scenario script, including new recommendation replays | PASS |
| Foundation-only core check | PASS |
| App and widget build for iOS Simulator | PASS |
| Focused iPhone UI: plan review/acceptance and explicit RPE selection | PASS |
| Physical device | NOT RUN |

Build products used a separate temporary derived-data directory. A remote fetch
encountered the pre-existing malformed ref `refs/remotes/origin/fix/session-presentation 2`;
the worktree was fast-forwarded to the available `origin/main` commit instead of
changing shared repository metadata. Remote freshness beyond that commit was not verified.
