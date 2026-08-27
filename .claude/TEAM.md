# The team

Three runtime roles. `CLAUDE.md` carries the ladder, the worktree rules and the
reporting contract — this file is the charter: who does what, and what has to be
true before work moves.

## The one idea

**GitHub is the message bus. No agent's context is.**

Every fact that has to survive from one agent to the next — the task, what done
means, what was tried, what CI said, what the verdict was — is written to an
issue, a PR body, a label or a comment. A head agent holding the plan in one
context is a single point of failure: it compacts, and the team forgets. Agents
here are stateless workers, killable mid-task.

## Who does what

| Role | Owns | Never |
|---|---|---|
| `builder-core` | `Sources/WeightTrainingCore`, its tests, the evals | SwiftData, SwiftUI, the Xcode project |
| `builder-app` | Store, `ChickenBreast/`, its tests | Changes a progression rule |
| `reviewer` | Correctness, scope, and whether the manifest is honest | Edits the implementation it is reviewing |
| `evaluator` | Whether a season of decisions adds up | Passes a change because the unit suite is green |

`/standup`, `/ship`, `/gate`, `/ci-triage` are skills, not agents. They were
agents once; the handoff cost a cold context and bought nothing.

## Why one builder at a time

Two coders only pay off if they cannot collide, and in this repo they collide.
`area:ui` work keeps landing in the same two view files — #90 and #91 are both
in `ContentView.swift` and `SettingsView.swift` right now. So the `area:` labels
are a **sequencing** key, not a parallelism key: never two in-flight issues
sharing one, and cross-layer issues run Core first, then App, on one branch.

## Definition of ready

Outcome, acceptance criteria, **non-goals**, one `area:` label, and the rung
that settles it. `.github/ISSUE_TEMPLATE/task.yml` is the form. Missing any of
them, it goes back to `/standup`, not forward to a builder.

An issue that can only be settled on the phone must say so, because no agent
can close it.

## Definition of done

1. Branch off `main` in its own worktree, `feat/<issue>-<slug>`.
2. `hooks/pre-push` green — enforced, not asked for.
3. `reviewer` verdict posted; `evaluator` too when the diff touches
   progression, suggestion, deload, readiness or e1RM.
4. CI green on the PR.
5. The evidence manifest filled from command output, every rung with a row.
6. **You merge.** No agent merges.

## Enforcement lives in the repo

Branch protection is unavailable — private repo, free plan; the API returns 403
on `/protection` and `/rulesets`. So the gate is local, and it is honest about
being local:

```sh
git config core.hooksPath hooks     # once per clone; covers every worktree
```

`hooks/pre-push` runs the suite and the purity check. `hooks/block-gate-bypass.sh`
denies `--no-verify`, force-push in each of its spellings, and `core.hooksPath`
mutation — and asks before anything writes to `hooks/` or
`.claude/settings.json`, because enumerating write *tools* is a losing game
when the allow list carries a general-purpose interpreter.

**The gate only exists on branches that contain `hooks/`.** Git runs no hook
when the directory is missing and says nothing about it, so a branch created
before this landed is ungated until it rebases.

If the repo ever goes public or Pro, required status checks on `main` are
strictly better than any of this — they apply to every clone and cannot be
skipped.

## Turning merging on

The team stops short of merging on purpose. To change that, **remove**
`Bash(gh pr merge:*)` from the *deny* list in `.claude/settings.json` — adding
an allow entry does nothing, because deny wins. Do it only after watching a few
cycles land correctly: a bad merge to `main` costs a day, reading a diff costs
a minute.
