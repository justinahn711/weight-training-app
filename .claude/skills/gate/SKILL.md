---
name: gate
description: Run the verification gates against an existing PR or the current branch and post the verdicts — correctness, judgment, and CI. Use to check work that already exists, including work you or the user wrote by hand.
---

# Gate a change

Argument is a PR number, or nothing for the current branch.

**Bind the diff to the PR before anything else.** `gh pr view` fetches metadata
and checks out nothing, so diffing your own `HEAD` against `main` describes
whatever branch you happen to be on — from `main` that diff is empty, `eval`
never gets added, and the gates verify one branch while their verdicts are
posted on another.

Fetch `main` in the same breath — every diff below is against `origin/main`,
and a stale one puts commits the PR does not contain into the change you hand
the gates. Work in a throwaway worktree so you do not disturb what is checked
out:

```sh
gh pr view <n> --json number,headRefName,title,files
git fetch origin main "$(gh pr view <n> --json headRefName -q .headRefName)"
git worktree add .claude/worktrees/gate-<n> --detach FETCH_HEAD
cd .claude/worktrees/gate-<n> && git config core.hooksPath hooks
git diff origin/main...HEAD --stat
```

With no argument, gate the branch you are on and say so — that is the one case
where local `HEAD` is the right target.

When you are done, ask the user before removing it — `git worktree remove` is
deliberately not in the allow list, because the same verb with `--force` deletes
a sibling agent's uncommitted work.

## Which gates apply

Always `test` and `devops`. They are independent — spawn them in one block, and
give each the worktree path explicitly.

Add `eval` when the diff touches progression, suggestion, deload, readiness or
e1RM logic:

```sh
git diff origin/main...HEAD --name-only -- Sources/WeightTrainingCore
```

When in doubt, run it. A false alarm from `eval` costs a minute; a progression
change that ships without it is the failure mode the harness was built for.

## Restate the verdicts

Subagent reports do not reach the user. Relay each verdict in full, including
the rungs that did **not** run — that is the half a summary drops and the half
that matters, because an unrun rung reading as a pass is how a defect ships
through a green board.

Keep the gates' own framing rather than flattening it:

- **`test`** — a failed rung is blocking. Give the failing case in the domain's
  terms: the exercise, the load, the session index.
- **`eval`** — an *invariant* breach is blocking; the engine proposed something
  it must never propose. A failed *expectation* is not: it is a judgement about
  training, and if the rules changed deliberately the right fix may be the
  expectation. Hand that one to the user with the reasoning, do not decide it.
- **`devops`** — say which of three things a red run means: the product broke,
  the workflow is wrong, or the runner image moved. Only the last two get fixed
  by an agent.

## Name what nothing here can prove

Close with the rungs no gate can reach. If the change touches haptics, sync,
Health, or anything about feel, say plainly that it is unsettled and what to
check on the phone. Nothing in this pipeline can distinguish "didn't fire" from
"fired and wasn't felt" from "fired late".
