---
id: as-of-costs-this-engine-nothing-a
level: task
title: "As-of costs this engine nothing: a permanent test that a horizon reaches SPARQL through query_init_txn"
short_code: "SPARQL-T-0025"
created_at: 2026-08-08T20:04:08.547580+00:00
updated_at: 2026-08-08T20:26:33.290929+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# As-of costs this engine nothing: a permanent test that a horizon reaches SPARQL through query_init_txn

## Objective **[REQUIRED]**

**Filed from odin-rdf-store as `STORE-T-0052`, the closing task of `STORE-I-0005`, and it
adds a test rather than a feature.**

odin-rdf-store has grown transaction time (`STORE-A-0008`): a quad index key carries the
epoch of the version it records, negated so that a quad's versions sort newest first;
`remove` is a tombstone append rather than an erasure; and **as-of lives on the
transaction**, not in any query language:

```odin
tx, err := kvstore.txn_begin_as_of(s, horizon)   // always .Read; every read through it is as-of
```

The ADR's §4 states the payoff as a claim about *this* repository: because
`sparql_kvstore.query_init_txn` already takes a `^kvstore.Txn` (`SPARQL-T-0024`), **passing
it an as-of transaction makes the whole query as-of with no source change here.** No temporal
SPARQL syntax, no reserved predicates an application must remember to filter on, no new
constructor.

**The claim is true — and that is exactly why it needs a test in this repository.** The store
session verified it with a throwaway program (`STORE-T-0052`'s status update: the same query,
the same `query_init_txn`, 1 row at HEAD and 2 as of epoch 1). A scratch program verifies a
claim *at a moment*. "As-of costs the siblings nothing" is a claim a future change **here**
could break — a `Query` that opened a second transaction of its own for some read, or a
constructor that stopped honouring the caller's handle, would falsify it — and **it should
fail in the repository that broke it**, not in a store session a release later. Nothing in
the W3C suites can produce it: they never edit a dataset after loading it, so no entry has a
second epoch to read at.

Same route as `SPARQL-T-0024`, `SPARQL-T-0023` and `SPARQL-T-0022`: filed from the store,
raised before it was filed, landing on this repository's schedule.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

**Nothing is wrong today and no behaviour changes.** This is a regression fence around a
property this engine gets for free, plus the two documentation duties the family's
release convention puts on a consumer when the layer under it gains a dimension.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: "What did this query answer last year" is the same call with a different
  transaction. An application asking it gets the engine's ordinary semantics, unchanged.
- **Business Value**: The store's audit story reaches the query engine without the query
  engine knowing the concept exists. That is only worth relying on if something re-checks it.
- **Effort Estimate**: S. One test file in `sparql/kvstore`, no non-test source change.

## What odin-rdf-store shipped **[CONDITIONAL: Feature]**

`STORE-A-0008`, format version 2, on the store's `main` and unreleased at the time of
filing. What this repository can call:

- **`kvstore.txn_begin_as_of(s, horizon: store.Epoch) -> (Txn, Error)`** — a read
  transaction carrying a horizon. `match_txn`, `find_term_txn`, `lookup_term_txn`,
  `count_txn`: every read through it is as-of. `store.EPOCH_NEVER` (0) yields the empty
  dataset; a horizon past the newest epoch is HEAD. Neither is an error.
- **`kvstore.epoch_at(s, nsec: i64) -> (store.Epoch, Error)`** — the newest epoch committed
  at or before a wall-clock time, so "as of midnight" is this feeding `txn_begin_as_of`.
- **`kvstore.remove(s, pattern)` / `remove_txn`** — retraction as a tombstone append, taking
  a `Match_Pattern` rather than a quad.
- **`kvstore.txn_begin` gained a defaulted third parameter** (`store.Txn_Annotation`, the
  agent and note an epoch is attributed with), which is why every existing call site here
  compiled untouched.

Two properties of the design this engine leans on without asking for them: **the dictionary
is not temporal** — a term interned at a later epoch stays nameable in an as-of read, and
that is deliberate, since a term is a name rather than a claim — and **the iterator
contract is unchanged**, so `match_txn`'s borrow-until-`match_destroy` rule holds under a
horizon exactly as at HEAD.

## Acceptance Criteria **[REQUIRED]**

- [x] **A permanent as-of test in `sparql/kvstore`**, meeting the store task's wording: a
      dataset edited across several epochs, then the same query run through
      `txn_begin_as_of` at two different epochs returning **two different correct answers**.
      Not a smoke test — the answers must be *wrong for HEAD and right for the epoch*, since
      a query returning the same thing either way demonstrates nothing.
- [x] **`remove` is what makes the epochs**, so the fixture exercises retraction rather than
      accumulation: an answer that only ever grows can be produced by a partial read, and a
      disappearing solution cannot.
- [x] **No source change outside tests.** If the engine turns out to need one, that is the
      finding — it falsifies `STORE-I-0005`'s exit criterion and is reported upstream rather
      than repaired here.
- [x] **`count`'s as-of asymmetry checked against this evaluator** (`STORE-A-0008` §7:
      `count` is `live_count` at HEAD and a scan under a horizon). Whether the evaluator
      calls it on a hot path is a finding either way — a checked negative is worth as much
      as a hit.
- [x] **`.metis/vision.md` Current State amended, dated**, in the amend-don't-rewrite style
      the file already uses: the store under this engine now has a time dimension, and as-of
      reaches it with no source change.
- [x] `make test` green at both `Term_ID` widths, all 483 evaluation and 352 syntax entries
      unchanged; `make check` clean.
- [ ] **The CI pin moves to the store's release tag, in the same commit as the test** — a
      **floor, not just a pin**: `txn_begin_as_of` does not exist before it, so a test
      calling it turns CI red against `ref: v0.4.0`. It therefore cannot move before the
      store is tagged.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

Entirely `sparql/kvstore`, and entirely test code. `query_init` opens its own read
transaction at HEAD and there is deliberately no as-of variant of it — the horizon arrives
through `query_init_txn`, which is the constructor `SPARQL-T-0024` added for a caller that
holds its own transaction. That an as-of read was not among the reasons it was added is the
point being pinned.

The fixture needs an answer that *shrinks*, which means a retraction. Three epochs from one
Turtle load and one `remove` are enough to give three distinct answers to one join, with
HEAD differing from both epochs.

Capturing "the epoch as of now" is `epoch_at(s, time.now()._nsec)` and is safe: the newest
epoch's `sort_time` cannot be after a clock reading taken once its commit returned.
**Asserting on a timestamp captured *between* two commits would not be**, and that is worth
recording rather than discovering: system clock resolution is coarse on Windows, two commits
in a test can share a reading, and `epoch_at`'s bound is inclusive — so such an assertion
would name the later epoch and fail on one platform only.

`open_ephemeral` is the right open here (`scratch_test.odin`'s rule): every write completes
before any read transaction opens, so this is not the reader-across-writer arrangement
`NOLOCK` forbids and `snapshot_test.odin` deliberately creates.

### Dependencies

odin-rdf-store's transaction-time work (`STORE-I-0005`, `STORE-A-0008`), which the `store:`
collection already resolves from the sibling working tree — so the test can be green here
before the release exists. The CI pin cannot move until it does.

### Risk Considerations

**The likeliest failure is a test that passes for the wrong reason.** A query whose answer at
an epoch happens to equal its answer at HEAD demonstrates nothing at all, and the cheapest
way to write this test is exactly that. Every assertion should therefore name a HEAD answer
it differs from.

The second is a fixture that only ever grows. Insert-only epochs can be satisfied by a read
that simply stopped early, which is not what is being claimed.

## Status Updates **[REQUIRED]**

- **2026-08-08 — Filed from odin-rdf-store (`STORE-T-0052`), which supplies the claim and
  does not edit this repo.** Raised before filing, per the family's convention on touching
  sibling repos. The store's own status update records the throwaway verification and says
  plainly that it is not the deliverable; this item is.

- **2026-08-08 — Done, and the claim holds: not one line outside `sparql/kvstore/as_of_test.odin`
  changed.** 73 tests in `sparql/kvstore` (was 71), green at both `Term_ID` widths; all 483
  evaluation and 352 syntax entries unchanged; `make check` clean. The whole diff in this
  repository is one new test file, this item, and the vision amendment.

  **What the test asserts.** One ephemeral store, three epochs — a Turtle load
  (`alice→bob`, `bob→carol`), a second load (`carol→dave`), and a `remove` by pattern
  retracting `bob :knows *`. Then one join, `{ ?a :knows ?b . ?b :knows ?c }`, four ways:

  ```
  HEAD           (query_init)                  no solutions
  as of epoch 2  (query_init_txn, as-of txn)   alice bob carol, bob carol dave
  as of epoch 1  (query_init_txn, as-of txn)   alice bob carol
  EPOCH_NEVER                                  the empty dataset
  EPOCH_LATEST                                 identical to HEAD
  ```

  **The retraction is what makes it a test rather than a demonstration.** Removing the
  *middle* edge leaves both of its endpoints in the graph, so at HEAD the join has no
  solutions while the single-pattern query still answers `alice bob, carol dave`. Every
  as-of answer therefore differs from HEAD, and the two epochs differ from each other —
  and the file says so with explicit `!=` assertions beside the equalities, because an
  equality alone can be satisfied by an engine that ignores the transaction it was handed.

  **Verified by breaking it**, the way `SPARQL-T-0024` verified its own: swapping
  `txn_begin_as_of(s, horizon)` for `txn_begin(s, .Read)` in the one helper fails eight
  assertions across both tests, including "as of epoch 1 nothing knows :dave, got `carol`".
  A test that cannot fail is not a fence.

  **The `count` finding is a clean negative, and it was checked rather than assumed.**
  Neither `kvstore.count` nor `count_txn` appears anywhere in `sparql`, `sparql/kvstore`,
  `sparql/srj` or `sparql/srx`. The engine's reads are exactly five: `match_txn`,
  `find_term_txn`, `lookup_term_txn`, `match_next`, `match_destroy`. So **an as-of query
  pays no scan this engine asked for** — `STORE-A-0008` §7's asymmetry is invisible here.
  Two details make the negative worth more than a grep. SPARQL's `COUNT` aggregate is
  accumulated over solutions in `sparql/aggregate.odin` and is backend-independent, so it
  never reaches the store's counter even at HEAD; and the *only* `kvstore.count` call in the
  repository is `tests/w3c/harness/readers_test.odin:240`, a survey that totals loaded quads
  at HEAD through an autocommit read, which no horizon ever reaches. **What the negative does
  not cover**: the sole plausible future caller is a cost-based join planner, which
  `sparql/plan.odin:1855` already parks pending store cardinality estimates. Whatever the
  store offers for that must be answerable under a horizon, or an as-of query pays a scan per
  planning decision — worth knowing while that interface is still unbuilt.

  **Three smaller things worth keeping.**

  `epoch_at` is used only as `epoch_at(s, time.now()._nsec)` *after* a commit returns, which
  names the newest epoch deterministically. Asserting on a timestamp captured *between* two
  commits would have been the natural way to write a date-based test and would have been
  flaky on one platform only: clock resolution is coarse on Windows, two commits in a test
  can share a reading, and `epoch_at`'s bound is inclusive, so the assertion would name the
  later epoch. The reasoning is recorded at the helper rather than in this file alone.

  The store's **dictionary is not temporal**, and the second test pins both halves of that:
  `query_find` resolves `:dave` through a transaction whose horizon predates `:dave`'s
  interning, *and* the query answers empty. Asserting only the empty answer would have
  passed for the wrong reason — a binding failure produces the same answer — and would have
  gone on passing if the dictionary ever became temporal.

  `open_ephemeral` is correct here and `snapshot_test.odin`'s `kvstore.open` rule does not
  extend to it: every write in this fixture completes before any read transaction opens, so
  there is no reader held across a writer for `NOLOCK` to be wrong about.

  **Outstanding, deliberately: the CI pin.** `.github/workflows/ci.yml` still says
  `ref: v0.4.0`, and `txn_begin_as_of` does not exist in that tag — so this test and the pin
  bump must land in one commit, and that commit cannot be made until odin-rdf-store tags the
  release. Local verification runs against the sibling working tree through
  `-collection:store=../odin-rdf-store`, which is why the test can be green before the
  release exists.