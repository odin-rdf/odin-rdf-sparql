---
id: as-of-still-costs-this-engine
level: task
title: "As-of still costs this engine nothing: SPARQL-T-0025's scenarios onto store_at"
short_code: "SPARQL-T-0034"
created_at: 2026-08-24T20:42:37.966524+00:00
updated_at: 2026-08-25T16:00:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# As-of still costs this engine nothing: SPARQL-T-0025's scenarios onto store_at

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Preserve the property `SPARQL-T-0025` established and pinned: **a query
against a past dataset is this engine's ordinary evaluation through a
different handle**, with no temporal SPARQL syntax, no as-of constructor,
and no line of non-test source written to allow it.

That was true on odin-rdf-store because `query_init_txn` took a `^Txn`
and `txn_begin_as_of` returned one. It should be true on record for the
same structural reason — `store_at(s, epoch)` returns an ordinary
`Snapshot` and `query_init` takes one — but "should be" is exactly what
`SPARQL-T-0025` refused to accept about the store. Port the tests, not
the assumption.

## Acceptance Criteria

- [x] **`sparql/kvstore/as_of_test.odin`'s scenarios move and pass**
      against `store_at`. The fixture's design survives: it **retracts**,
      because an answer that only ever grows can also be produced by a
      read that stopped early, where a solution that comes back from the
      past cannot; and every assertion names the HEAD answer it is *not*,
      because a query returning the same thing either way is satisfied by
      an engine that ignores the handle it was given.
- [x] **No non-test source changes to make this work.** If any does, that
      is the finding — record it here rather than quietly making the
      change, because the whole claim of this task is that the capability
      arrives by being in the right place.
- [x] **Three record behaviours that differ from the store are pinned**,
      each with a test:
      - `store_at` past head is `.Future_Epoch` — **refused, not
        clamped**. The store's horizon had no equivalent refusal.
      - **There is no `epoch_at(wall)`.** The store turned a wall-clock
        time into a horizon; record's as-of coordinate is the epoch, and
        `wall` in `snapshot_epoch_meta` is advisory. A caller holding a
        time finds its epoch itself. Note this as a capability the port
        loses — small, real, and worth stating in SPARQL-T-0039 rather
        than discovering later.
      - **Terms are not epoch-scoped; facts are.** A term resolves at
        every epoch, including before it was first written, so
        `store_at(0)` resolves a graph label and reads an empty graph
        through it. This is the record's version of the store's
        deliberately non-temporal dictionary, and the existing test that
        pins that division should port across almost unchanged — it is
        the same correct division reached by a different mechanism.
- [x] **`store_at(0)` — the empty world before the first commit — answers
      a query**, returning no solutions rather than failing. The store had
      `EPOCH_NEVER`; record has epoch 0, and the difference is worth one
      test.
- [x] The W3C suites are untouched by this task. They cannot produce
      these scenarios: no entry edits its dataset after loading it, so no
      entry has a second epoch to read at, and an engine that silently
      ignored the handle would pass all 474 of them. That is why this task
      exists.

## Implementation Notes

### Technical Approach

The mechanical change is `txn_begin_as_of(s, horizon)` →
`store_at(s, epoch)`, and `txn_abort` → `snapshot_release`. The fixture
needs two epochs, so it needs two `apply` calls — which is where the
record fact "a candidate is the delta" bites: the second edit is *what
the write adds*, not the document again. The existing fixture already has
this shape (`FIRST_EDIT`, `SECOND_EDIT`), which is lucky rather than
planned.

The retraction half needs `Op_Kind.Retract` in a `Changeset` rather than
`store.remove(ds, pattern)`. Note the semantic difference and pin it:
record retracts a *named quad*, the store retracted everything matching a
`Match_Pattern`. A fixture that retracted by pattern must name its quads.

The old file's comment about `open_ephemeral` being correct here — every
write completing before any read opens, so this is not the
reader-across-writer arrangement `NOLOCK` forbids — is store lore and
should be replaced rather than translated. record's equivalent property
(readers are safe under a live writer because the published index set
carries copies of every list a reader indexes) is stronger and needs no
fixture discipline at all.

### Dependencies

Blocked by SPARQL-T-0033 — the harness must be green before a capability
test on top of it means anything.

### Risk Considerations

Low. The most likely outcome is that this task is short and finds
nothing, which is the result `SPARQL-T-0025` was written to make
checkable rather than assumed.

The one thing that would make it long: if `query_init`'s snapshot
handling in SPARQL-T-0031 accidentally re-acquires `store_latest`
anywhere instead of using the snapshot it was handed, every as-of test
fails and the bug is in the *core*, not here. That would be a good bug to
find, and it is the reason this task follows the harness rather than
running in parallel with it.

## Status Updates

### 2026-08-25 — done, and it found nothing, which is the result

Four tests in `sparql/as_of_test.odin`, all green. **`git status` after
the work shows one added file and nothing else**: no non-test source
changed, which was this task's real criterion and the whole of what
SPARQL-T-0025 established. As-of arrives by `store_at` returning an
ordinary `Snapshot` and `query_init` taking one — the same structural
reason it arrived on odin-rdf-store, reached through a different handle.

The risk note's one way this could have been long — `query_init`
re-acquiring `store_latest` somewhere instead of using the snapshot it
was handed — did not happen. Every as-of answer differs from HEAD's, so
an engine that ignored its snapshot would fail all four.

#### What the port made simpler

**There is one `answer_at`, where there were two.** The old file had
`answer_at_head` and `answer_as_of`, differing only in which constructor
they called — `query_init` against the store, `query_init_txn` against a
transaction carrying a horizon. On record there is one constructor and
one kind of handle, so reading the past and reading the present are the
same procedure called with a different snapshot. The file's shape is now
the claim.

**The epoch comes back from `apply`.** The old fixture read the clock
after each commit and converted it with `epoch_at(wall)`, carrying a
paragraph on why that was deterministic — and a warning that a timestamp
captured *between* two commits would name the wrong epoch on a platform
with a coarse clock. None of it applies.

#### The three record behaviours, pinned

- **`store_at` past head is `.Future_Epoch` — refused, not clamped.**
  odin-rdf-store's `EPOCH_LATEST` read HEAD, so a caller that computed a
  horizon wrongly got an answer; record makes the same mistake a
  diagnostic. Nothing in this engine chose either, which is the point.
- **`store_at(0)` is the empty world and answers a query** rather than
  failing, returning no solutions where HEAD returns two edges. The store
  spelled it `EPOCH_NEVER`, a reserved value; record spells it 0, one
  below the first epoch it issues.
- **Terms are not epoch-scoped; facts are.** `:dave`, interned at epoch
  2, still resolves through a snapshot at epoch 1 and matches nothing
  there. Both halves are asserted, because if binding had failed to
  resolve it the query would return the same empty answer for an entirely
  different reason. This is odin-rdf-store's deliberately non-temporal
  dictionary reached by a different mechanism: an index set bounds
  *facts* by epoch and *terms* by the count it published with.

#### One capability the port loses, for SPARQL-T-0039

**There is no `epoch_at(wall)`.** The store turned a wall-clock time
into a horizon. record's as-of coordinate is the epoch, and `wall` in
`snapshot_epoch_meta` is advisory evidence rather than an index — so a
caller holding a time and wanting the epoch it belongs to must walk the
epoch metadata itself. Small, real, and stated here rather than
discovered later. Nothing in this repository needed it; the fixture
needed it only because the store gave it no other way to learn an
epoch, and `apply` returns one.

#### One thing that got narrower, and correctly

**A retraction names its quad.** odin-rdf-store spelled it
`remove(ds, pattern)` over a `Match_Pattern`, so "retract everything
:bob :knows" was one call. record retracts a named quad, refused with
`.Not_Live` if no live generation matches — more work for a fixture, a
narrower promise, and the narrower promise is why `.Not_Live` can exist
at all. Either way it is a tombstone rather than an erasure, which is
what keeps the earlier epochs readable.
