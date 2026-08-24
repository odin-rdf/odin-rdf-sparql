---
id: plumbing-the-record-checkout-the
level: task
title: "Plumbing: the record checkout, the collections, and a store that opens"
short_code: "SPARQL-T-0030"
created_at: 2026-08-24T20:42:25.718435+00:00
updated_at: 2026-08-24T20:42:25.718435+00:00
parent: SPARQL-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# Plumbing: the record checkout, the collections, and a store that opens

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Make odin-rdf-record reachable from this repository, and prove it by
opening one and answering one query — before anything store-side is
touched. This task **adds only**. `store:`, `sparql/kvstore` and the
width matrix are all still standing when it ends, and the suite is still
green at 512/512, because the deletion motion is SPARQL-T-0031's and
mixing the two would make a red build ambiguous.

## Acceptance Criteria

- [ ] **`Makefile`**: `COLL` gains `-collection:record=../odin-rdf-record`
      alongside the existing `rdf:` and `store:`. `rdf:` stays for good —
      record's own sources import it, and a collection resolves in the
      importing compilation, not the imported checkout.
- [ ] **`ols.json`** mirrors the collection set, so the language server
      resolves what the compiler does.
- [ ] **`ci.yml`** checks out `odin-rdf/odin-rdf-record` as a sibling
      directory (`actions/checkout@v5`, `repository:`/`ref:`/`path:`) at
      **`v0.3.0`**, beside the existing parser and store checkouts. The
      pin gets a comment in the style of odin-rdf-shacl's store-floor
      history, recording *why* `v0.3.0` is the floor: `v0.2.0` for
      `ingest`'s set semantics (RECORD-T-0019), `v0.3.0` for the distinct
      `Term_ID`/`Fact_ID`/`Epoch` types (RECORD-T-0020).
- [ ] **A smoke test** in a new package: open a store over `Mem_FS` +
      `mem_file_ops`, `ingest.turtle` a two-triple document, `apply` it,
      take `store_latest`, answer one `snapshot_match` and release the
      snapshot before `store_close`. It asserts nothing about SPARQL —
      it asserts that the collection resolves, the library links, and the
      lifetime discipline is understood.
- [ ] **The smoke test runs on all three CI runners.** This is the real
      point of the task: record has no Windows `File_Ops` and its POSIX
      file is `#+build linux, darwin`, so a Windows leg compiles record
      only if the suite never names `posix_file_ops`. Proving that now,
      on a 30-line test, is much cheaper than discovering it during
      SPARQL-T-0033 with the whole harness in flight.
- [ ] `make test` still green at both widths, 512/512 — nothing removed
      yet.

## Implementation Notes

### Technical Approach

The new package is the whole design decision here. Put it where it can be
deleted later without ceremony (`tests/smoke/` is the lean, matching
odin-rdf-shacl's) and add it to `PKGS` so `make test` and `make check`
both see it. It builds against `record:record` and `record:record/ingest`
and must not import `sparql` at all — a smoke test that needs the engine
to compile is not testing the plumbing.

Two record lifetime rules the smoke test exists to encode, both of which
cost odin-rdf-shacl a debugging session:

- **The store must not be copied or moved after `store_open`.** The
  writer holds a pointer to the `Mem_FS` living inside it, so returning
  one by value segfaults. Declare it in place; pass `^Store`.
- **Every snapshot is released before `store_close`.** `store_destroy`
  asserts it.

`blank_prefix` must be label characters (`t1_`, not `t1/`) — the rule
matters the moment anything is dumped and re-ingested, and starting
correct is free.

### Dependencies

None. First task of the initiative.

### Risk Considerations

**The Windows leg is the one that can actually fail here**, which is why
it is an acceptance criterion rather than an assumption. odin-rdf-shacl's
first record CI run also failed for an unrelated reason worth knowing:
the record repository was private at the time. It is public now, but if
the checkout step fails, check that before debugging the build.

Low risk otherwise: nothing is deleted, so the worst outcome is a task
that does not finish rather than a repository that does not build.

## Status Updates

*To be added during implementation*
