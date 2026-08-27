## Contract

Closes #

Non-goals this PR respects:

## Evidence

Fill every row from the command output, not from memory. `NOT RUN` is a value —
a missing row is the failure mode, not a false PASS.

| Rung | Command | Result |
|---|---|---|
| 1. Domain suite | `swift test` | |
| 2. Evals | `sh hooks/run-evals.sh` | |
| 3. Core purity | `sh hooks/check-core-purity.sh` | |
| 4. Simulator build | `xcodebuild … -destination 'generic/platform=iOS Simulator'` | |
| 5. The phone | install and lift | NOT RUN — no agent can reach this |

Rung 2 reads `UNAVAILABLE` on a tree with no `Tests/WeightTrainingEvals`
target. That is not a pass.

## Risk

- Persistence / schema change:
- Public API change:
- Rollback: revert this PR

## Review focus

What a reader should look hardest at, and why.

## What nothing here can prove

Anything about haptics, push-driven sync, Health or *feel* — say what to check
on the phone.
