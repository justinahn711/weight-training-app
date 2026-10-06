# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Built for its owner first: one lifter training a push/pull/legs cycle, logging
every set on an iPhone at the gym. A wider release to recreational lifters
(healthy adults training for muscle and steady strength, the provisional
audience in `docs/recommendation-engine-plan.md`) is planned for later, not
now. Design for the expert daily user; keep it approachable enough that a
later audience wouldn't need a different app. Don't build for strangers yet.

## Product Purpose

A training log that also coaches. It records what was actually lifted, and
from that history proposes the next load, reps, sets and effort target for
each exercise. Success: logging never slows a workout down, and the
proposals are trusted because they're grounded in the lifter's own history
and explained in a sentence.

## Positioning

The proposal and the record are one surface. The app works out what to try
next from the sets just logged (double progression, RPE, deloads, plate
math against the gym's real rack, weekly volume per muscle), and the lifter
logs against it, adjusts it, or ignores it in the same tap. It suggests; it
never decides.

## Operating Context

- **Mid-set, one glance:** the screen is read from the bench between sets.
  The next number has to land in a single look.
- **Minimal friction:** logging a set must be fast. The common case, doing
  what was proposed, is one tap. Owner's words: "minimal friction so users
  can log sets really fast."
- Logging also works by voice and from the lock screen (Live Activity, App
  Intents). Data syncs over iCloud (CloudKit, private database) and can be
  exported and restored from a file the lifter owns.

## Capabilities and Constraints

- Push/pull/legs split with a cycle position; day templates with swappable
  lifts; warmup ramps; rest timer with alerts; plate breakdowns against the
  gym's configured rack; per-exercise equipment and increments; history,
  records, e1RM trends, weekly volume per muscle; a readiness digest;
  set plans and automatic recommendations (#316); early-finish reasons.
- Derived data (records, volume, trends, readiness) is computed from logged
  sets, never stored. Warmups count only in history.
- Every proposed load must be one the equipment can actually make
  (`Exercise.nearestAchievable`).
- **Open decision:** since #316 a set plan *activates automatically* for a
  lift. That sits uneasily with "it suggests, I decide" (below). Whether an
  automatic plan should stay, become an explicit opt-in, or read as plainly
  as a suggestion is undecided.

## Brand Commitments

- Name: ChickenBreast.
- "Suggest, never change": the app proposes and the lifter decides. The one
  exception is a digest deload bullet, which applies a target when tapped
  and says so.

## Evidence on Hand

The owner's own training history in the app. No testimonials, users,
reviews, or outcome claims exist; future work must not invent them.

## Product Principles

1. **Logging is the hot path.** Any screen element earns its place by making
   the next set faster or clearer to log, or it waits until the set is done.
2. **One glance from the bench.** The next number and the action to take must
   read at arm's length without hunting.
3. **Suggest, never decide.** Proposals are explained, easy to accept, and
   easy to override; nothing changes the lifter's plan without saying so.
4. **Honest numbers.** Unknown means silent: no plate line for an unmeasured
   machine, no readiness from a thin baseline, no record from a first session.
5. **Expert first, ready for others.** Optimise for daily use; don't add
   ceremony for a hypothetical newcomer, but don't rely on knowledge only the
   owner has.

## Accessibility & Inclusion

Existing commitment, enforced in CI by `SystemAuditUITests`: the session
screens pass the system accessibility audit (Dynamic Type through the
accessibility sizes, VoiceOver labels, 44 pt tap targets, contrast, with
documented exceptions for content under bars). Reduce Motion is honoured.
