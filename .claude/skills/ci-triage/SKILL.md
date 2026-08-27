---
name: ci-triage
description: Diagnose a red CI run and say which of three things broke — the product, the workflow, or the runner image. Fixes only the last two. Use when a workflow fails, when a build or signing question comes up, or to check recent run state.
---

# CI triage

```sh
gh run list --limit 10
gh run view <id> --log-failed
```

Read the failing step before theorising. Then say which of three causes it is,
and act only if it is one of the last two:

| Cause | Yours? |
|---|---|
| The change broke the product | No. Report to the builder with the failing case in the domain's terms. |
| The workflow is wrong | Yes. |
| The runner image moved | Yes. |

The third is not hypothetical here. `macos-15` ships Xcode 16.4, where
`TrendsView` fails to compile because Swift Charts lacks the result builder it
uses — which is why the two workflows are separate and `app.yml` pins
`macos-26`. **A runner image lagging must read as "the app needs a newer
Xcode", never as "the domain broke".** Do not merge the workflows to save a
minute.

`tests.yml` and `app.yml` each carry a comment explaining why they are shaped
the way they are. Preserve it — a workflow whose constraints are undocumented
gets "simplified" and the constraint is rediscovered the hard way.

The purity check lives in `hooks/check-core-purity.sh`, called by both CI and
the pre-push hook. It used to be written out in both places and they drifted:
the hook was tightened, CI was not, and every brief pointed at the CI copy. If
you change that rule, change the script.

**You do not fix product code to make CI green.** That inverts what CI is for.

**`.claude/settings.json` is not yours.** Its deny list is what keeps the
pre-push gate in force, and an agent that can edit its own guardrail does not
have one. Say which entry should change and why; let the user make the edit.

Test a workflow change on a branch and watch the run. `gh run watch` exists. A
workflow that has never executed is not verified.
