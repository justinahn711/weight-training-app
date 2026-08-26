---
name: ship
description: Take one GitHub issue from ready to a gated draft PR — assign the right coding agent, run the correctness, judgment and CI gates, and post the verdicts. Use when told to implement, build, fix or ship a specific issue number.
---

# Ship an issue

Argument is an issue number. Read `.claude/TEAM.md` first if you have not this
session.

## 1. Check it is ready

```sh
gh issue view <n> --json number,title,body,labels
gh pr list --state open --json number,headRefName,title
```

Ready means: acceptance criteria, exactly one `area:` label, and a named rung.
**If any is missing, stop and hand it to `pm`** — do not infer the acceptance
criteria yourself. An agent that invents the criteria then meets them has
proven nothing.

**Check the collision rule before assigning.** If an in-flight PR carries the
same `area:` label, say so and stop. Two agents in the same files is a merge
conflict you pay for at the end, not parallelism.

## 2. Assign one coder

| The change is in | Agent |
|---|---|
| Progression, suggestions, e1RM, deload, readiness, plate math, pure reasoning | `core-dev` |
| Persistence, CloudKit, SwiftUI, the widget, the Xcode project | `app-dev` |

Spawn it with `isolation: "worktree"` so it gets its own branch off `main` and
cannot disturb whatever is checked out in the main tree.

**If the issue spans both layers — most substantial ones do — run them in
sequence on one branch, `core-dev` first, never in parallel.** Core has no
dependencies and its suite runs in 1.5 seconds; the app layer depends on it and
needs a simulator build. Building the dependency second means discovering its
shape twice. Pass `core-dev`'s handoff — what Core now exposes, what the app
half still owes — into `app-dev`'s prompt.

## 3. Gate it

Once the coder has pushed and opened a draft PR, run the gates. `test` and
`devops` are independent — spawn them in one block. Add `eval` only when the
diff touches progression, suggestion, deload, readiness or e1RM logic:

```sh
git diff origin/main...HEAD --stat -- Sources/WeightTrainingCore
```

- `test` — rungs 1–4, plus coverage for anything the diff could have broken silently
- `eval` — invariants and expectations over a season
- `devops` — CI green on both workflows, and triage if not

**Never let a coder gate its own work.** The whole value of the gate is that a
second reader with different instructions looks at it.

## 4. Post the verdicts and stop

Each gate's verdict goes on the PR as a comment, in its own voice. Then relay
to the user: what landed, which rungs ran, **which did not**, and what is left
that only the phone can settle.

**You do not merge.** The PR stays a draft. An invariant breach from `eval` or a
failed rung from `test` goes back to the coder — with the failing case in the
domain's terms — and the gate re-runs. Everything else is the user's call.
