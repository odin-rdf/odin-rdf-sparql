---
id: retire-the-memstore-instantiation
level: task
title: "Retire the memstore instantiation: port sparql/memstore's tests to kvstore"
short_code: "SPARQL-T-0023"
created_at: 2026-08-07T16:45:00.000000+00:00
updated_at: 2026-08-07T16:45:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


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

## Acceptance Criteria **[REQUIRED]**

- [ ] Every assertion currently running against memstore runs against kvstore afterwards.
      Test counts recorded before and after, at **both `Term_ID` widths**; any reduction is
      named and justified rather than absorbed.
- [ ] `sparql/memstore/` deleted — `eval.odin` (299 lines) plus `blocking_test.odin`,
      `eval_test.odin`, `forms_test.odin`, `path_test.odin`, `triple_terms_test.odin`
      (2,415 lines total).
- [ ] Nothing in this repo imports `store:store/memstore`.
- [ ] **The vision's falsified success criterion is retracted.** `.metis/vision.md` states
      "Evaluation runs against any odin-rdf-store backend through the match interface alone
      — in-memory and LMDB behave identically apart from performance." That becomes
      unverifiable, and a port that leaves it standing in a published vision is incomplete.
      Recommend a dated amendment rather than a rewrite: what it recorded *was* true and is
      why the interface is trusted.
- [ ] Also checked in `.metis/vision.md`: the note that "both backends already iterate in
      identical numeric-ID order, so ordered iteration is nearly free when asked for"
      (STORE-T-0015 groundwork). Upstream annotated STORE-A-0001 point 7 as historical and
      confirmed **kvstore's numeric-ID order stands on its own** — it falls out of the
      big-endian key rule — so the conclusion survives; only the cross-backend agreement
      that reassured it is moot.
- [ ] `README.md` and any package docs describing two backends are corrected.
- [ ] The full suite is green at both widths on all three CI platforms.

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
