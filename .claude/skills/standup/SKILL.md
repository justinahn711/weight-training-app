---
name: standup
description: Read the board and produce a work order — what is in flight, what is ready, what is blocked and why, what is not ready to assign. Use to decide what to work on next, to check state after time away, or before assigning work to the coding agents.
---

# Standup

Delegate to the `pm` agent. Do not read the board yourself and summarise it —
`pm` carries the definition of ready, the collision rule, and the house style
for issues, and re-deriving those here is how they drift.

```
Agent(subagent_type: "pm", prompt: "Standup. Read the board — open issues, open
PRs, recent CI runs, existing worktrees — and produce the work order. Include
NOT READY with the specific question each one is missing.")
```

Pass through any focus the user gave ("what's blocking #67", "plan the backup
work") as the prompt instead.

## Relay the work order in full

`pm`'s report does not reach the user — you must restate it. Relay the whole
thing, not a summary of it: the point of a work order is that every line is
actionable, and the BLOCKED and NOT READY sections are the ones a summary drops
and the user most needs.

## Then stop

A standup ends with a decision for the user, not with you starting the work.
If the work order makes the next move obvious, say what it is and offer to run
`/ship <issue>` — do not run it.
