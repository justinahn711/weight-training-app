# Session lifecycle

The set log is still saved immediately and remains the source of truth for
training history and every derived statistic. An unfinished-workout draft only
stores the route the lifter intends to resume.

| Event | Workout state | Progression | Live Activity |
|---|---|---|---|
| Back / return to Train | Keep draft; show Resume | Do not apply | Keep running |
| Explicit Finish | Clear draft after success | Apply once | End |
| Background / lock | No change | Do not apply | Keep running |
| App termination | Draft and sets are already durable | Do not apply | ActivityKit preserves it |
| Relaunch | Rebuild exact lineup/current exercise and reload logged sets | Do not apply | Resume on opening workout |

“Unfinished” means a workout draft exists. It is not inferred from today’s
sets: a completed workout and an interrupted one can contain the same sets.
