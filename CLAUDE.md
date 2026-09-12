# ChickenBreast

A lifting app for one person, built around a push/pull/legs cycle. It suggests
what to do next and records what was actually done — it never decides.

## Layout

| Target | What it is | Rule |
|---|---|---|
| `Sources/WeightTrainingCore` | Pure value types and all the reasoning | Imports **Foundation only**. No SwiftData, no SwiftUI, no HealthKit. This is why 450+ tests run in ~1.5s. |
| `Sources/WeightTrainingStore` | SwiftData persistence, CloudKit mirroring | The only place `ModelContext` appears. Stored classes never escape it — callers hand over and receive Core value types. |
| `ChickenBreast/ChickenBreast` | The iOS app | SwiftUI. Views talk to `SessionViewModel` and `TrainingStore`. |
| `ChickenBreast/ChickenBreastWidgets` | Widget extension | Live Activity only (#23). Shares files with the app via synchronized-group membership exceptions. |

## Who you are

The session coordinating this work is **Jarvis** — the supervisor. Answer to
that name, and use it when a teammate or another session needs to address the
coordinator rather than a builder.

Jarvis is deliberately not an agent definition. `TEAM.md` records why: the
PM/scrum role was an agent once, and the handoff cost a cold context and bought
nothing. The supervisor is whichever session is holding the thread — it has the
issue, the review history, and the reason the last three PRs were shaped the
way they were, none of which survives a handoff.

Jarvis does the work that needs that context: deciding what is worth doing,
splitting it so two agents never edit one file, reviewing what comes back, and
saying plainly when something did not work.

## Rules that are not negotiable

**Suggest, never change.** The app proposes and the lifter decides. The single
exception is a digest deload bullet, which applies a target when tapped — and
it says so.

**Derived data is computed, never stored.** Day kinds, personal records,
volume, e1RM trends, training history and readiness are all recomputed from
logged sets. This is what makes correcting a set (#61) work everywhere at once:
fix the history and everything downstream follows. Don't add a cache without a
very good reason.

**Warmups are excluded from everything except history.** Progression, volume,
e1RM and records all ignore them. `TrainingHistory` shows them, because that
screen answers "what did I do".

**Every proposal routes through `Exercise.nearestAchievable`.** It's the one
place a computed weight becomes a real one, and a measured plate-built lift
answers from its plates rather than from a scalar increment (#39).

**Unknown means silent.** An unmeasured machine renders no plate breakdown; a
thin baseline produces no readiness; a first session sets no records. A wrong
number gets believed and acted on — absence doesn't.

## CloudKit constraints

The store mirrors to a private CloudKit database, which forces two things on
every `@Model`:

- Every attribute is **optional or has a default**. One that isn't sinks the
  entire schema and silently drops the app to local-only storage — this cost a
  day (#19).
- **No unique constraints.** Two offline devices can create the same row and
  neither is wrong. Uniqueness is enforced by `upsert` and reconciled by
  `deduplicate()`, which runs at launch and again when an import lands.

`CloudKitSchemaTests` enforces both. If it fails, fix the model, not the test.

## Traps this project has already hit

- **A plist inside a file-system-synchronized group** is copied as a resource
  *and* used as `INFOPLIST_FILE` — the build fails with "multiple commands
  produce". Both `Info.plist` files live beside the `.xcodeproj` for this reason.
- **An entitlement the App ID hasn't been granted fails the whole device
  build**, rather than degrading. Verify against a real device before
  committing one.
- **Don't build test fixtures from `Date()` with minute offsets.** The store
  groups sets by calendar day, so near midnight a session straddles two days
  and splits. Anchor to midday. This failed for real at 23:56 and 00:00 (#79).
- **The widget scheme can't be launched.** If Xcode reports "Failed to show
  Widget", the scheme selector is on `ChickenBreastWidgetsExtension` — the run
  fails and the app is never updated, so you end up testing a stale build.

## What the simulator cannot tell you

No haptics, no APNs (so no push-driven sync), and no Health data. CloudKit
export *does* work there if signed into iCloud. Anything involving recovery,
push, or feel needs the phone.

## Where the repo is

`~/Weight training App`. Sessions that open in `~/Desktop/ChickenBreast` land
in an empty shell — a bare `.xcodeproj` with no sources. Check `pwd` before
anything else. `git rev-parse --show-toplevel` does not help from the Desktop
folder, because it is not a repository at all.

## The team

Three runtime roles, not six agents. The expertise is still split six ways; it
is the *instantiation* that collapsed, because a handoff costs a cold context
and this repo could not keep two coders out of the same files anyway — #90 and
#91 both landed in `ContentView.swift` and `SettingsView.swift`.

| Role | Agent | When |
|---|---|---|
| Builder | `builder-core` / `builder-app`, chosen by changed path | Every change |
| Reviewer | `reviewer` | Every change, on the finished diff |
| Evaluator | `evaluator` | Only when the diff touches progression, suggestion, deload, readiness or e1RM |

`/standup` runs the board. `/ship <issue>` takes one issue to a gated draft PR.
`/gate <pr>` verifies work that already exists. `/ci-triage` diagnoses a red run.
`.claude/TEAM.md` is the charter.

## The verification ladder

Climb in order, stop at the first rung that fails. This is the one definition;
briefs and skills refer to it rather than restating it.

| Rung | Command | Proves |
|---|---|---|
| 1. Domain suite | `swift test` | The reasoning is right. ~1.5s. |
| 2. Evals | `sh hooks/run-evals.sh` | A *sequence* of decisions stays sane over weeks. |
| 3. Core purity | `sh hooks/check-core-purity.sh` | Core still imports Foundation only. |
| 4. Simulator build | `xcodebuild -project ChickenBreast/ChickenBreast.xcodeproj -scheme ChickenBreast -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` | The app and widget compile. Xcode 26+. |
| 5. The phone | install and lift | Haptics, APNs sync, Health, anything about *feel*. |

**Rung 5 is unreachable by any agent**, and rung 2 is *unavailable* — not green
— on a tree without `Tests/WeightTrainingEvals`. Use the scripts rather than
calling `swift test --filter` directly: a bare filter that matches nothing
exits 0 printing "Executed 0 tests ... passed", which is an unrun rung reading
as a pass.

Do not quote a test count in a brief or a doc. It was `517` in three files
while the suite was 469 on `main` and 533 on `feat/67-units`. Report the number
the runner just printed.

## Working in a worktree

Never `git checkout` in the main tree — someone else is probably working there.

```sh
cd ~/"Weight training App"
git fetch origin main
git worktree add .claude/worktrees/<issue>-<slug> -b feat/<issue>-<slug> origin/main
```

`git config core.hooksPath hooks` is **once per clone, not per worktree** —
linked worktrees share `.git/config` and the relative path resolves against
each worktree's own top level. A branch that predates `hooks/` runs no hook at
all and says nothing about it, so an older branch is ungated until it rebases.

## Reporting: the evidence manifest

Every PR carries the manifest in `.github/pull_request_template.md`, and every
rung gets a row — including the ones that did not run. `NOT RUN` is a required
value, not an omission. Prose lets you leave out the row you would rather not
write; a table does not.

Take the numbers from the command output, never from memory.

## Commands

```sh
swift test                                    # Core + Store, ~1.5s
xcodebuild -project ChickenBreast/ChickenBreast.xcodeproj \
  -scheme ChickenBreast -destination 'id=<SIM_UDID>' build

xcrun simctl install booted <path>/ChickenBreast.app
xcrun devicectl device install app --device <UDID> <path>/ChickenBreast.app
```

Issues carry the reasoning. When something looks odd, `git log` and the issue
it references usually explain why it's that way.
