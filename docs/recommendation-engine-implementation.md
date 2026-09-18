# Recommendation engine implementation

This work begins the [recommendation engine plan](recommendation-engine-plan.md) in an isolated worktree on `feat/recommendation-engine`, based on the locally available `origin/main` commit `43f4714`.

## Current milestone: core policy and replay tests

Implemented in `WeightTrainingCore`:

- `ExercisePlan`: an accepted prescription with individual working-set targets and an exercise configuration snapshot. Its ID is the prescription revision; repeat it across workouts until the user accepts a change.
- `ExerciseExposure`: one explicitly identified exercise/session, its actual ordered sets, the accepted plan, completion reason, and optional technique-change report. Workout identity is independent of calendar dates.
- `ExposureSet`: records whether effort was explicitly reported. Existing or prefilled RPE values must enter as `unknown` unless their provenance is known.
- `RecommendationEngine`: a pure function returning one explained recommendation, evidence status, supporting exposure IDs, and a rule version. Repeated reads do not consume evidence.
- `RecommendationPolicy`: configurable rep range, repeated-workout threshold, RPE slack, maximum load increase, and history freshness.

The policy increases one total rep after two consecutive easy workouts on the same accepted plan. At the rep ceiling it proposes the next achievable load within the configured increase limit and resets reps. It holds for missing effort, interrupted workouts, unexpectedly difficult sets, stale history, changed execution, and coarse equipment increments. It can suggest a local load reduction after two comparable full workouts miss the rep floor. Pain suspends progression; an accepted deload blocks increases, and deload history cannot earn progression after resuming.

The policy is currently for straight sets with external loads. Bodyweight, assistance, unmeasured plate-built equipment, and mixed top/back-off prescriptions require explicit policies before support. An unavailable reduction returns a hold with an explanation rather than forcing a large equipment step.

Historical duplicates are collapsed by exposure ID only when identical. Conflicting duplicates or reused working-set IDs prevent progression. Actual records remain the source of truth: rebuilding exposures after a correction or deletion recomputes the recommendation.

## Integration boundary

This milestone does **not** replace `ProgressionEngine` or `SuggestionEngine` on the live workout screen. The current app does not yet persist accepted set plans or trustworthy effort provenance, and treating old logs as if it did would manufacture progression evidence.

No existing stored model or archive schema has changed. The new Codable values are domain inputs, not a new persistence system. When integrating the store, retain the accepted prescription as historical user intent and rebuild exposure sets from current `SetRecord` rows. Do not persist duplicate mutable workout totals.

The integration sequence is:

1. Persist accepted plan revisions and their session associations, with CloudKit-compatible optional/defaulted fields. Keep legacy completion and effort provenance unknown.
2. Let the user review advisory set targets, record an explicit effort selection, and finish or shorten an exercise without being forced to complete the plan.
3. Route both next-workout prescriptions and in-session progression suggestions through this policy. Immediate responses to unexpectedly hard work need their own consistent downward-adjustment path.
4. Extend the existing muscle-volume report with reported/unknown effort, exercise counts, personalized budgets, and remaining planned work. Add weekly set allocation only after these inputs exist.
5. Add optional tonnage/block targets and scheduled/adaptive deload coordination. This core currently respects an accepted deload; it does not create whole-program deload schedules or infer fatigue from wearable scores.

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

Device validation is still required when the store and workout screen are integrated.

Validation for this milestone on 2026-09-17:

| Check | Result |
|---|---|
| Swift domain/store suite, including new recommendation tests | PASS |
| Repository scenario script, including new recommendation replays | PASS |
| Foundation-only core check | PASS |
| App and widget build for iOS Simulator | PASS |
| Physical device | NOT RUN — the new policy is not yet connected to the workout screen |

Build products used a separate temporary derived-data directory. A remote fetch
encountered the pre-existing malformed ref `refs/remotes/origin/fix/session-presentation 2`;
the worktree was fast-forwarded to the available `origin/main` commit instead of
changing shared repository metadata. Remote freshness beyond that commit was not verified.
