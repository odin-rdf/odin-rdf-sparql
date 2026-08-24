---
id: as-of-still-costs-this-engine
level: task
title: "As-of still costs this engine nothing: SPARQL-T-0025's scenarios onto store_at"
short_code: "SPARQL-T-0034"
created_at: 2026-08-24T20:42:37.966524+00:00
updated_at: 2026-08-24T20:42:37.966524+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] **`sparql/kvstore/as_of_test.odin`'s scenarios move and pass**
      against `store_at`. The fixture's design survives: it **retracts**,
      because an answer that only ever grows can also be produced by a
      read that stopped early, where a solution that comes back from the
      past cannot; and every assertion names the HEAD answer it is *not*,
      because a query returning the same thing either way is satisfied by
      an engine that ignores the handle it was given.
- [ ] **No non-test source changes to make this work.** If any does, that
      is the finding — record it here rather than quietly making the
      change, because the whole claim of this task is that the capability
      arrives by being in the right place.
- [ ] **Three record behaviours that differ from the store are pinned**,
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
- [ ] **`store_at(0)` — the empty world before the first commit — answers
      a query**, returning no solutions rather than failing. The store had
      `EPOCH_NEVER`; record has epoch 0, and the difference is worth one
      test.
- [ ] The W3C suites are untouched by this task. They cannot produce
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

*To be added during implementation*
