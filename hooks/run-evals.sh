#!/bin/sh
# Rung 2: the scenario evals, with a floor under what counts as a pass.
#
# `swift test --filter WeightTrainingEvals` exits 0 and prints
# "Executed 0 tests ... passed" when the filter matches nothing — so on a tree
# without the target, the longitudinal gate reports success having run nothing.
# That is an unrun rung reading as a pass, which is the one failure this
# project's whole verification story is built to prevent. Measured on main at
# faa383e: exit 0, zero tests.
#
# So: zero scenarios is a FAILURE here, never a pass. The distinction the
# caller needs is *why* it was zero, which is what the two messages below say.

set -e
filter=${1:-WeightTrainingEvals}

if ! output=$(swift test --filter "$filter" 2>&1); then
    printf '%s\n' "$output" | grep -E 'error:|failed|XCTAssert|Test Case.*failed' | head -30
    printf '\n  Evals failed. An invariant breach is blocking — it means the\n'
    printf '  engine proposed something it must never propose. A failed\n'
    printf '  expectation is a judgement about training and is the lifter'"'"'s call.\n'
    exit 1
fi

xctest=$(printf '%s\n' "$output" | grep -oE 'Executed [0-9]+ tests?' \
    | grep -oE '[0-9]+' | sort -rn | head -1)
swifttesting=$(printf '%s\n' "$output" | grep -oE 'Test run with [0-9]+ tests?' \
    | grep -oE '[0-9]+' | sort -rn | head -1)
count=$(( ${xctest:-0} + ${swifttesting:-0} ))

if [ "$count" -eq 0 ]; then
    if ! grep -q "$filter" Package.swift 2>/dev/null; then
        printf '  FAIL — no %s target in Package.swift.\n\n' "$filter"
        printf '  swift test exits 0 on a filter that matches nothing, so this\n'
        printf '  would otherwise read as a passing longitudinal gate on a tree\n'
        printf '  that cannot run one. The harness arrives with the branch that\n'
        printf '  adds the target; until then rung 2 is UNAVAILABLE, not green.\n'
    else
        printf '  FAIL — the %s target exists but matched no scenarios.\n\n' "$filter"
        printf '  Check the filter spelling and that Scenarios.all is non-empty.\n'
    fi
    exit 1
fi

printf '  %s scenarios ran.\n' "$count"
exit 0
