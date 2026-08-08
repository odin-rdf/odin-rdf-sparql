---
id: a-query-is-one-snapshot-hold-a
level: task
title: "A query is one snapshot: hold a read transaction for the Query's lifetime"
short_code: "SPARQL-T-0024"
created_at: 2026-08-08T00:06:00+00:00
updated_at: 2026-08-08T15:32:41.664725+00:00
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

# A query is one snapshot: hold a read transaction for the Query's lifetime

## Objective **[REQUIRED]**

**Filed from odin-rdf-store as STORE-T-0041, and it closes a loop this repo opened.**
SPARQL-T-0019 sent the store the evidence that a query reads the dataset in several
independent places and that nothing makes those reads an answer about *one* dataset. The store
took it as STORE-T-0019, designed it in `STORE-A-0007`, and shipped it in **v0.3.0**. What is
left is one line of lifetime on this side.

Take a read transaction at `query_init`, release it at `query_destroy`, and read through it —
**which is exactly the lifetime a `Query` already has.**

**The evidence, unchanged since this repo wrote it.** A SPARQL query is defined against one
dataset, not against a sequence of them. Today each of these is an independent read:

1. **Term binding** at setup — `find_term` per ground term (`sparql/kvstore/eval.odin:92`,
   and the triple-term components at `:123`).
2. **Matching** — one `match` iterator per triple pattern per depth, opened and closed as the
   join chain advances and backtracks (`sparql/kvstore/eval.odin:42`).
3. **Materialization** — `lookup_term` per result term, at the answer boundary
   (`sparql/kvstore/eval.odin:266`) and inside expression evaluation (`:77`, `:112`).

Nothing in the engine assumes those see the same dataset, because nothing can. The current
iterator rule is about *crashing*, not about *answering*: it does not say what a query means if
a writer commits between pattern one and pattern two. Under concurrency the answer is a smear —
a solution assembled from two datasets, which is not an answer to the query at all.

**The engine already has this property done right in one place, and can point at what it
buys.** `NOW()` is fixed once for the whole query (§17.4.5.1), so two calls cannot disagree.
This is the same "a query's answer is a snapshot rather than a smear" property, at the data
instead of at the clock.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

**Nothing is wrong today**, and that is worth being precise about rather than inflating: the
suites are single-threaded, so the engine has never observed an inconsistent read, and all 483
evaluation tests pass. It becomes a correctness bug the day anything writes to the store while
a query runs — which the family's deployment shape (~200 processes per machine, each embedding
a store) makes a question of when rather than whether. It is cheaper to get the lifetime right
before three consumers build around per-operation reads than after.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A query's answer is an answer about one dataset. Long-running reads stop
  being wrong in the presence of writers.
- **Business Value**: The last structural correctness gap between the engine as tested
  (single-threaded suites) and the engine as deployed.
- **Effort Estimate**: S. One field on `Session`, taken and released where the `Query` already
  begins and ends, plus seven call sites. Stated as an estimate from the store side; this repo
  owns the number.

## What odin-rdf-store shipped **[CONDITIONAL: Feature]**

v0.3.0 (ADR `STORE-A-0007`, initiative `STORE-I-0004`). One opaque `Txn` handle with a
`.Read`/`.Write` mode, and **a read transaction *is* the snapshot** — there is no separate
snapshot type and nothing in the API says "snapshot", because LMDB's read transaction is
literally the thing this repo asked for.

```odin
tx, err := kvstore.txn_begin(s, .Read)   // store.Txn_Mode
defer kvstore.txn_abort(&tx)             // legal on a read txn; txn_commit is equivalent
```

Every read this engine uses has a `_txn` form taking the handle alone: `match_txn`,
`find_term_txn`, `lookup_term_txn`, plus `count_txn` and the graph-label trio.

Two details that matter for this engine specifically:

- **`match_txn`'s iterator borrows the transaction.** `match_destroy` closes the cursor and
  leaves the transaction alone, so the open/close-per-pattern-per-depth pattern in `exec` is
  unaffected — it just stops opening a fresh snapshot each time.
- **The bare procedures are unchanged and are now *defined* as autocommit**, so this is
  additive here too: a `Session` carrying no transaction behaves exactly as it does today.

## Acceptance Criteria **[REQUIRED]**

- [x] `Session` gains a transaction alongside `store` (`sparql/kvstore/eval.odin:35`), and the
      reads go through it.
- [x] **The transaction is taken at `query_init` and released at `query_destroy`** — the
      lifetime a `Query` already has, so no new lifetime enters this repo. `query_destroy` is
      documented as safe on a query whose `query_init` returned false, and that must stay true:
      a failed init must not leak a transaction.
- [x] The seven read sites take the `_txn` form:
  - `sparql/kvstore/eval.odin:42` — `match_adapter`
  - `sparql/kvstore/eval.odin:77` — `lookup_term`, expression materialization
  - `sparql/kvstore/eval.odin:92` — `find_term`, term binding
  - `sparql/kvstore/eval.odin:112` — `lookup_term`, triple-term decomposition
  - `sparql/kvstore/eval.odin:123` — `find_term`, triple-term components
  - `sparql/kvstore/eval.odin:266` — `lookup_term`, the answer boundary
  - and the `match_next` / `match_destroy` pair, which need no change but should be confirmed
    against the borrowing rule rather than assumed.
- [x] **The error-slot contract is unchanged**: a failed read still records into `Session.err`
      and still hands back an already-done iterator, so a failure cannot read as an exhausted
      match.
- [x] **A test that would fail without this.** The suites cannot produce it — they are
      single-threaded — so it has to be written on purpose: open a query, drain part of it,
      commit a write through a second handle, and assert the query's remaining solutions are
      the ones the dataset had at `query_init`. Asserting the *dictionary* half is worth it
      too: a term interned by the later write must not resolve through the query's snapshot,
      which is what stops a query half-seeing a write.
- [x] **The page-pinning cost is documented on `query_init`**, as contract rather than as a
      note: an open read transaction pins pages, so a concurrent writer grows the file for as
      long as the query lives. A query is a fine lifetime for that; a request handler that
      holds a `Query` open across unrelated work is making a storage-sizing decision.
- [x] `make test` green at both `Term_ID` widths, all 483 evaluation tests and 352 syntax tests
      unchanged; `make check` clean.
- [x] The CI pin moves to `v0.3.0` — a **floor, not just a pin**, as `v0.2.0` already is here:
      `match_txn` does not exist before it.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`Session` is `{store: ^kvstore.Store, err: kvstore.Error}` at `sparql/kvstore/eval.odin:35`,
and `Query` holds one by value (`:167`). `query_init` (`:187`) already takes the store and
builds the session; that is where the transaction begins, and `query_destroy` (`:244`) already
releases everything the query allocated.

The backend-independent core is untouched: this is entirely `sparql/kvstore`, and `sparql`
still names no backend.

**Whether the transaction should be optional here is this repo's call, and it is a real
choice** — unlike odin-rdf-shacl, where a caller may want to validate inside its *own* write
transaction and so must be able to supply one. For a query, always taking a read transaction is
simpler and strictly more correct. But a consumer that wants to run a query inside a write
transaction it already holds — `odin-rdf-app` validating a candidate with a query rather than
with SHACL — needs to pass one in. An optional `query_init_txn` alongside `query_init` covers
both without changing the existing signature.

### Dependencies

odin-rdf-store **v0.3.0**. Nothing in this repo blocks it. Independent of SPARQL-T-0020 (GRAPH
scoping) and SPARQL-T-0021 (term identity).

### Risk Considerations

**The pinning cost is the one to weigh.** A query holds its snapshot for its whole life, and a
long-running query against a busy store makes that store grow. That is the correct trade —
the alternative is wrong answers — but it is a real change in the resource profile of a
long-running query, and it should be measured rather than assumed if this engine ever serves
one.

A second, smaller: an always-on read transaction means the autocommit path in these adapters
stops being exercised by the suite. If `query_init` takes a transaction unconditionally, the
bare-procedure branch has no test — which argues for the optional form above, with the suite
covering both.

## Status Updates **[REQUIRED]**

- **2026-08-08 — Filed from odin-rdf-store (STORE-T-0041), which supplies the argument and the
  call sites and does not edit this repo.** Raised before filing, per the family's convention
  on touching sibling repos.

  This closes a loop rather than opening one: SPARQL-T-0019 sent the evidence upstream, the
  store designed it as STORE-A-0007 and shipped it in v0.3.0, CI-verified on all three
  platforms. The design answers this repo's original framing exactly — a snapshot is a
  read-only transaction, not a separate concept — so nothing about the proposal needs
  re-litigating; what remains is the lifetime.

  **Worth pairing with the temp-path work this repo already reported upstream.**
  SPARQL-T-0023 flagged the duplicated temp-directory dance, and odin-rdf-store answered it in
  the same v0.3.0 with `kvstore.open_ephemeral` — no path to name, make unique or clean up, and
  a 16 MiB default map instead of 1 GiB. That second number is why it matters here rather than
  being tidiness: LMDB has no sparse-file handling on Windows, so every `open` materializes
  `map_size` in full, and **this repo's Windows CI job takes over 20 minutes against ubuntu's
  28s** for precisely that reason, with one store opened per evaluation entry.
  odin-rdf-store's own job went 64s → 41s while running 83% more tests once it adopted it.
  Bumping the pin to v0.3.0 is the prerequisite for both, so they are one pass.

- **2026-08-08 — Done. 71 tests in `sparql/kvstore` (was 66), green at both `Term_ID`
  widths, all 483 evaluation and 352 syntax entries unchanged; `make check` clean.**

  **The open question this item left to this repository is answered: the transaction is
  not optional.** `Session` holds a `^kvstore.Txn` and no store at all, so there is one
  read path rather than a transactional one beside an autocommit one. The item worried
  that the untested path is whichever the suite does not exercise; the way to retire that
  worry is to not have a second path. `query_init` opens a read transaction and owns it,
  `query_init_txn` takes one the caller holds and leaves it open, and both share a private
  `query_prepare`. `query_init`'s signature is unchanged, so every existing caller
  compiled untouched.

  Two lifetime details worth keeping. `query_destroy` ends the transaction **after**
  `exec_destroy`, because a match iterator borrows it and every cursor has to close first.
  And `query_init` releases the transaction on its own failure paths rather than relying
  on the destroy that usually follows — "a failed init must not leak" should hold for a
  caller that abandons the query too. `txn_abort` zeroes its handle, so the later destroy
  is a no-op rather than a double end.

  **The test almost tested nothing, and that is the part to remember.** The first version
  used a single-pattern query and passed *without* the change: `match` hands its iterator a
  transaction of its own, so one iterator opened before a commit already ignores that
  commit. Exposing the bug needs a second read — the inner pattern of a join, which
  reopens once per outer solution. Verified by reverting the read path to autocommit and
  confirming three tests fail; the central one failed with exactly the smear this item
  predicted, returning `bob carol dave`, a solution assembled from two datasets.

  Two tests assert the lifetime the only way it is observable from here: LMDB's reader
  table is 126 slots, so 300 query cycles and 300 *failed* inits with no `query_destroy`
  at all would exhaust it if anything leaked.

  **Paired work, both done.** The CI pin moved to `v0.3.0` and then to `v0.4.0`
  (STORE-T-0042). `open_ephemeral` was adopted across the suites in its own commit: 17 of
  24 opens, three scratch-path helper sets deleted, and the W3C harness went 11.5s → 0.44s
  locally with the Windows job going 31m16s → 59s. Seven opens stay on `kvstore.open`,
  and the reason is recorded at both sites — `NOLOCK` forbids holding a reader across a
  writer, which every test in `snapshot_test.odin` does deliberately.