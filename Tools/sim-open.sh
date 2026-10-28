#!/bin/sh
# Opens the installed Debug app on a simulator in a known state, ready for a
# screenshot. See UITestLaunchRoutes.swift for the fixtures and routes.
#
#     sh Tools/sim-open.sh <fixture> [route]
#     sh Tools/sim-open.sh history progress
#     sh Tools/sim-open.sh history session:push
#     SIM=<udid> sh Tools/sim-open.sh fresh      # required when two are booted
#
# Always on the isolated store, reset first, so it never reads or writes the
# simulator's own training data and never syncs to iCloud.
#
# Checks that the process really got its arguments (#321). Right after
# `simctl install`, iOS can start the app on its own, without them, and
# `simctl launch` then reports that process: it opened on the real store,
# measured on 2026-10-25. The running process's command line is the proof,
# so this reads it, relaunches once if the arguments are missing, and fails
# rather than handing back a screen that isn't the one asked for.

set -e
fixture=${1:?usage: sh Tools/sim-open.sh <fresh|history> [route]}
route=$2
bundle=com.justinloves.ChickenBreast

# Never "booted" when more than one is. Another agent's UI test run boots its
# own simulator (ChickenBreast-SE), and "booted" can resolve to that one: the
# terminate below then kills the app in the middle of their test. That
# happened while this script was being written.
sim=$SIM
if [ -z "$sim" ]; then
    booted=$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\) \(Booted\)' | cut -c2-37)
    if [ "$(printf '%s\n' "$booted" | grep -c .)" -ne 1 ]; then
        printf 'sim-open: %s simulators are booted. Name one: SIM=<udid> sh Tools/sim-open.sh ...\n' \
            "$(printf '%s\n' "$booted" | grep -c .)"
        xcrun simctl list devices booted | grep Booted
        exit 1
    fi
    sim=$booted
fi

set -- -UITestIsolatedStore -UITestResetState -UITestFixture "$fixture"
[ -n "$route" ] && set -- "$@" -UITestRoute "$route"

pid=
for attempt in 1 2; do
    xcrun simctl terminate "$sim" "$bundle" 2>/dev/null || true
    pid=$(xcrun simctl launch "$sim" "$bundle" "$@" | awk '{ print $NF }')
    if ps -p "$pid" -o command= | grep -q -- '-UITestIsolatedStore'; then
        break
    fi
    printf 'sim-open: pid %s started without its arguments; relaunching (#321)\n' "$pid"
    pid=
done
if [ -z "$pid" ]; then
    printf 'sim-open: the app never started with -UITestIsolatedStore. Not continuing,\n'
    printf '          because what is on screen is the real store.\n'
    exit 1
fi

# The fixture logs one line when its data is written. Each `log show` takes
# about a second, so this polls for roughly a minute.
for _ in $(seq 1 45); do
    ready=$(xcrun simctl spawn "$sim" log show --last 2m --style compact \
        --predicate "processID == $pid AND eventMessage CONTAINS \"fixture $fixture ready\"" \
        2>/dev/null | grep -o 'fixture .* ready in .*' || true)
    if [ -n "$ready" ]; then
        printf 'sim-open: pid %s, %s%s\n' "$pid" "$ready" "${route:+, route $route}"
        exit 0
    fi
done
printf 'sim-open: pid %s never logged "fixture %s ready". Check the name\n' "$pid" "$fixture"
printf '          (fresh, history) and that a Debug build is installed.\n'
exit 1
