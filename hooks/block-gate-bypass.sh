#!/bin/sh
# Deny any Bash command that would skip the pre-push gate or rewrite history.
#
# The permission deny list cannot do this alone: its patterns are command-PREFIX
# matches, so `Bash(git push --no-verify:*)` catches `git push --no-verify
# origin main` and misses `git push origin main --no-verify`, which then falls
# through to the `Bash(git push:*)` allow and runs. A PreToolUse hook sees the
# whole command string, so flag position stops mattering.
#
# This script FAILS CLOSED. A guardrail that exits 0 when its own dependency is
# missing is worse than none, because nothing announces that it stopped working.

# Fail closed: no jq, no parse, no permission.
if ! command -v jq >/dev/null 2>&1; then
    echo "block-gate-bypass: jq not found — cannot inspect the command, refusing." >&2
    exit 2
fi

payload=$(cat)
if ! command=$(printf '%s' "$payload" | jq -er '.tool_input.command // ""' 2>/dev/null); then
    echo "block-gate-bypass: unparseable hook payload, refusing." >&2
    exit 2
fi
[ -z "$command" ] && exit 0

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}
ask() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}
has() { printf '%s' "$command" | grep -qE "$1"; }

# 1. --no-verify, anywhere, on any command.
if has '(^|[[:space:]])--no-verify([[:space:]]|=|$)'; then
    deny "Blocked: --no-verify skips hooks/pre-push, the only enforced gate on this repo (branch protection is unavailable on a private free plan). If the suite or the purity check fails, fix the code. See .claude/TEAM.md."
fi

# 2. core.hooksPath mutation. `git -c core.hooksPath=/dev/null push` and
#    `git config --unset core.hooksPath` both remove the gate outright, and the
#    second one persists for every worktree in the clone. The documented setup
#    command is the single permitted form.
if has 'core\.hooksPath'; then
    if ! printf '%s' "$command" | grep -qE '^[[:space:]]*git[[:space:]]+config[[:space:]]+core\.hooksPath[[:space:]]+hooks[[:space:]]*$'; then
        deny "Blocked: changing core.hooksPath disables hooks/pre-push — for this command, or for every worktree in the clone if it is written to config. The only permitted form is the documented setup: git config core.hooksPath hooks"
    fi
fi

# 3. Force-push, in each of its spellings. Only on a push; -f means other
#    things elsewhere, and a refspec leading + is a force push with no flag.
if has '(^|[[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
    if has '(^|[[:space:]])--force([[:space:]]|=|$)' \
    || has '(^|[[:space:]])--force-with-lease' \
    || has '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)' \
    || has '(^|[[:space:]])\+[^[:space:]]*:'; then
        deny "Blocked: force-pushing rewrites published history. No agent force-pushes here — if a branch needs rewinding, say what and why and let the user do it."
    fi
fi

# 4. Writes to the guardrail files themselves.
#
#    Enumerating write TOOLS is a losing game: the allow list carries
#    python3, sed, cp and mv, any of which can rewrite this script or
#    settings.json, and no list of banned verbs stays complete. So protect the
#    ASSETS instead — anything that looks like a write aimed at a protected
#    path needs a human, whatever tool it uses.
#
#    "ask", not "deny": maintaining these files is legitimate, it just should
#    never happen silently on an agent's own initiative.
protected='(^|[[:space:]"'"'"'/])(hooks/(pre-push|block-gate-bypass|check-core-purity)|\.claude/settings\.json)'
if has "$protected"; then
    if has '>[>]?[[:space:]]*[^|&[:space:]]*(hooks/|\.claude/settings\.json)' \
    || has '(^|[[:space:]])(cp|mv|rm|touch|chmod|chown|ln|install|truncate|tee)([[:space:]]|$)' \
    || has '(^|[[:space:]])(sed|perl|awk)([[:space:]][^|;]*)?[[:space:]]-i' \
    || has '(^|[[:space:]])(python3?|ruby|node|perl|osascript)([[:space:]]|$)'; then
        ask "This writes to a guardrail file (hooks/ or .claude/settings.json). Those are what keep the pre-push gate and the permission denies in force, so a change to them needs you, not an agent acting on its own. Say what should change and why."
    fi
fi

exit 0
