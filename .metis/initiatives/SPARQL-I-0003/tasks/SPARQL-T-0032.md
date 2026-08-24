---
id: the-core-s-own-tests-sparql-tests
level: task
title: "The core's own tests: sparql, tests/guards and tests/readme onto Mem_FS and ingest"
short_code: "SPARQL-T-0032"
created_at: 2026-08-24T20:42:35.725354+00:00
updated_at: 2026-08-24T20:42:35.725354+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0031"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# The core's own tests: sparql, tests/guards and tests/readme onto Mem_FS and ingest

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Get this repository running again. SPARQL-T-0031 left a library that
compiles and a test suite that does not; this task ports every test
outside `tests/w3c` — the `sparql` package's own in-package tests,
`tests/guards`, `tests/readme` — plus the nine `sparql/kvstore` test
files worth keeping, whose subject matter (blocking operators, property
paths, evaluation semantics, snapshots) is about the *engine* and only
incidentally about a backend.

Green boundary: `make test` passes on everything except `tests/w3c`.

## Acceptance Criteria

- [ ] **Every `open_ephemeral` + `load_*` + `close` call site becomes
      `Mem_FS` + `store_open` + `ingest` + `apply` + `store_close`**,
      through one harness type per package rather than 20 open-coded
      sequences. odin-rdf-shacl's `Test_DB`/`Guard_DB` pattern is the
      model: open over `Mem_FS`, load each document, pin the head
      snapshot on first use, release before close, **never copied or
      moved after open**.
- [ ] **`sparql/kvstore`'s nine test files are triaged, not bulk-deleted
      or bulk-kept.** `blocking_test.odin` (532 lines, the blocking
      operators' semantics asserted directly rather than only through the
      suites), `forms_test.odin`, `path_test.odin`,
      `evaluation_test.odin`, `eval_test.odin` and
      `graph_scope_test.odin` are about SPARQL and move into `sparql`.
      `snapshot_test.odin` is about a backend property that no longer
      exists in that form and is re-derived or dropped with a reason
      recorded. `as_of_test.odin` moves to SPARQL-T-0034.
      `triple_terms_test.odin` moves to SPARQL-T-0035.
- [ ] **`tests/guards`' allocation guards still guard.** They assert the
      zero-allocation properties of the hot paths; those properties are
      the reason `RDF-A-0001`'s borrowing discipline exists, and record
      changes what is being borrowed (an arena rather than mapped LMDB
      pages) without changing that it is borrowed. Any guard whose
      expected allocation count moves gets a comment saying why it moved.
- [ ] **`tests/readme` compiles and asserts the README's examples**, with
      the README updated in the same motion so it cannot drift — the
      family's README-as-contract pattern. The quick start now opens a
      record store; follow odin-rdf-shacl's precedent of the README using
      `posix_file_ops()` over a directory where the tests use `Mem_FS`,
      and say so in both places.
- [ ] **The fixtures respect two record facts** that odin-rdf-store hid:
      a candidate is the delta, so re-asserting a live quad is
      `.Already_Live` at the op and a fixture written as "the whole
      document again" must become "what the write adds"; and `ingest`
      emits a document's *set*, so a document stating a triple twice
      loads (that is what the `v0.2.0` floor buys).
- [ ] **`blank_prefix` is derived from the test name and sanitized to
      label characters.** Two documents under one prefix sharing a label
      collide by construction — which is correct when that is the test,
      and a bug when it is not.
- [ ] `make test` green at the single width on every package except
      `tests/w3c/harness`, and `make check` still green.

## Implementation Notes

### Technical Approach

**One harness type per test package, not a shared one.** The packages
have different needs (guards count allocations, readme mirrors
documentation, `sparql` wants terse fixtures) and a shared helper would
have to serve all three. odin-rdf-shacl found the same and kept
`Test_DB`, `Guard_DB` and `Graph_Store` separate.

**Compiling shapes from a scratch store that is then closed** is a trick
worth stealing from odin-rdf-shacl: it keeps the "artefacts own their
terms" property under test on every entry rather than only where someone
remembered to check. The engine's equivalent is a `Query` prepared
against one store while another is open — worth one test.

**`ingest`'s signatures**: `turtle(src, graph, allocator, kind,
blank_prefix, base)`, `ntriples(src, graph, allocator, kind,
blank_prefix)`, `trig(src, allocator, kind, blank_prefix, base)` — note
`trig` and `nquads` take **no graph**, because a quad-bearing document
names its own. `ops_destroy(ops, allocator)` frees; the ops own their
terms.

**Odin gotcha from the shacl port, worth writing down once**: `&m[k]` on
a map with the key absent is `nil`, not an inserted zero. Insert first.

### Dependencies

Blocked by SPARQL-T-0031.

### Risk Considerations

**The triage is where judgement is required and where it can go quietly
wrong.** ~3850 lines of `sparql/kvstore` tests exist because there was an
instantiation to test; some of that is genuinely about SPARQL and some is
about LMDB. Deleting a test that was about SPARQL loses coverage silently
— nothing goes red. Bias toward moving rather than deleting, and record
in the Status which files were dropped and why.

**The guards are the subtle ones.** A guard that starts passing for the
wrong reason (because the code no longer allocates *because it no longer
runs*) is worse than one that fails. Check that each guard's subject is
still on a path the engine takes.

## Status Updates

*To be added during implementation*
