# Evals

The unit suite proves a single decision is correct. These prove a *sequence* of
correct decisions adds up to sensible coaching — which is a different question,
and the one that actually matters to someone following the app for a season.

Twelve individually-defensible sessions can still end with a lift that never
progresses, deloads into the floor, or asks for a weight the rack can't build.
Nothing in `Tests/WeightTrainingCoreTests` can see that, because none of it
runs the engine forward against its own output.

```sh
swift test --filter WeightTrainingEvals               # run them
EVAL_VERBOSE=1 swift test --filter EvalReportCard      # read what happened
```

## The shape of one

A scenario is a lifter, a starting load, and a number of sessions. The runner
puts the engine's own target in front of the lifter each session, records what
they did, feeds it back, and repeats. Nothing here reimplements a rule — an
eval carrying its own copy of the logic can only ever agree with itself.

```swift
public static var plateau: EvalScenario {
    EvalScenario(
        "plateau at 65 lb",
        exercise: exercise("Incline DB Press"),
        startingLoad: Load(50),
        sessions: 34,
        lifter: .stallsAbove(Load(65)),
        expectations: [.deloads(within: 34), .neverExceeds(Load(70))]
    )
}
```

Add it to `Scenarios.all` and assert it from `ProgressionEvals`.

## Invariants vs expectations

**Invariants** (`Invariants.swift`) hold for every scenario, always. They are
the promises the app makes about what a number on screen means: every proposal
is buildable, nothing falls below the lightest usable load, double progression
moves one increment at a time, a deload goes down and stays positive, rep
targets stay in range. A breach is a bug no matter what the scenario was
demonstrating.

**Expectations** are judgements about training, scoped to one scenario, and
revisable. "Gains at least 15 lb in 30 sessions" encodes an opinion; if the
progression rules change deliberately, the right response may be to change the
number rather than the engine.

## Writing a lifter

Lifters are closures over `(session, load, reps, exercise)`, because the
interesting cases are conditional on the load the engine arrived at — "fails
above 65 lb" can't be written as a fixture. See `Lifters.swift`.

## Two traps

**Never anchor to `Date()`.** The runner spaces sessions two days apart at
midday deliberately: the store groups sets by calendar day, so minute-offset
fixtures straddle midnight and split one session into two, which failed for
real at 23:56 (#79). Deload triggers count *sessions of this exercise*, so a
run whose sessions collapsed would silently stop testing what it claims to.

**Watch for a scenario that passes vacuously.** A plateau eval that never
reaches the plateau is green and worthless. `EVAL_VERBOSE=1` prints the
timeline; read it once when you add a scenario, and confirm it actually gets
where it says it does.
