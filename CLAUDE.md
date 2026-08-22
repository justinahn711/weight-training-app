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
