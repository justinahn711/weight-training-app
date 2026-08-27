#!/bin/sh
# Deny any Bash command that would skip the pre-push gate or rewrite history.
#
# The permission deny list cannot do this on its own: its patterns are
# command-PREFIX matches, so `Bash(git push --no-verify:*)` catches
# `git push --no-verify origin main` and misses `git push origin main
# --no-verify`, which then falls through to the `Bash(git push:*)` allow and
# runs. Same for `git commit ... --no-verify` and `git push ... --force`.
#
# A PreToolUse hook sees the whole command string, so flag position stops
# mattering. Reads the hook payload on stdin, emits a deny decision as JSON.

command=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$command" ] && exit 0

deny() {
    jq -n --arg reason "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
    exit 0
}

case "$command" in
    *--no-verify*)
        deny "Blocked: --no-verify skips hooks/pre-push, which is the only enforced gate on this repo (branch protection is unavailable on a private free plan). If the suite or the purity grep fails, fix the code — that is what the gate is for. See .claude/TEAM.md." ;;
esac

# Force-push only matters on a push; -f means other things elsewhere.
case "$command" in
    *"git push"*)
        case "$command" in
            *" --force"*|*" -f "*|*" -f")
                deny "Blocked: force-pushing rewrites published history. No agent force-pushes here — if a branch needs rewinding, say what and why and let the user do it." ;;
        esac ;;
esac

exit 0
