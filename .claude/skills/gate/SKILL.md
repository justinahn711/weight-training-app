---
name: gate
description: Run the verification gates against an existing PR or the current branch and report the verdicts — correctness, scope, and longitudinal judgment. Use to check work that already exists, including work written by hand.
---

# Gate a change

Argument is a PR number, or nothing for the current branch.

## Bind the diff to the PR first

`gh pr view` fetches metadata and checks out nothing, so diffing your own
`HEAD` describes whatever branch you are on — from `main` that diff is empty,
the eval gate never gets added, and the gates verify one branch while their
verdicts are posted on another.

Fetch `main` in the same breath; every diff below is against `origin/main`, and
a stale one puts commits the PR does not contain into the change you hand the
gates.

```sh
head=$(gh pr view <n> --json headRefName -q .headRefName)
git fetch origin main "$head"
git worktree add .claude/worktrees/gate-<n> --detach FETCH_HEAD
cd .claude/worktrees/gate-<n>
git diff origin/main...HEAD --stat
```

With no argument, gate the branch you are on and say so — that is the one case
where local `HEAD` is the right target.

Removing the worktree afterwards needs the user: `git worktree remove` is
deliberately not allow-listed, because the same verb with `--force` deletes a
sibling builder's uncommitted work.

## Which gates

Always `reviewer`. Add `evaluator` when the diff touches progression,
suggestion, deload, readiness or e1RM:

```sh
git diff origin/main...HEAD --name-only -- Sources/WeightTrainingCore
```

When in doubt, run it. A false alarm costs a minute; a progression change that
ships without it is the failure the harness was built for.

Give each gate the worktree path explicitly.

## Restate the verdicts

Subagent reports do not reach the user. Relay each in full — **including the
rungs that did not run**, which is the half a summary drops and the half that
matters.

- **`reviewer`** — a failed rung blocks. Failing case in the domain's terms.
- **`evaluator`** — an *invariant* breach blocks; a failed *expectation* is a
  judgement about training and is the user's to make, so hand it over with the
  reasoning rather than deciding it. "Rung 2 unavailable" is neither a pass nor
  a failure of the change.

Close with what nothing here can prove. If the change touches haptics, sync,
Health or feel, say plainly that it is unsettled and what to check on the phone.
