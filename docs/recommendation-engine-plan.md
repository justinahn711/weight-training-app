# Progressive overload recommendation engine

Status: updated after commit `879f52e`. Phases 1–4 are implemented on
`feat/recommendation-engine`; phase 5 instrumentation is implemented and
unassisted bodyweight progression is shipped. The 811 Swift tests, 16 eval
scenarios, Core purity check, simulator build, and signed device build pass.
The commit was installed and launched on an iPhone; the SwiftData store UUID
and counts (19 exercises, 11 sessions, 118 sets) remained unchanged. Physical
hands-on flow and real outcome collection remain. Assisted movements,
unmeasured plate-built equipment, other bodyweight variations, and mixed
top/back-off prescriptions remain deferred. Threshold tuning follows hands-on
validation and observed outcomes.

Provisional audience: healthy adult recreational lifters seeking muscle growth with steady strength gains. Offer a goal and equipment choice during first use, reusing any existing setup. Experience, frequency, and exercise priorities are optional refinements; reuse the chosen routine and observed schedule without treating an inferred preference as user-confirmed. Strength and general fitness can use different exercise prescriptions without replacing the decision pipeline.

## Product contract

For each exercise, prepopulate an achievable load, reps for each working set, a suggested set count, target RPE, and a short explanation grounded in actual history. The lifter can train immediately or edit targets directly in the workout. Ordinary progression must not require opening Review set plan or pressing Use Plan. Completing a set records what was actually performed.

At workout preparation, coordinate targets across the full routine. When an
exercise starts, persist the exact displayed prescription before its first
working set, using the same operation whether the user logs by touch, voice,
or the lock screen. This is a record of what the app prescribed, not evidence
that the user explicitly approved a recommendation or completed it. Existing
references to an "accepted plan" denote the stored prescription/revision; the
revised model must distinguish automatic activation from an explicit edit or
review. Historical accepted plans retain their original provenance.

Keep an activated exercise's targets stable for that workout. Recompute future
recommendations after relevant log or configuration changes; make any change
to the active prescription explicit. Preserve the ability to change targets,
stop early, or log extra work. A pain report takes precedence over every
recommendation path, including first use and legacy-history initialization.

## Minimal-configuration workout experience

- Reuse existing goal, routine, equipment, and history. Offer editable defaults
  when these are absent; do not require a volume-budget or training-block setup.
- Recent comparable history supplies a conservative starting target without a
  plan-review gate. With no usable history, guide selection of a starting load;
  do not present an equipment minimum as a personalized working-weight estimate.
- Show one short reason beside the target. Detailed evidence and advanced
  settings are optional, outside the normal logging flow.
- Actual RPE remains optional and separate from target RPE. Prompt lightly when
  missing effort is preventing a decision; otherwise explain a conservative hold.
  Do not copy one reported set's effort to the other sets.
- Muscle-volume calculations and default ranges work automatically. Adjustments
  to volume ranges, priorities, and scheduled blocks belong in advanced settings.
- Explain recovery proposals in the workout with a simple way to use, adjust,
  or dismiss them. Provide an explicit exit from recovery even with blocks off.
- Recommendation results in Settings is an evaluation surface. Visiting it,
  reviewing plans, or configuring metrics is never necessary to obtain guidance.

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
| Training profile | Goal/default; optional experience, schedule, priorities with source/provenance | Selects policy without mandatory advanced configuration |
| Exercise configuration | Stable exercise/variant ID, muscles and roles, equipment identity, load convention, achievable loads, rep range, target RPE | Prevents comparisons between different movements or machines |
| Planned exercise exposure | Session ID, exact displayed proposal, active ordered set targets, load/reps/RPE, revision and automatic/explicit origin | Distinguishes suggested work, user changes, performed work, and early stops |
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

Adding a set is a coordinated workout-allocation decision, not the default response to an easy session. It does not require a separate user review screen. From three to four sets is a 33% increase in exercise set volume.

Only consider it when recovery is acceptable, repeated training has been tolerable, the completed schedule is below a personalized set budget, and ordinary rep/load progression is unavailable or a planned volume block explicitly calls for it. Maintain a progressing routine by default. A plateau with high effort is not evidence that more volume is needed.

Select one exercise and add at most one set in a defined seven-day allocation period, tracked from prescription decisions rather than screen openings. Check every involved muscle's projected workload, including the entire candidate prescription, secondary exposure, sibling exercises, and already planned remaining sessions. Avoid double counting work already reserved for that exercise. If several exercises are eligible, rank by optional user priority, then routine order and stable exercise ID. A chest press can be rejected if its additional triceps exposure exceeds that muscle's budget. When upcoming work or recovery is too uncertain to establish headroom, hold the set count instead of assuming the budget is empty.

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

Evidence status is a description of input quality, not a probability of success. Recompute future recommendations after log corrections, deletions, configuration changes, or new sessions. Persist the displayed proposal and activated prescription with their origin so completion can be assessed. Neither is an authoritative cache of future recommendations, and automatic activation is not a historical user approval.

Example: "Bench press: 100 lb for 10, 10, 10 reps. Your last two workouts completed 10, 10, 9 with every set at RPE 7 or lower. Add one rep to your final set."

Another: "Repeat 100 lb for 12, 12, 12. Your final set was RPE 9, above your target of 8."

## Integration with the inspected Swift app

The following integration notes describe the original baseline inspected before
implementation. Current delivery status and remaining work are defined below;
these notes are not a claim that the listed data models remain absent.

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
actual logs + prescription snapshots + exercise/profile configuration
    -> comparable exposures and muscle workload summaries
    -> recovery and data-quality gates
    -> exercise progression candidates
    -> coordinated workout allocation and equipment validation
    -> explained targets in the workout
    -> exact proposal and active-prescription snapshot before logging
```

Build exposure and muscle summaries once per workout evaluation and share them
across candidates, avoiding repeated full-history fetches per exercise. Optimize
only with equivalence tests and measured representative histories. Any cache
must include history/configuration revisions and relevant time-window boundaries;
corrections, deletions, sync, and schedule changes must invalidate future advice.
The persisted active prescription stays stable across refreshes and relaunches.

## Delivery and evaluation

### Phase 1 — Reliable history and automatic prescription records

**Foundation, correction integrity, and automatic activation implemented.** Preserve
plan revisions, workout identities, completion reasons, and legacy logs. Add
the exact displayed proposal and automatic/explicit origin to the prescription
lifecycle. Save the active prescription before the first working set without
requiring a review screen. RPE additions/removals in both correction editors
must update effort provenance; a weight-only edit must not certify an old RPE.

**Complete when:** first-use and returning-user flows work with minimal setup;
automatic activation cannot manufacture completion or effort evidence; logging,
undo, corrections, restore, sync, and relaunch preserve the prescription record.

### Phase 2 — Recommendations inside the normal workout

**Core progression, unassisted bodyweight progression, and the default
touch/voice per-set workflow implemented; physical hands-on validation remains.**
Keep repeated-easy, achievable-load, and one-variable-at-a-time rules. Populate
targets and their reason directly in the exercise view. Review set plan becomes
an optional detailed editor. Use the same per-set targets for touch, voice,
Live Activity logging, undo, and resumed sessions. Apply pain gates before
legacy initialization as well as normal progression. Refresh unstarted proposals
when their evidence changes; retain active targets unless explicitly changed.

**Complete when:** users can receive, follow, and edit recommendations without
visiting Settings or accepting a separate plan; a 10/10/9 prescription advances
correctly through every logging surface; recorded pain always pauses guidance.

### Phase 3 — Automatic workout-wide muscle-volume coordination

**Implemented.**
Reuse routine/history with editable default set ranges. Coordinate candidates
together, counting the full proposed prescription, remaining sibling work,
secondary muscles, and known upcoming sessions. Enforce one extra set on one
selected exercise per allocation period. Do not interpret an incomplete schedule
as permission to add work. Manual muscle budgets remain optional.

**Complete when:** 9 logged chest sets plus a proposed 4 cannot pass a maximum
of 12; overlapping accepted work is retained; candidate ordering and repeated
reads cannot allocate extra sets twice; no volume configuration is required.

### Phase 4 — Explainable recovery and optional training blocks

**Implemented; physical-phone validation remains.**
Require comparable loads, reps, set structures, equipment, and execution before
using effort trends to infer deterioration. Separate local resets from broader
recovery. Keep scheduled blocks opt-in and ensure the base recommendation flow
works with them off. Recovery proposals have a visible use/adjust/dismiss path
and an explicit route back to normal training when a block is disabled. Preserve
the consistent exercise basket for baseline comparisons and show actual recovery
reductions after rounding rather than implying the percentage was achieved.

**Complete when:** doing harder or different work alone does not trigger a false
fatigue trend; disabling a block cannot trap a lift in recovery; deload sets do
not earn progression; resumption establishes fresh evidence.

### Phase 5 — Outcome evaluation, phone validation, and optimization

**Instrumentation, evidence integrity, automatic-origin tracking, and
request-scoped history indexing implemented; physical hands-on validation and
real outcomes remain.**
Recommendation results is primarily for development/evaluation, not a required
user workflow. Preserve the exact displayed proposal instead of recomputing it
at acceptance. Track displayed prescriptions, automatic activation, explicit
reviews, overrides, completion, RPE coverage, and effort overshoot separately.
Automatic and explicitly reviewed plans remain separate outcome cohorts. Report
the saved reason for every hold and distinguish fully reported work completed
below target RPE from missing effort or target-level effort; this allows the
repeat-easy gate to be evaluated without treating completion alone as proof that
progression was too conservative.
Do not relabel old history as an automatic recommendation or approval. Derive
outcomes from corrected logs and count effort only when an actual reported RPE
exists. Activation, acceptance, and completion are distinct metrics.

Validate the normal phone flow, including lock-screen logging, corrections,
relaunches, and recovery exit. Replay multiweek scenarios and inspect per-exercise
holds/overrides before tuning the two-workout gate, load cap, freshness window,
or volume ranges. History fetches now build one value snapshot per request,
indexed by exercise and workout. Exact-equivalence tests compare the optimized
batch against the prior implementation across a representative two-year history,
while correction and deletion tests ensure the next request sees current rows.
The snapshot is never retained across requests, so optimization cannot serve
stale advice.

**Complete when:** displayed proposals match evaluation records; editing RPE
updates coverage correctly; automatic targets require no evaluation-screen use;
the full phone flow passes; observed outcomes support any threshold change.
The first three conditions and the performance-equivalence gate are automated;
phone validation and observed outcome collection remain.

### Execution order and review regression gates

The seven review findings, automatic prescription lifecycle, full-workout
allocation, and recovery decision boundary have automated regressions. Next
validate the integrated flow on the phone and collect outcomes before tuning
thresholds.

| Review finding | Regression / owning phase | Status |
|---|---|---|
| Volume cap exceeded and sibling work omitted | Full candidate plus other remaining work fits every budget; phase 3 | Fixed |
| Pain ignored before first accepted plan | Legacy/no-plan pain history returns stop; phase 2 | Fixed |
| Incomparable work triggers adaptive fatigue | Load/rep/technique changes cannot establish decline; phase 4 | Fixed |
| Disabling blocks retains deload forever | Explicit recovery exit works with blocks off; phase 4 | Fixed |
| RPE edits leave stale provenance or coverage | Adding/removing RPE changes evidence and coverage correctly; phases 1 and 5 | Fixed |
| Live Activity repeats the prior set target | Logging and undo advance/restore the correct per-set target; phase 2 | Fixed |
| Stored proposal differs from displayed proposal | Snapshot the displayed proposal and distinguish actual overrides; phases 1 and 5 | Fixed |

Required evaluation scenarios: two easy exposures; a single unusually good workout; a hard final set hidden by a low average RPE; partial completion for time versus fatigue; absent RPE; warmup-only history; changed machine or ROM; mixed loads; plate minimums; coarse dumbbell steps; kg/lb conversion; overlapping muscle budgets; an unfinished week; missed sessions; a long break; deload entry/exit; duplicates/imports; corrected/deleted logs; and sessions across midnight.

Assert that missing information never manufactures success, warmups never earn progression, recommendations stay achievable, muscle budgets account for all proposed work, and replaying the same inputs gives the same result. Simulations should check behavior over multiple weeks, including whether the conservative gate produces excessive holding. Use observed outcomes and coach review to tune thresholds before claiming effectiveness.
