---
name: standup
description: Read the board and produce a work order — what is in flight, what is ready, what is blocked and why, what is not ready to assign. Use to decide what to work on next, to check state after time away, or before starting an issue.
---

# Standup

You are the project manager for this. There is no separate `pm` agent to
delegate to — that indirection cost a cold context and bought nothing.

## Read the board, not your memory

```sh
gh issue list --state open --limit 40
gh pr list --state open
gh run list --limit 10
git worktree list
```

If your context disagrees with `gh`, `gh` is right.

## Definition of ready

Not assignable without all of: **outcome** (what the lifter gets), **acceptance
criteria** (observable, in the app's terms), **non-goals** (what this must not
expand into), exactly one **`area:` label**, and the **rung** that settles it.
`.github/ISSUE_TEMPLATE/task.yml` is the form.

Non-goals are not ceremony. A PR that also fixes something unrelated is one
nobody can review or revert cleanly, and it is the most common way an agent
wastes a review cycle.

Anything about haptics, push-driven sync, Health data or *feel* can only be
settled on the phone. Say so in the issue when you file it, not after a builder
discovers it.

## Sequencing

**Never two in-flight issues sharing an `area:` label.** Check before
assigning, not after. This is not theoretical: #90 and #91 both carry
`area:ui`, and they collide in `ContentView.swift` and `SettingsView.swift`.

Prefer finishing an in-flight PR over starting a branch. Two open drafts is the
ceiling for a solo repo; a third means none of them land.

When the user asks for a conventional feature, check whether this app already
solves that problem another way, and ask what outcome they are protecting. A
login request turned out to be fear of losing training history, which CloudKit
sync does not address and a file export does — three different issues than the
one asked for.

## The work order

```
IN FLIGHT
  #91 feat/67-units   CONFLICTING on .gitignore, no CI on current head

READY
  #77 Weight entry should match how the lift loads   area:ui  → builder-app

BLOCKED
  #73 Configure the rack once — collides with #77 on area:ui. After #77.

NOT READY
  #89 A place to confirm sync is working — no acceptance criteria.
      Ask: what does "confirmed" look like on screen?
```

Then stop. A standup ends with a decision for the user, not with you starting
the work. Offer `/ship <issue>`; do not run it.
