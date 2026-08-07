---
id: retire-the-memstore-instantiation
level: task
title: "Retire the memstore instantiation: port sparql/memstore's tests to kvstore"
short_code: "SPARQL-T-0023"
created_at: 2026-08-07T16:45:00+00:00
updated_at: 2026-08-07T17:56:00.353236+00:00
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

# Retire the memstore instantiation: port sparql/memstore's tests to kvstore

## Objective **[REQUIRED]**

odin-rdf-store is removing its in-memory backend. Port `sparql/memstore`'s tests onto
kvstore and delete the package.

**This is a request from upstream, not a decision taken here.** odin-rdf-store decided the
stance in **STORE-A-0006** (one backend, a library over LMDB) and is carrying it out in
**STORE-I-0003**. This item is the odin-rdf-sparql half; sequencing and shape are this
repo's call.

**Why upstream decided it.** memstore was an architectural proposal in odin-rdf-store's
first initiative, never a consumer request — no application and no developer asked for an
ephemeral RDF store. The forcing question was transactions: STORE-T-0019 (snapshot reads)
and STORE-T-0022 (write transactions) were designed jointly, and the resulting model came
out dominated by memstore. LMDB is MVCC, so kvstore gets snapshot isolation, atomicity,
and read-your-own-writes free; memstore has no versioning, so one contract covering both
required a declared capability constant, a capability-conditional tier in the conformance
suite, a write journal, a generation counter, and a deferred copy-on-write upgrade path.
More than half of that ADR was accommodation for a backend with no consumer, so it was
archived undecided and the removal was sequenced ahead of the transaction work — building
that machinery and then deleting it is the worst available order.

The measured performance argument does not save memstore either: in odin-rdf-shacl the
kvstore path costs 61× per test, but that is around a small absolute number (8.9 ms/test),
so porting a 71-test suite costs under a second.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for the next release)

Not urgent in itself, but it **blocks STORE-T-0030**, which cannot delete
`store/memstore` while this repo still imports it — the `store:` collection resolves to
the sibling checkout, so the deletion breaks this build the instant it lands.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: None directly; this is the cost side of a simplification whose value
  lands in odin-rdf-store's transaction model, which this engine then consumes.
- **Business Value**: One backend means one contract with nothing conditional in it. The
  snapshot API this engine asked for (STORE-T-0019, filed from SPARQL-T-0019) arrives
  simpler because of it.
- **Effort Estimate**: M — mechanical but not small: 2,415 lines of tests move, 299 lines
  of code are deleted.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Every assertion currently running against memstore runs against kvstore afterwards.
      Test counts recorded before and after, at **both `Term_ID` widths**; any reduction is
      named and justified rather than absorbed.
- [x] `sparql/memstore/` deleted — `eval.odin` (299 lines) plus `blocking_test.odin`,
      `eval_test.odin`, `forms_test.odin`, `path_test.odin`, `triple_terms_test.odin`
      (2,415 lines total).
- [x] Nothing in this repo imports `store:store/memstore`.
- [x] **The vision's falsified success criterion is retracted.** `.metis/vision.md` states
      "Evaluation runs against any odin-rdf-store backend through the match interface alone
      — in-memory and LMDB behave identically apart from performance." That becomes
      unverifiable, and a port that leaves it standing in a published vision is incomplete.
      Recommend a dated amendment rather than a rewrite: what it recorded *was* true and is
      why the interface is trusted.
- [x] Also checked in `.metis/vision.md`: the note that "both backends already iterate in
      identical numeric-ID order, so ordered iteration is nearly free when asked for"
      (STORE-T-0015 groundwork). Upstream annotated STORE-A-0001 point 7 as historical and
      confirmed **kvstore's numeric-ID order stands on its own** — it falls out of the
      big-endian key rule — so the conclusion survives; only the cross-backend agreement
      that reassured it is moot.
- [x] `README.md` and any package docs describing two backends are corrected.
- [x] The full suite is green at both widths on all three CI platforms.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The port target already exists and is proven: `sparql/kvstore/eval.odin` is the same file
against the persistent backend, and the W3C evaluation harness
(`tests/w3c/harness/eval_runner.odin`, `dataset.odin`) already runs both backends. The 483
evaluation tests across 35 suite directories go through that harness rather than per-test
setup, so the harness change is likely one place rather than 483.

What changes is store construction in test setup: `dictionary_init` + `dataset_init` become
`kvstore.open` against a temp path, and the destroys become `close` plus directory removal.
`store/kvstore/kvstore_test.odin` upstream has `temp_path` / `remove_test_db` helpers worth
copying rather than reinventing.

**Do not rewrite assertions during the port.** A coverage change hidden inside a mechanical
change is the main risk, and it is invisible in review.

**No benchmark work on this side**: this repo has no `bench/`. odin-rdf-shacl does, and its
benchmarks are the one thing in the family that cannot be ported whole (SHACL-T-0028).

### Dependencies

Upstream: STORE-A-0006 (decided stance), STORE-I-0003 (the initiative), STORE-T-0026 (the
task that filed this).

**Blocks STORE-T-0030** (the deletion of `store/memstore`). Until this lands, upstream
cannot proceed, and the transaction work behind it (STORE-T-0019, STORE-T-0022) is queued
behind that.

### Risk Considerations

Suite wall-clock grows: kvstore tests do filesystem work, and Windows is the least-exercised
platform. If the inner development loop becomes painful, the first remedy is one store per
test file rather than per test — **not** reinstating memstore.

The temp-path boilerplate (`TMPDIR` → `TEMP` → `TMP` → `/tmp`, separator trim, pid suffix)
already exists in two copies upstream. If this port produces a third and a fourth, say so:
upstream has `kvstore.open_ephemeral` scoped as an optional convenience
(STORE-I-0003 Detailed Design point 3) and is explicitly waiting on evidence from these
ports to decide whether to build it.

## Status Updates **[REQUIRED]**

- **2026-08-07 — Filed from odin-rdf-store STORE-T-0026**, the sibling-proposal task of
  STORE-I-0003. Sequencing and shape are this repo's call; the blocking relationship with
  STORE-T-0030 is the one part that is not.
- **2026-08-07 — Done. Green at both `Term_ID` widths, `make check` clean.**

  **Counts, per width.** Before: sparql 102, srj 6, srx 7, sparql/memstore 64,
  sparql/kvstore 2, guards 10, w3c/harness 104, readme 2 = **297**. After: sparql 102,
  srj 6, srx 7, sparql/kvstore 66, guards 9, w3c/harness 69, readme 2 = **261**. The −36
  is two things and neither is a silent drop: −35 is the harness's memstore arm (35 suites
  that ran twice now run once — the same suites, one backend), and −1 is a guard that
  provably cannot hold on kvstore, below. The 64 evaluation tests moved intact
  (memstore 64 + kvstore 2 → kvstore 66), no assertion rewritten.

  **The port was smaller than the line count suggested.** Each test file carried its own
  file-private harness and the test bodies touched only it, so the memstore surface was
  7–10 lines per file. `sparql/memstore/eval_test.odin` became
  `sparql/kvstore/evaluation_test.odin` to avoid colliding with the existing one.

  **Three things the mechanical pass got wrong, caught before they shipped:**
  - `test_construct_graph_outlives_its_store` would have had `defer kvstore.close(s)` run
    *after* the graph was read — the exact inverse of what it asserts. The close is now
    explicit and undeferred, and its comment records that kvstore makes the test stronger
    than memstore did: closing unmaps the pages, so a graph that had not copied its terms
    reads unmapped memory rather than a stale borrow.
  - Two helpers had wrong return arity for their procedure after substitution.
  - `path_test`'s GRAPH-variable case is a test body, not a helper: no `loc`, no return
    values.

  **The harness had a full parallel memstore evaluation path**, larger than this item
  estimated: a `Backend` enum, `evaluate_memstore`, `find_memstore`, 35 `_memstore` test
  wrappers, and `Test_Dataset` in `dataset.odin`. The enum is kept with one arm rather than
  collapsed — it is the seam a second backend would use, the same reason odin-rdf-store
  retained its conformance `Backend` adapter. `Test_Dataset` was ported rather than deleted
  because `readers_test.odin` uses it to prove every suite's data documents load; it still
  reports **517 entry datasets, 5016 quads, 10 blocked on RDF/XML** — unchanged.

  **One guard retired, measured rather than assumed.**
  `test_triple_term_matching_streams_without_allocating` asserted that taking a stored
  triple term apart allocates nothing. Its own comment already recorded the limit — "a
  backend that has to materialize instead — kvstore does — will not satisfy this". Run
  against kvstore it reported **1996 allocations for 500 solutions**, about four per
  solution, exactly the term materialization predicted. It is deleted with that measurement
  in place of the test, and nothing replaces it: triple-term decomposition being
  allocation-free is no longer asserted anywhere, because on the only backend that exists
  it is not true. `test_evaluation_streams_without_allocating` — the general streaming
  promise — **passes on kvstore**, so the operator-level guarantee is intact.

  **This is the third instance of one pattern** (after odin-rdf-store's live-bytes
  benchmark metric and, expected, odin-rdf-shacl's `bench/consumers.odin`): a measurement
  whose premise was memstore borrowing rather than copying. Worth naming as a category in
  STORE-A-0006's consequences if it recurs a fourth time.

  **Scratch-database boilerplate**: `sparql/kvstore/scratch_test.odin` is one shared
  helper, and the harness's temp-dir logic was promoted to `kv_temp_dir` rather than
  copied. Two further copies were still needed (`tests/guards`, `tests/readme`), which is
  the evidence STORE-I-0003's `open_ephemeral` question was waiting on — **reporting it
  upstream: the count across the family is now five.** Also note the helper needed an
  atomic counter, not just a pid: the runner uses ~10 threads and two tests sharing a
  scratch path fail as a store error that reproduces only under load.

  README example, `tests/readme`, the package table, the Makefile's package list and its
  rationale comments, and the vision are all updated. The vision's identical-behaviour
  criterion is retracted with a dated amendment; the ordered-iteration note is annotated
  rather than removed, since kvstore's numeric-ID order stands on STORE-A-0001's
  big-endian key rule alone.