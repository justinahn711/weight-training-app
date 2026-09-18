# Progressive overload recommendation engine

Status: proposed design; no application behavior changed.

Provisional audience: healthy adult recreational lifters seeking muscle growth with steady strength gains. Goal, experience, available equipment, exercise priorities, and training frequency are explicit configuration. Strength and general fitness can use different exercise prescriptions without replacing the decision pipeline.

## Product contract

For each exercise, recommend an achievable load, reps for each working set, a suggested set count, target RPE, and a short explanation grounded in actual history. The lifter accepts, edits, or ignores the recommendation. Completing a set records what was actually performed.

Use a deterministic rule engine for v1. Every decision includes its rule version, supporting session identifiers, reason codes, and data limitations. Do not generate numerical prescriptions with an LLM.

The objective is repeatable improvement at an appropriate effort with manageable fatigue. Tonnage is a descriptive metric, not the quantity the engine must maximize.

## Evidence and product choices

- Both repetition progression and load progression produced adaptations in an eight-week trial of trained adults. This supports offering both routes; it does not validate the exact thresholds below. [Plotkin et al., 2022](https://pubmed.ncbi.nlm.nih.gov/36199287/)
- Use a resistance-training RPE scale tied to repetitions in reserve: RPE 10 approximately means no reps remaining, 9 means one, 8 means two, and 7 means three. These are subjective estimates, not exact measurements or a generic session-effort scale. [Zourdos et al., 2016](https://pubmed.ncbi.nlm.nih.gov/26049792/)
- ACSM's 2026 guidance emphasizes individualized programming, consistency, goal-specific loading, and weekly volume. It does not prescribe universal monthly tonnage increases. [ACSM, 2026](https://acsm.org/resistance-training-guidelines-update-2026/)
- A deload every fourth week is an available program mode, not a universal requirement. Expert consensus supports tailoring deloads to the athlete and performance data, while acknowledging evidence gaps. Adaptation also occurs outside deload weeks. [Bell et al., 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10511399/)

All numerical decision thresholds below are configurable engineering defaults to evaluate with training histories and a qualified coach. They are not clinically validated prescriptions.

## Inputs and data model

| Entity | Required information | Why it matters |
|---|---|---|
| Training profile | Goal, experience, normal schedule, priority exercises | Selects progression policy and reasonable starting set targets |
| Exercise configuration | Stable exercise/variant ID, muscles and roles, equipment identity, load convention, achievable loads, rep range, target RPE | Prevents comparisons between different movements or machines |
| Planned exercise exposure | Session ID, ordered set targets, planned load/reps/RPE, accepted plan changes | Distinguishes completing the prescription from stopping early |
| Actual set | ID, session ID, exercise ID, set order, load, reps, optional RPE, warmup/work status, timestamp | Source of performance and volume calculations |
| Exercise completion | Completed, shortened for time, stopped for fatigue, stopped for pain, or unknown | A missed target is different from an interrupted workout |
| Optional context | Rest duration, technique/ROM consistency, pain flag, subjective recovery | Establishes comparability and constrains increases |
| Training block | Optional start/end, priority lifts, deload mode, baseline periods | Supports block review without making a calendar mandatory |

Do not prefill a target RPE as if the user reported it. Distinguish missing effort, reported effort, and any imported/defaulted values. Missing technique or recovery information is unknown, not confirmed good.

Keep logging lightweight: weight and reps remain the main inputs; use one optional RPE selection per working set and a brief completion reason only when the exercise ends early. Existing logs remain usable, but cannot retrospectively prove completion of an unrecorded plan.

## Derived metrics

Compute from corrected actual logs. Do not store mutable totals or duplicate counters as the source of truth.

```text
exercise total reps = sum(actual reps across working sets)
exercise working sets = count(actual working sets)
exercise volume load = sum(load_i × reps_i)
muscle set credit = sum(working-set contribution to that muscle)
exercise count per muscle = distinct qualifying exercise variants performed
```

For muscle set credit, report direct sets separately from secondary exposure. A primary contribution of 1 and a secondary contribution of 0.5 can retain the current app convention, but fractional credit is a bookkeeping approximation. It is not a measured biological dose and credits across different muscles are not additive whole-body sets.

Show total working sets, known RPE >= 7 sets, and sets with unknown RPE separately. The RPE threshold is a tracking convention; lower-effort work is not automatically worthless. Unknown effort must not make the workload disappear or become evidence that training was easy.

Compare volume load primarily within the same exercise, apparatus, load convention, and execution. The existing app records dumbbells per hand and barbells as total load. Keep that convention explicit; do not combine their raw values into an apparently comparable workload score. A future normalized total needs explicit limb/repetition semantics. Assisted exercises need their own progression direction; more assistance is less difficulty. Bodyweight variations need exercise-specific accounting.

Muscle summaries include sets, exercise count, exposure frequency, and trend. More exercise variety is not automatically more stimulus. Three exercises with three sets each is nine direct sets before secondary contributions, not a multiplier applied to already summed sets.

Use rolling seven-day volume for current context and complete, non-overlapping periods for trends. On a drifting push/pull/legs schedule, also compare completed training cycles. Consider remaining planned sessions before proposing extra volume. Do not infer undertraining simply because the week is unfinished or a session was missed.

## Comparing exercise exposures

An exposure is one performance of this exercise in a session. Use explicit session IDs going forward; calendar-day grouping cannot reliably distinguish two workouts in one day or a workout crossing midnight.

Compare the last two eligible exposures, with up to four to six recent exposures available for context. Eligibility requires the same variant/equipment, load convention, comparable working-set structure, and stable execution. Different exercises for the same muscle do not earn each other's progression streaks.

For the v1 straight-set policy, successful completion requires all planned sets and their respective rep targets. A heavier top set with lighter back-off sets is a separate policy; never apply the heaviest load to every set when judging success.

Changed load, set count, variant, or materially changed rest/ROM starts a new comparison segment. A missed prescription or missing RPE breaks the easy streak. An interrupted exposure provides volume history but does not count as successful progression evidence. A gap longer than the configured freshness window triggers re-establishment rather than an automatic increase; initially use 21 days as an adjustable product default.

## Decision rules

Provisional hypertrophy example: three working sets, an 8–12 rep range, target RPE 8. Preserve an existing tolerable routine rather than forcing this example on every lift. The set count is advisory and user-editable.

Define an easy exposure conservatively:

```text
all planned working sets completed
AND every set met its prescribed reps at the planned load
AND every working set has a reported RPE <= target RPE - 1
AND no reported pain or technique breakdown
AND no conflicting fatigue signal
```

Thus, with target RPE 8, all sets must be at RPE 7 or lower to bank an easy exposure. Use the hardest set as a guard; an average of 7 must not hide a final set at 9. This implements the requested repeated-easy-workout behavior. More permissive progression can be a later explicit policy.

Evaluate in this order, returning one primary action:

| Priority | Condition | Recommendation |
|---|---|---|
| 1 | Pain reported for this movement | Suspend its progression and suggest stopping that movement; do not infer a diagnosis |
| 2 | Active accepted deload | Follow the recovery prescription; block progression increases |
| 3 | Repeated comparable misses or worsening effort with declining performance | Propose reducing exercise demand; consider a broader deload only if the pattern is broader |
| 4 | Cold start, stale data, incomplete plan, or missing effort evidence | Establish/repeat a target; explain the specific missing evidence |
| 5 | Two consecutive easy exposures, all sets at rep ceiling | Add the smallest permitted equipment increment; reset reps toward the bottom of the range |
| 6 | Two consecutive easy exposures, room in rep range | Hold load and add one total rep across the exercise |
| 7 | Eligible weekly volume review | Consider adding one working set on one priority exercise, subject to all muscle budgets |
| 8 | Other cases | Repeat the current prescription |

After an accepted progression change, require new confirming exposures before another increase. Do not count repeatedly opening the recommendation as a new success.

Rep allocation: add the next rep to the lowest-target set that remains below the ceiling, resolving ties by earlier set order. For 10/10/9, propose 10/10/10; for 10/10/10, propose 11/10/10. Base increases on an achieved, accepted prescription, not a best set alone.

Load calculation: enumerate or request the next truly achievable load above the current load. Initially reject jumps above a configurable 5% limit. If the available step is too large, hold or offer microloading/a reviewed rep-range expansion; do not invent a weight. Even an allowed increase is provisional: suggest the lower end of the rep range and use the next session's actual effort to adjust. No exact reps-to-weight equivalence is assumed.

Revalidate the final load after equipment rounding: correct direction, within the increment cap, at least the minimum usable load, and actually available. A snapped value equal to the old weight is a hold, not an increase.

Change one demand variable at a time. A load increase with a compensating rep reset is one progression action. Never simultaneously raise load, reps, and set count to satisfy a volume target.

## Weekly set allocation

Adding a set is a planned review decision, not the default response to an easy session. From three to four sets is a 33% increase in exercise set volume.

Only consider it when recovery is acceptable, repeated training has been tolerable, the completed schedule is below a personalized set budget, and ordinary rep/load progression is unavailable or a planned volume block explicitly calls for it. Maintain a progressing routine by default. A plateau with high effort is not evidence that more volume is needed.

Select one priority exercise and add at most one set in a review period. Check every involved muscle's projected workload, including secondary exposure and already planned remaining sessions. If several exercises are eligible, rank by explicit user priority and then stable exercise ID. A chest press can be rejected if its additional triceps exposure exceeds that muscle's budget.

Derive initial budgets from two to three weeks of completed, tolerated training plus goal/experience configuration. Population guidance can inform suggested bands, but current fixed per-muscle ranges should become defaults the user can adjust. Never treat a band boundary as an injury threshold.

Shorter rests are an optional density/endurance policy for later versions. Keep rest reasonably consistent while evaluating strength/hypertrophy progression. Better technique is a success to record; a material technique or ROM change creates a new comparison baseline, not fictitious extra tonnage.

## Baselines, tonnage targets, and recovery

Log normally for two to three weeks to establish volume context. There is no need to withhold ordinary exercise guidance when two comparable exposures are already available.

If the user enables the proposed 5% block target, define it precisely:

```text
baseline = median volume load from 2–3 complete comparable training weeks
target accumulation-week volume load = baseline × 1.05
```

Apply to a consistent exercise basket and label it an optional planning target. Do not compare an incomplete week, a newly expanded exercise basket, or a deload week to an accumulation week as if it were a regression. Do not force catch-up work. An unchanged load performed with better control or less effort can also be progress without increased tonnage.

If week four is a scheduled deload, aim for the accumulation target in week three. This avoids requiring both peak volume and recovery in week four. The suggested 70–80% of peak volume load is an optional block setting; the resulting actual reduction must be shown after discrete set/load rounding.

For adaptive recovery, use repeated performance deterioration at comparable load, reps, sets, and execution, supported by effort and recovery reports. Rising RPE from doing more reps is not evidence of a decline. One poor wearable reading should not independently prescribe a deload.

Distinguish a local reset from a whole-program deload. A starting local reset can reduce the load by approximately 5–10% or remove one set, depending on whether intensity or accumulated volume is the issue. A broader deload can initially reduce working sets by roughly one third to one half and lower the effort target for about one training week. These are configurable heuristics, not mandatory physiological schedules. Review recovery before resuming; do not progress from the deliberately easy deload performance. Restart at the last sustainable prescription or a modestly reduced one, then collect fresh evidence.

## Recommendation output

```text
ExerciseRecommendation
  exerciseID, generatedAt, validForSessionID
  action: establish | hold | addReps | addLoad | addSet | reduce | deload | stop
  sets: [{ load?, targetReps, targetRPE }]
  reasonCode, explanation, supportingExposureIDs
  evidenceStatus: insufficient | limited | consistent
  missingInputs, constraintsApplied, ruleVersion
```

Evidence status is a description of input quality, not a probability of success. Recompute live recommendations after log corrections, deletions, configuration changes, or new sessions. Persist the accepted plan as a historical user decision so completion can be assessed; it must not become an authoritative cache of future recommendations.

Example: "Bench press: 100 lb for 10, 10, 10 reps. Your last two workouts completed 10, 10, 9 with every set at RPE 7 or lower. Add one rep to your final set."

Another: "Repeat 100 lb for 12, 12, 12. Your final set was RPE 9, above your target of 8."

## Integration with the inspected Swift app

The inspected checkout is `weight-training-app` under this workspace; this is not an audit of every sibling worktree.

- `ProgressionEngine.swift` already handles double progression and RPE-based loading. Extend it with comparable exposure history and planned completion. Its current middle-of-range rep increases do not require repeated easy exposures, and its RPE-targeted rule can raise load from one scored set.
- `Suggestion.swift` can suggest a load increase during a workout from one easy set. Route it through the same policy so it cannot bypass the repeated-session gate or contradict a recovery action. Keep immediate downward adjustments available for unexpectedly hard work.
- `Session.swift` intentionally has no planned set count. Add an advisory exercise plan and record accepted edits/completion reasons while preserving the open-ended ability to finish or log another set.
- `Prescription.swift` currently holds one rep target. Add per-set targets and an optional suggested set count.
- `SetRecord.swift` already contains load, reps, optional RPE, and warmup status. Add session/plan association and effort provenance with compatible defaults. Keep legacy unknowns explicit.
- `VolumeReport.swift` already computes muscle credit with primary/secondary roles. Extend it with known/unknown effort counts, exercise counts, projected workload, and configurable budgets.
- `Deload.swift` already detects misses and effort creep. Require comparable reps/set structure for creep, distinguish local resets from block deloads, and prevent deload work from earning progression.
- Keep calculations pure in `WeightTrainingCore`, persistence in `WeightTrainingStore`, and display/user actions in the app. Reuse the existing achievable-load helpers and CloudKit-compatible optional/defaulted fields.

Suggested pipeline:

```text
actual logs + accepted plans + exercise/profile configuration
    -> comparable exposures and muscle workload summaries
    -> recovery and data-quality gates
    -> exercise progression candidate
    -> weekly budget and equipment validation
    -> one explained recommendation
```

## Delivery and evaluation

1. Add plan/completion metadata, exposure matching, and missing-effort handling. Preserve old logs and first-session behavior.
2. Implement hold/add-rep/add-load behavior with repeated-easy gates, achievable load checks, and one shared decision path for session suggestions.
3. Add personalized muscle budgets and guarded weekly set allocation.
4. Add optional training blocks, baseline comparisons, and scheduled/adaptive deload coordination.
5. Replay historical scenarios in shadow mode before showing the new engine's suggestions. Then collect acceptance, overrides, achieved reps, RPE overshoot, and workout completion. Acceptance alone does not establish quality.

Required evaluation scenarios: two easy exposures; a single unusually good workout; a hard final set hidden by a low average RPE; partial completion for time versus fatigue; absent RPE; warmup-only history; changed machine or ROM; mixed loads; plate minimums; coarse dumbbell steps; kg/lb conversion; overlapping muscle budgets; an unfinished week; missed sessions; a long break; deload entry/exit; duplicates/imports; corrected/deleted logs; and sessions across midnight.

Assert that missing information never manufactures success, warmups never earn progression, recommendations stay achievable, muscle budgets account for all proposed work, and replaying the same inputs gives the same result. Simulations should check behavior over multiple weeks, including whether the conservative gate produces excessive holding. Use observed outcomes and coach review to tune thresholds before claiming effectiveness.
