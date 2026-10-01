# Recommendation engine implementation

This work begins the [recommendation engine plan](recommendation-engine-plan.md) in an isolated worktree on `feat/recommendation-engine`, based on the locally available `origin/main` commit `43f4714`.

## Current status: automatic workout prescriptions

The phased plan was revised on 2026-09-27 to make recommendations part of normal
workout logging with minimal configuration. An eligible recommendation now
becomes the active prescription when its exercise enters the normal workout.
The exact displayed proposal is stored before the first working set; Review set
plan remains an optional editor. Workout preparation now evaluates the final
roster together before any exercise activates.

The review of commit `3d07d6d` found seven gaps: incomplete volume projections,
pain bypass during legacy initialization, incomparable adaptive-fatigue evidence,
recovery exit when blocks are disabled, stale RPE provenance/coverage after edits,
Live Activity targets that did not advance per set, and proposal traces recomputed
instead of captured from the displayed recommendation. These defects are fixed
and covered by regressions. The automatic, low-friction workout flow is now
implemented. Physical-phone validation and real outcome collection remain.

The sections below describe existing components and their intended behavior. The revised
[phase completion criteria](recommendation-engine-plan.md#delivery-and-evaluation)
are authoritative. Correctness and normal-workout integration come before
collecting outcomes for threshold tuning. Recommendation results in Settings is
an evaluation surface, never a prerequisite for obtaining recommendations.

Implemented in `WeightTrainingCore`:

- `ExercisePlan`: an accepted prescription with individual working-set targets and an exercise configuration snapshot. Its ID is the prescription revision; repeat it across workouts until the user accepts a change.
- `ExerciseExposure`: one explicitly identified exercise/session, its actual ordered sets, the accepted plan, completion reason, and optional technique-change report. Workout identity is independent of calendar dates.
- `ExposureSet`: records whether effort was explicitly reported. Existing or prefilled RPE values must enter as `unknown` unless their provenance is known.
- `RecommendationEngine`: a pure function returning one explained recommendation, evidence status, supporting exposure IDs, and a rule version. Repeated reads do not consume evidence.
- `RecommendationPolicy`: configurable rep range, repeated-workout threshold, RPE slack, maximum load increase, and history freshness.

The policy increases one total rep after two consecutive easy workouts on the same accepted plan. At the rep ceiling it proposes the next achievable load within the configured increase limit and resets reps. It holds for missing effort, interrupted workouts, unexpectedly difficult sets, stale history, changed execution, and coarse equipment increments. It can suggest a local load reduction after two comparable full workouts miss the rep floor. Recorded pain takes precedence for both planned and legacy/no-plan history. An accepted deload blocks increases, and deload history cannot earn progression after resuming.

The policy supports straight sets with external loads and unassisted bodyweight
sets. Bodyweight progression preserves the recorded total load, adds reps after
the same repeated-easy evidence used by loaded movements, and can add one
budgeted set at the rep ceiling; it never invents a bodyweight change or load
reduction. Assisted movements, unmeasured plate-built equipment, bodyweight
variations, and mixed top/back-off prescriptions require explicit domain models
before support. An unavailable reduction returns a hold with an explanation
rather than forcing a large equipment step.

Historical duplicates are collapsed by exposure ID only when identical. Conflicting duplicates or reused working-set IDs prevent progression. Actual records remain the source of truth: rebuilding exposures after a correction or deletion recomputes the recommendation.

## App and persistence integration

The workout displays the recommendation directly in its normal load, reps, and
RPE controls. Entering an eligible exercise stores that exact proposal as an
automatically activated prescription; the first working-set boundary verifies
activation again before writing. **Review set plan** remains available to inspect
or change set count, achievable load, per-set reps, and target RPE. The screen
advances through per-set targets and still permits direct edits, early stops, or
extra work.

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
workout. Correcting an RPE establishes explicit provenance, removing it withdraws
that evidence, and edits to other fields preserve the existing provenance.

The legacy progression engine remains active only for exercises that have never
adopted an accepted plan. Planned exercises use the new engine for next-workout
targets, while the in-session path retains only a conservative downward response
to explicitly reported high effort.

Recent pre-plan history now supplies a reviewable starting baseline instead of
an empty recommendation. The baseline repeats the most recent workout using the
lightest load from that workout, snaps it to available equipment, preserves up
to eight set-by-set rep counts inside the exercise's configured range, and uses
the exercise's target RPE. It expires after 21 days. Because legacy logs do not
prove that an accepted plan was completed or that effort was easy, this action
can only establish a plan; it never earns a rep, load, or set increase.

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
secondary muscle would exceed its personalized maximum. The allocator validates
the complete candidate prescription and retains remaining accepted work for
sibling exercises in the same workout. Completed and accepted remaining work
both count. The recommendation automatically becomes the active prescription
when the lifter reaches that exercise and remains editable before the first set.

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
two exercises at the same load, reps, sets, rest, equipment, and technique;
time pressure, pain, increased work, duplicate evidence, wearable data, or one
struggling movement do not become whole-program fatigue. Recovery reduces the
accepted workload rather than an unaccepted progression proposal. A recovery
proposal must be accepted, and the next build week—or disabling blocks—offers
the last non-deload plan again so the reduced plan does not become permanent.

Automatic activation and explicit set-plan review both carry the displayed
proposal into persistence, verify that its decision inputs and outputs are still
current, and retain that exact snapshot. Automatic activation, acceptance, edits,
completion, and reported effort remain separate facts. **Settings → Recommendation
results** derives a rolling 28-day report from current logs: automatic targets,
reviewed plans, edits, exact-plan completion, RPE coverage, and sets above target effort. It
stores no mutable success counters, so correcting or deleting a set updates the
report. Older history remains valid but is not retroactively labeled as a
reviewed recommendation.

The same screen lists each recent reviewed exercise with its proposed action,
accept/edit decision, completion outcome, and RPE coverage. This makes a real
workout auditable without treating plan acceptance as a successful outcome.

Automatic and explicitly reviewed prescriptions now have separate completion,
RPE coverage, below-target-effort, and above-target-effort totals. The results
screen also groups saved hold reasons, so missing RPE, incomplete work, high
effort, equipment limits, and the repeat-easy gate can be evaluated separately.
Legacy traces without a displayed recommendation keep their reason unknown.
These values are derived from corrected logs and stored proposal snapshots;
they do not create mutable scores or require another user step.

Recommendation reads now create one request-scoped history snapshot and index
sets by exercise and workout. Workout coordination, exposure reports, and
feedback reuse that snapshot instead of repeatedly scanning or fetching the
same rows. It is rebuilt on every public request, so corrections and deletions
refresh unstarted advice while an already active prescription stays frozen.
Equivalence tests retain the previous batch implementation as a test-only oracle
and compare every recommendation over canonical and edge-case histories.

Live Activity logging advances through different per-set targets, undo restores
the prior target, and foreground reconciliation reloads persisted plan state
before publishing. Touch and voice share the same activate-before-log boundary.
Workout-wide allocation reserves every unopened sibling prescription, primary
and secondary muscle credit, and other represented active/upcoming work before
selecting at most one deterministic add-set winner. Repeated reads remain pure;
persisting the winning prescription consumes that allocation period.

Recovery remains an explicit exception to automatic activation. A recovery card
offers Use, Adjust, and Dismiss; dismissal persists the prior normal prescription.
The Log action and Live Activity stay unavailable until that decision is stored.
The remaining work is physical-phone validation and outcome collection before
tuning thresholds. Users never need to visit Recommendation results to receive targets.

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

Physical-device hands-on validation remains required for the integrated workout flow.

Validation after the history-indexing and outcome-integrity milestone on 2026-09-28:

| Check | Result |
|---|---|
| Swift domain/store suite, including automatic activation, workout-wide allocation, review regressions, conservative legacy baselines, personalized bands, explicit recovery decisions, deload entry/exit, automatic/reviewed outcome cohorts, hold-reason derivation, history equivalence, correction/relaunch integrity, and sync constraints (798 tests) | PASS |
| Repository scenario script, including overlapping muscle budgets and 12-week block replay (15 scenarios) | PASS |
| Foundation-only core check | PASS |
| Two-year synthetic history equivalence (312 workouts, 1,872 exercise sessions, 7,386 sets) | PASS — identical decisions; shared exposure read about 6× faster in the measured local run |
| App and widget build for iOS Simulator | PASS |
| UI-test target compilation, including stable target/results accessibility identifiers | PASS |
| Focused iPhone UI through the early-completion milestone | PASS |
| Signed iPhone build | PASS |
| Install of the workout-wide allocation and recovery-choice milestone over existing phone data | PASS |
| Read-only replay against the phone's 101-set history | PASS — T-Bar Row now receives an 80 lb × 12, 12 baseline; Incline DB Press holds for missing RPE |
| Physical-device hands-on volume and recommendation review | PENDING |

Build products used a separate temporary derived-data directory. A remote fetch
encountered the pre-existing malformed ref `refs/remotes/origin/fix/session-presentation 2`;
the worktree was fast-forwarded to the available `origin/main` commit instead of
changing shared repository metadata. Remote freshness beyond that commit was not verified.
