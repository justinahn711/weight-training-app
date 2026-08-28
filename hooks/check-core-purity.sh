#!/bin/sh
# Rung 3: WeightTrainingCore imports Foundation only.
#
# One script, called by both hooks/pre-push and .github/workflows/tests.yml,
# because the previous arrangement had the rule written out twice and they
# drifted: the hook was fixed and CI was not, while every agent brief defines
# rung 3 as "the grep in tests.yml" — so the documented check was the weak one.
#
# Written as an allowlist. A denylist of banned frameworks misses every form
# that still pulls one in: `import struct SwiftUI.Color`, `@preconcurrency
# import SwiftData`, an indented import, or any framework nobody enumerated.
# The invariant is "Foundation only", so that is what the pattern says.
#
# Run from the repo root. Exits 1 and prints the offending lines on failure.

set -e
root=${1:-Sources/WeightTrainingCore}

imports=$(grep -rnE '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*[[:space:]]+)*import[[:space:]]' \
    "$root" || true)

# Anchored to the whole line, so a comment or a second statement mentioning
# Foundation cannot exempt an import of something else:
#   import SwiftUI // like import Foundation
#   import SwiftUI;import Foundation
offenders=$(printf '%s\n' "$imports" | grep -vE \
    '^[^:]*:[0-9]+:[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*[[:space:]]+)*import([[:space:]]+(struct|class|enum|protocol|func|var|let|typealias))?[[:space:]]+Foundation[A-Za-z0-9_.]*[[:space:]]*$' \
    || true)

# grep -v on empty input yields one empty line; don't read that as an offender.
offenders=$(printf '%s' "$offenders" | sed '/^$/d')

if [ -n "$offenders" ]; then
    printf '%s\n' "$offenders" | sed 's/^/    /'
    printf '\n  WeightTrainingCore must import Foundation only. Any of these\n'
    printf '  moves the reasoning behind a simulator boot and costs the fast\n'
    printf '  suite — the change belongs in WeightTrainingStore or the app.\n'
    exit 1
fi
exit 0
