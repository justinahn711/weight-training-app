#!/bin/sh
# Design tokens: a branch adds no new raw layout literal to the app.
#
# DESIGN.md names the spacing scale, the radii and the text roles, and
# `Theme` defines them in code (`Theme.Space`, `Theme.Radius`,
# `Theme.Typography`). The drift never came from the document. It came from
# the next view, written without the document open. So this checks only the
# lines a branch adds. The literals already on main block nothing, and they
# switch to tokens when their line is edited for another reason.
#
# On an added line under ChickenBreast/ChickenBreast/ (Theme.swift excepted),
# this flags:
#   .padding(…12…)  spacing: 6  cornerRadius: 10   a number where a token goes
#   Color(red:  Color(white:  Color(hue:            a colour Theme doesn't name
#   .caption2   .system(size: 13                     DESIGN.md's type Don'ts
#
# `spacing: 0` passes, because 0 is not a design value. A deliberate off-scale
# value, like an optical nudge or a ring's stroke inset, passes when the same
# line carries `// off-scale: <why>`. The reason is required: a bare marker
# still fails.
#
# Compares the working tree, including uncommitted edits to tracked files,
# against its merge base with origin/main (or $1). Run from the repo root.
# Exits 1 and prints file:line for each offender.

set -e
base=${1:-origin/main}

if ! merge_base=$(git merge-base HEAD "$base" 2>/dev/null); then
    printf '  Cannot find %s to compare against. Run: git fetch origin main\n' "$base"
    exit 1
fi

# Added lines only, as file:line: text, so a failure says where to look.
added=$(git diff -U0 "$merge_base" -- \
    'ChickenBreast/ChickenBreast/*.swift' \
    ':(exclude)ChickenBreast/ChickenBreast/Theme.swift' | awk '
    /^\+\+\+ / { file = substr($0, 7); next }
    /^@@/      { split($3, range, ","); line = substr(range[1], 2) + 0; next }
    /^\+/      { print file ":" line ": " substr($0, 2); line++ }
')

offenders=$(printf '%s\n' "$added" \
    | grep -E '\.padding\([^)]*[0-9]|spacing: *([1-9]|0\.)|cornerRadius(: *|\( *)[0-9]|Color\((red|white|hue):|\.caption2|\.system\(size: *[0-9]' \
    | grep -vE '// off-scale: *[^ ]' \
    || true)

if [ -n "$offenders" ]; then
    printf '%s\n' "$offenders" | sed 's/^/    /'
    printf '\n  Use Theme.Space, Theme.Radius, Theme.Typography or a named Theme\n'
    printf '  colour (DESIGN.md has the scale). For a value that really is off\n'
    printf '  the scale, add `// off-scale: <why>` on the same line.\n'
    exit 1
fi
exit 0
