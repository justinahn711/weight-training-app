# Codex instructions for ChickenBreast

## Read the project guide first

Before any work here, read `CLAUDE.md`. It is the project guide every agent
follows: the code layout, the rules that are not negotiable (suggest, never
change; derived data is computed, never stored; every proposal routes through
`Exercise.nearestAchievable`), the CloudKit constraints, the verification ladder,
the evidence manifest PRs carry, and the traps this project has already hit.
Codex does not load `CLAUDE.md` on its own, which is why this pointer exists.

This file only adds Codex model routing and worktree habits. Where the two
disagree, `CLAUDE.md` wins.

## Model routing and token budget

Use the least expensive available model that can reliably handle the task. Route
by uncertainty, failure impact, and scope, not just file count. These model IDs
were verified in this host's Codex catalog; check availability before substituting.

| Work | Custom agent | Model | Reasoning |
|---|---|---|---|
| Narrow searches, log summaries, copy/docs edits, mechanical changes with clear requirements | `routine_worker` | `gpt-5.6-luna` | `low` |
| Bounded feature implementation, ordinary SwiftUI changes, straightforward debugging and tests | `engineering_worker` | `gpt-5.6-sol` | `medium` |
| Ambiguous bugs, architecture, recommendation rules, persistence/migrations, sync/concurrency, data integrity, substantial code review | `complex_worker` | `gpt-6-astra` | `high` |

- Delegate a concrete independent subtask to the appropriate tier when it saves
  meaningful work or improves reliability. This file explicitly requests that
  bounded delegation; it does not request agents for every task.
- For a tiny task, finish locally when spawning would cost more than doing it.
  Never delegate solely to claim that a smaller model was used.
- If named custom agents are unavailable but the spawn tool accepts a model and
  reasoning override, pass the table's values explicitly. Use a fresh context
  (`fork_turns="none"` where supported) with a concise task brief, file paths,
  constraints, and expected output instead of copying the whole conversation.
- Upgrade once when a worker identifies uncertainty outside its assigned scope
  or cannot resolve the cause after a bounded attempt. Send its evidence and
  remaining question to the next tier; do not repeat the same investigation.
- Use Astra directly for the hardest/highest-impact work. Do not route uncertain
  training-load, pain, recovery, migration, or concurrency decisions to Luna.
- Reserve `xhigh`, `max`, and `ultra` for demonstrated need or an explicit request.
  Do not automatically use maximum reasoning for routine work.
- Default to one worker; use at most two concurrent workers when their tasks
  are independent. Workers must not recursively delegate without parent approval.
- The parent integrates and verifies results without redoing the worker's full
  investigation. Return concise findings, changed files, validation, and blockers.
- No promise of token savings: smaller-model price, tokens consumed, and account
  quota usage are different measures. Avoid invented savings percentages.

`AGENTS.md` is routing guidance, not an automatic model switch for the active
conversation. Custom agent definitions live in `.codex/agents/`; default child
model and concurrency settings live in `.codex/config.toml`. They take effect
when the runtime loads them for a new session/spawn. Respect explicit user model
choices. If a model is unavailable, report it and use an available appropriate
tier; never silently substitute a premium model for routine delegated work.

## Worktree and verification discipline

- Work in the task's isolated worktree. Inspect branch/status before editing;
  preserve other agents' and the user's changes. Do not edit the main checkout
  to implement a feature assigned to another worktree.
- Parallel writers need disjoint files or separate worktrees. State ownership in
  their briefs. Read-only reviews may share a checkout.
- Start searches with `rg`, read targeted ranges, and return relevant log tails
  instead of full build output. Reuse inspected evidence.
- Keep calculations in `WeightTrainingCore`, persistence in `WeightTrainingStore`,
  and UI in `ChickenBreast/ChickenBreast`. Core imports Foundation only.
- Run validation appropriate to the change. Code changes use relevant Swift
  tests; progression changes also need scenario evals and core-purity checks.
  App changes need the relevant Xcode build. Follow required repository hooks.
- Documentation/configuration-only work needs diff/config validation, not a
  redundant app build. Do not rerun passing checks without a relevant change.
- Never fabricate workout history or overwrite phone data to create test results.
- The current recommendation contract and remaining phases are in
  `docs/recommendation-engine-plan.md`; distinguish planned behavior from shipped
  behavior using `docs/recommendation-engine-implementation.md`.
