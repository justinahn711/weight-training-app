# Round-trip evals (#87, #88)

`ArchiveTests` proves the backup round-trips *one* carefully-built history.
These ask whether it round-trips *every shape of history the app produces* —
warmups, half-point efforts, a measured apparatus, a lift loaded by bodyweight,
a session straddling midnight, six months of training.

```sh
swift test --filter WeightTrainingStoreEvals
```

## The properties

For every shape in `Corpus.all`, exported and restored into a store that has
never seen it:

| Property | Why it isn't covered by row equality |
|---|---|
| every row comes back | the floor |
| what the lifter reads is unchanged | #88's done-when says "history, records **and trends**" — derived data is recomputed, so identical rows can still produce different answers |
| timestamps survive to the instant | which calendar day an instant lands on depends on the calendar you ask with; what a restore owes you is the unshifted instant (#79) |
| a restored store exports the same document | two backups of one history that differ can't both be trusted, and diffing them is the cheap way to check one |
| importing twice changes nothing | the second tap of a worried person |

Plus: a restore onto a phone that kept training keeps both histories, a file
from a later build is refused rather than half-read, and a store restored from
its own archive is unchanged.

## Corpus, not fixture

The shapes exist because each one is a way the round trip could fail while a
single hand-built fixture passed. Warmups are excluded from every statistic, so
they're the rows an export written against the insight layer would drop. RPE
6.5 is storable but never offered as a chip, so it's the value most likely to
be rounded away. `LoadingStyle` rides inside the exercise, so losing it makes
plate breakdowns disagree with the rack.

Add a shape whenever you find a kind of history the app can produce that isn't
here. A metric gym (#67) belongs in this list once that branch lands — it isn't
here because `MassUnit` doesn't exist on this branch.

## Two traps

**Dates are anchored to a fixed midday**, never built from `Date()`: the store
groups sets by calendar day, and a fixture near midnight straddles two of them
(#79). `eitherSideOfMidnight` does this deliberately, and must keep doing it.

**Fixture timestamps are whole seconds.** The archive format preserves stamps
to the millisecond, not exactly — ISO-8601 fractional seconds are three digits
and `Date` carries more. `ArchivePrecisionEvals` pins that contract.
