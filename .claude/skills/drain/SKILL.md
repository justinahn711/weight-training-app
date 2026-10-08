---
name: drain
description: Work the issue queue until nothing is left that an agent can move — land green PRs the owner pre-authorized, then ship the next ready issue, one at a time. Built to run under `/loop /drain`; each run does one step and says whether to keep going.
---

# Drain the queue

One run, one step. `/loop` brings you back; do not try to finish the queue in
a single turn. The steps are the ones `/standup` and `/ship` already define —
this skill only decides which comes next and when to stop.

## 1. Read the board, not your memory

```sh
gh issue list --state open --limit 50 --json number,title,labels
gh pr list --state open --json number,headRefName,isDraft,labels,closingIssuesReferences
git worktree list
```

If your context disagrees with `gh`, `gh` is right. A builder or gate you
spawned earlier that has not reported back is in flight — wait for it; do not
spawn a second one on the same issue.

## 2. Land before you start

Prefer finishing a PR over starting a branch. For each open PR whose issue
carries **`agent:merge-ok`**:

```sh
gh pr update-branch <pr>
gh pr checks <pr> --watch   # returns early: see below
gh pr merge <pr> --squash
```

- `gh pr checks --watch` right after `update-branch` returns once only the fast
  "Tests" check exists. Wait until **all 4 checks exist and all have
  conclusions** before reading the result.
- A UI-job failure that is the **only** failure gets **one** rerun
  (`gh run rerun <id> --failed`). A second failure stops that PR: comment the
  failing test and message on it, and leave it for the owner.
- Never `--admin`, never `--no-verify`. If the issue did not close on merge,
  close it by hand with a link to the PR.

**No `agent:merge-ok` label, no merge.** The owner adds it; you never do. A
green PR without it is "awaiting owner", not a reason to stop the loop.

## 3. Pick the next issue

Eligible means all of:

- **ready** by `/standup`'s definition (outcome, acceptance criteria,
  non-goals, one `area:` label, a named rung) — not ready is skipped and
  listed, never filled in by you;
- **no open PR** already closes it;
- **no in-flight PR shares its `area:` label** — `area:` is a sequencing key;
- **open PRs awaiting the owner are fewer than two.** Two open drafts is the
  ceiling for this repo; a third means none of them land.

Take the lowest-numbered eligible issue, unless an issue body names another
as a prerequisite.

## 4. Ship it

Run `/ship <n>`. Everything in it applies: one builder with worktree
isolation, gates given the worktree path, the manifest from command output.

**One simulator-heavy agent at a time.** Two at once drove load average to
~1000. If a builder or gate already owns the simulator, a second app-layer
issue waits; a Core-only issue (`swift test`, no simulator) may run alongside.

## 5. Report, then decide whether to continue

End every run with:

```
LANDED     #<pr> (closes #<n>)
SHIPPED    #<n> → PR #<pr>, gates <verdict>
IN FLIGHT  #<n> <agent>, started <when>
AWAITING   #<pr> green, no agent:merge-ok
STOPPED    #<pr> <failing test>, needs owner
SKIPPED    #<n> not ready: <missing field>
```

**Stop the loop** (`ScheduleWakeup` with `stop: true`) only when nothing is in
flight **and** nothing is eligible to land or ship. Say which: queue empty,
everything awaiting the owner, or everything remaining not ready.

Otherwise keep going. While an agent is running you are woken when it
finishes; schedule only a long fallback (1200s+) in case it hangs. Do not
poll.
