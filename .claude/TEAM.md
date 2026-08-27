# The team

Six agents build ChickenBreast. This file is the charter: who does what, what
they are allowed to touch, and how work moves between them.

## The one idea

**GitHub is the message bus. No agent's context is.**

Every fact that has to survive from one agent to the next — what the task is,
what "done" means, what was tried, what CI said, what the verdict was — is
written to an issue, a PR body, a label, or a PR comment. Nothing important
lives only in a conversation.

This is not ceremony. A head agent that holds the whole plan in one context is
a single point of failure: it compacts, and the team forgets. Agents here are
stateless workers that read the board, do one thing, and write the result back.
Any of them can be killed mid-task and the next one picks up from the repo.

## Who does what

| Agent | Owns | Never |
|---|---|---|
| `pm` | The board. Issues, acceptance criteria, sequencing, assignment. | Writes product code. Merges. |
| `core-dev` | `Sources/WeightTrainingCore` — the reasoning. | Touches SwiftData, SwiftUI, or the Xcode project. |
| `app-dev` | `Sources/WeightTrainingStore`, `ChickenBreast/` — persistence and screens. | Changes a progression rule. That's a Core change. |
| `test` | Correctness. Rungs 1–4 of the ladder. | Judges whether a suggestion is *reasonable*. |
| `eval` | Judgment. Does a season of decisions add up. | Passes a change because the unit suite is green. |
| `devops` | `.github/workflows`, `hooks/`, CI triage, the toolchain. | Fixes a product bug to make CI green. |

## How work moves

```
intent ──▶ pm ──▶ issue (ready)
                    │
                    ├──▶ core-dev  ──┐
                    └──▶ app-dev   ──┴──▶ branch + draft PR
                                              │
                                    ┌─────────┼─────────┐
                                  test      eval     devops     (gates)
                                    └─────────┼─────────┘
                                              ▼
                                      verdict on the PR
                                              ▼
                                        you merge
```

Gates are advisory in the sense that they write a verdict, not a merge. The
only hard gate is `hooks/pre-push`, which no agent can talk its way past.

## The collision rule

Two coding agents in flight at once is only worth it if they cannot touch the
same files. The board already carries the partition key: the `area:` labels.

**Never assign two in-flight issues that share an `area:` label.** If a single
issue spans both layers — most do; #67 and #87–89 both did — the `pm` splits it
into a Core task and an App task on one branch, sequenced Core first, with the
handoff written as a PR comment. Never parallel.

## Definition of ready

An issue is not assignable until it has:

1. **Acceptance criteria** — what is observably true when this is done, in the
   app's own terms, not the code's.
2. **One `area:` label**, which is also the collision key.
3. **A named rung.** Which layer of the ladder settles it — `swift test`, an
   eval scenario, a simulator build, or the phone. An issue that can only be
   settled on the phone must say so, because no agent can close it.

An issue missing any of these goes back to `pm`, not forward to a coder.

## Definition of done

1. Branch off `main`, in its own worktree, named `feat/<issue>-<slug>`.
2. `hooks/pre-push` green — this is enforced, not asked for.
3. `test` verdict posted. `eval` verdict posted if the diff touches
   progression, suggestion, deload, readiness or e1RM logic.
4. CI green on the PR — both workflows.
5. Draft PR whose body closes the issue and says which rungs ran and which
   did not.
6. **You merge.** No agent merges. See "Turning that off" below.

## The ladder

Verification climbs in order; stop at the first rung that fails.

| Rung | Command | Proves |
|---|---|---|
| 1 | `swift test` | The reasoning is right. ~1.5s. |
| 2 | `swift test --filter WeightTrainingEvals` | A *sequence* of decisions stays sane. |
| 3 | `hooks/check-core-purity.sh` | Core still imports Foundation only. |
| 4 | `xcodebuild ... -destination 'generic/platform=iOS Simulator'` | App and widget compile. Xcode 26+. |
| 5 | install and lift | Haptics, APNs sync, Health, anything about *feel*. |

**Rung 5 is not reachable by any agent.** An issue that needs it gets a PR that
says so plainly and waits for you. Never let an unrun rung read as a pass.

## Enforcement lives in the repo

Branch protection is unavailable here — private repo, free plan; the API
returns 403. So the gate is local:

```sh
git config core.hooksPath hooks     # once per clone; covers every worktree
```

**The gate only exists on branches that contain `hooks/`.** Git runs no hook
when the directory is missing, and says nothing about it — so a branch created
before this landed is ungated until it rebases onto `main`. That covers the
branches in flight right now. Check with `ls hooks/` before trusting a green
push on an older branch.

`hooks/pre-push` runs the fast suite and the purity grep before anything
leaves the machine. `git push --no-verify` is in the deny list in
`.claude/settings.json` so an agent cannot route around it.

If you ever want a gate GitHub enforces rather than one your machine does,
making the repo public or upgrading to Pro unlocks required status checks on
`main`. That is the only thing here a plan change would improve.

## Turning that off

The team stops short of merging on purpose. To let it merge its own green PRs,
**remove** `Bash(gh pr merge:*)` from the *deny* list in
`.claude/settings.json` and say so in `pm`'s brief. Adding an allow entry does
nothing on its own — deny wins over allow. Do that only
once you have watched a few cycles land correctly — the cost of a bad merge to
`main` here is a day, and the cost of reading a diff is a minute.
