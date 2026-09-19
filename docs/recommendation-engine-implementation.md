# Recommendation engine implementation

This work begins the [recommendation engine plan](recommendation-engine-plan.md) in an isolated worktree on `feat/recommendation-engine`, based on the locally available `origin/main` commit `43f4714`.

## Current milestone: personalized volume and training blocks

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

The trailing volume report now separates completed working sets, known hard
sets, unknown-effort sets, direct and secondary credit, distinct exercises,
session frequency, and remaining sets from accepted active plans. Per-muscle
weekly bands are stored with the synced gym configuration and can be edited in
Settings under **Muscle volume**. Existing configuration rows decode to the
default bands.

Once ordinary repeated-easy progression reaches the top of the rep range and
the next achievable weight is unavailable or exceeds the load-increase limit,
the weekly allocator may suggest one additional set. It requires consistent
evidence, keeps the exercise below eight planned sets, requires a primary muscle
to remain below its weekly minimum, and rejects the increase if any primary or
secondary muscle would exceed its personalized maximum. Completed and accepted
remaining work both count. The recommendation stays advisory and is persisted
only if the lifter accepts it.

Finishing a workout with unstarted exercises or an accepted plan that still has
sets remaining now asks for a lightweight completion reason. Time and fatigue
apply to every accepted plan left incomplete. Pain applies only to the exercise
currently on screen and pauses that movement's progression; it does not taint
unrelated exercises. Completed plans remain completed, and finishing after all
planned work remains a single tap. The reason sheet remains reachable in
portrait, landscape, and accessibility text sizes.

Settings now offers optional starting set bands after two or three consecutive
calendar weeks were completed as planned, with every working-set RPE reported at
or below its target. A blank, incomplete, time-limited, painful, fatiguing, or
unscored week prevents the inference. The suggestion changes only the editor's
draft; the lifter must still press Save.

An optional synced training block derives its phase from the chosen start date.
It uses two or three consecutive, comparable tolerated weeks to calculate median
baseline tonnage, then shows a configurable 5–10% build target and 70–80%
recovery target. The recovery week proposes roughly one-third fewer working sets
at RPE 7. An adaptive recovery proposal requires repeated fatigue across at least
two exercises; time pressure, pain, wearable data, or one struggling movement do
not become whole-program fatigue. A recovery proposal must be accepted, and the
next build week offers the last non-deload plan again so the reduced plan does
not become permanent.

The next evaluation step is physical-device review with real history, followed
by shadow comparison of recommendations and user overrides before tuning any
thresholds.

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

The replay scenarios feed recommendations back into subsequent workouts. They
cover steady progression, an effort-limited plateau, alternating missing effort,
repeated misses followed by rebuilding, twelve calendar weeks of scheduled
recovery, deload boundaries, and time pressure that must not be misclassified as
program fatigue. These simulations verify behavior; they do not establish
physiological effectiveness.

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

Validation through the training-block milestone on 2026-09-19:

| Check | Result |
|---|---|
| Swift domain/store suite, including personalized bands, block persistence, baseline derivation, deload entry/exit, and sync constraints (742 tests) | PASS |
| Repository scenario script, including overlapping muscle budgets and 12-week block replay (15 scenarios) | PASS |
| Foundation-only core check | PASS |
| App and widget build for iOS Simulator | PASS |
| Focused iPhone UI through the early-completion milestone | PASS |
| Signed iPhone build and install over existing app data | PASS |
| Physical-device hands-on volume and recommendation review | PENDING |

Build products used a separate temporary derived-data directory. A remote fetch
encountered the pre-existing malformed ref `refs/remotes/origin/fix/session-presentation 2`;
the worktree was fast-forwarded to the available `origin/main` commit instead of
changing shared repository metadata. Remote freshness beyond that commit was not verified.
