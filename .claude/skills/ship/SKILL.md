---
name: ship
description: Take one GitHub issue from ready to a gated draft PR — one builder, then the review and eval gates, then the evidence manifest. Use when told to implement, build, fix or ship a specific issue number.
---

# Ship an issue

Argument is an issue number.

## 1. Check it is ready

```sh
gh issue view <n> --json number,title,body,labels
gh pr list --state open --json number,headRefName,labels
```

Ready means outcome, acceptance criteria, **non-goals**, one `area:` label, and
a named rung. **If any is missing, stop and hand it back** — an agent that
invents the acceptance criteria and then meets them has proven nothing.

**Check the collision rule before assigning.** If an in-flight PR carries the
same `area:` label, say so and stop.

## 2. One builder

Pick the mode by the paths the change will touch — Core reasoning →
`builder-core`; persistence, screens, widget, project → `builder-app`. Spawn
with `isolation: "worktree"`.

**A cross-layer issue is still one builder at a time, Core first.** Most
substantial issues are cross-layer; #67 and #87–89 both were. Core has no
dependencies and a 1.5s suite, the app layer depends on it and needs a
simulator build, so building the dependency second means discovering its shape
twice. Hand the second mode what the first exposed.

## 3. Gate it

Once the builder has pushed a draft PR, spawn `reviewer` — and `evaluator` too
when the diff touches progression, suggestion, deload, readiness or e1RM:

```sh
git -C <worktree> diff origin/main...HEAD --name-only -- Sources/WeightTrainingCore
```

**Give every gate the worktree path explicitly.** The builder ran with worktree
isolation, so its diff is checked out nowhere else; a gate spawned without a
path follows `CLAUDE.md` to the main checkout, runs the suite against whatever
is there, and posts a green verdict on code it never executed.

**Never let the builder gate its own work.** The value of the gate is a second
reader with different instructions.

## 4. Manifest, then stop

Fill `.github/pull_request_template.md` from the command output — not from the
builder's summary, and not from memory. Every rung gets a row; `NOT RUN` is a
value.

**You do not merge.** A failed rung or an invariant breach goes back to the
builder with the failing case in the domain's terms, and the gate re-runs.
Everything else is the user's call.
