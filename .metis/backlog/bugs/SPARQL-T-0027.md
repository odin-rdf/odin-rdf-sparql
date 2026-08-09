---
id: synthetic-term-ids-collided-with
level: task
title: "Synthetic term IDs collided with the store's new NAMED_GRAPHS sentinel"
short_code: "SPARQL-T-0027"
created_at: 2026-08-09T11:55:00+00:00
updated_at: 2026-08-09T12:01:58.190860+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: NULL
---

# Synthetic term IDs collided with the store's new NAMED_GRAPHS sentinel

## Objective **[REQUIRED]**

Every evaluation test in the repository aborted, on an assertion from the
backend:

```
runtime assertion: match: NAMED_GRAPHS outside the graph position
```

A query that computes a term — `BIND(?a + ?b AS ?c)`, a VALUES cell naming
a term the store does not hold, a path endpoint that is not in the data —
cannot bind a store ID to it, because interning it would make reading a
write. So the engine names such terms itself, in the Sentinel space the
store promises never to assign, and `SYNTHETIC_FIRST` in
`sparql/expr_eval.odin` was where that space began.

It was the literal `3`, with a comment explaining the number: "counters 0,
1, and 2 are DEFAULT_GRAPH, WILDCARD, and UNBOUND, and … counters from 3 up
are unused". True when written. odin-rdf-store's `STORE-T-0017` then added
a fourth sentinel, `NAMED_GRAPHS`, on counter 3 — so the **first computed
term of every query became the named-graph wildcard**, and the first time
one reached a match pattern kvstore asserted, as it is entitled to.

Not caught by CI, and that is the interesting part: CI pins odin-rdf-store
at `v0.5.0`, where `NAMED_GRAPHS` does not exist. It appears only against a
sibling checkout of the store's `main`, which is where the next release
comes from.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Bug - Something is broken

### Priority
- [x] P0 - Critical (blocks work)

Nothing in this repository could be measured while it stood: the whole
evaluation suite aborted on the first computed term.

### Bug Details **[CONDITIONAL: Bug]**

**Steps to reproduce**: check out odin-rdf-store at `main` (any commit from
`STORE-T-0017`, 2026-08-09, onward) as the `store:` collection, and run
`make test`.

**Expected**: the suite runs.

**Actual**: `runtime assertion: match: NAMED_GRAPHS outside the graph
position`, from `match_txn` in `store/kvstore/dataset.odin`.

**Root cause**: two ID spaces sharing a counter, because this engine
described the store's space by *observing* it rather than by naming the
boundary the store publishes. `store.SENTINEL_CONSUMER_FIRST` — Sentinel
counter 8 — has existed since v0.5.0 and says exactly this: counters at and
above it belong to the layer above, and the store will never assign one,
"not to a term, and not to a future sentinel of its own"
(`STORE-T-0021`). The store wrote that rule down the day before it took
counter 3, and it is the reason taking counter 3 was safe. This engine had
simply never adopted the constant — its own comment even cites
`SYNTHETIC_FIRST` as the motivating consumer, from the store's side.

**Fix**: `SYNTHETIC_FIRST :: store.SENTINEL_CONSUMER_FIRST`, with the
arithmetic moved from the counter to the ID (the counter is the low bits,
so adding an index to the base ID walks the counter and leaves the tag
alone). No store change, and no new store release: the constant this needed
has been released since v0.5.0.

**Not reproducible after**: the whole suite, both `Term_ID` widths, back to
the position it held before the store's `main` moved.

## Acceptance Criteria **[REQUIRED]**

- [x] The synthetic space is derived from `store.SENTINEL_CONSUMER_FIRST` and no literal counter appears in this repository.
- [x] `make test` green at both widths against a `main` checkout of odin-rdf-store.
- [x] The comment says why the base is the store's constant and not a number, so the next reader does not re-derive `3`.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Risk Considerations

The general shape is worth naming, because the fix does not remove it: **CI
pins the store, so this repository is blind to a store change until the pin
moves.** That is the right trade for reproducibility, and it means a class
of breakage is discovered by whoever next runs the suite against a sibling
checkout rather than by a machine. Here that was a hard assert, which is
the good case — the store's own note on this space warns of the bad one, a
collision where "nothing would fail loudly: a query would simply start
matching the wrong thing."

## Status Updates **[REQUIRED]**

- **2026-08-09 — Found and fixed during SPARQL-T-0020**, which could not
  take a baseline measurement until the suite ran at all. Filed after the
  fact so the cause is on the record rather than buried in another task's
  diff; the fix is in that task's commit.

- **2026-08-09 — Completed, and the fix verified in both directions.**
  `store.SENTINEL_CONSUMER_FIRST` is counter 8 in `v0.5.0` and in the
  store's `main` alike, so the base is the same constant either way. Both
  checkouts were built and run: every package, both `Term_ID` widths,
  against a `v0.5.0` worktree and against `main`. Green in all four
  combinations.

  That measurement was taken to settle a different question — whether this
  repository could be pushed on its current pin — and it answers this one
  too. It is worth stating because the old `SYNTHETIC_FIRST :: 3` also
  passed against `v0.5.0`: the bug was invisible from the pinned side,
  which is exactly the blindness the Risk Considerations section names, and
  the reason the fix has to be checked against the ref CI uses rather than
  only against the checkout that exposed the bug.