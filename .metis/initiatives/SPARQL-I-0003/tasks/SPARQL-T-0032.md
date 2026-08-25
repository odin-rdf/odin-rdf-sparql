---
id: the-core-s-own-tests-sparql-tests
level: task
title: "The core's own tests: sparql, tests/guards and tests/readme onto Mem_FS and ingest"
short_code: "SPARQL-T-0032"
created_at: 2026-08-24T20:42:35.725354+00:00
updated_at: 2026-08-25T14:00:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0031"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


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

- [x] **Every `open_ephemeral` + `load_*` + `close` call site becomes
      `Mem_FS` + `store_open` + `ingest` + `apply` + `store_close`**,
      through one harness type per package rather than 20 open-coded
      sequences. odin-rdf-shacl's `Test_DB`/`Guard_DB` pattern is the
      model: open over `Mem_FS`, load each document, pin the head
      snapshot on first use, release before close, **never copied or
      moved after open**.
- [x] **`sparql/kvstore`'s nine test files are triaged, not bulk-deleted
      or bulk-kept.** `blocking_test.odin` (532 lines, the blocking
      operators' semantics asserted directly rather than only through the
      suites), `forms_test.odin`, `path_test.odin`,
      `evaluation_test.odin`, `eval_test.odin` and
      `graph_scope_test.odin` are about SPARQL and move into `sparql`.
      `snapshot_test.odin` is about a backend property that no longer
      exists in that form and is re-derived or dropped with a reason
      recorded. `as_of_test.odin` moves to SPARQL-T-0034.
      `triple_terms_test.odin` moves to SPARQL-T-0035.
- [x] **`tests/guards`' allocation guards still guard.** They assert the
      zero-allocation properties of the hot paths; those properties are
      the reason `RDF-A-0001`'s borrowing discipline exists, and record
      changes what is being borrowed (an arena rather than mapped LMDB
      pages) without changing that it is borrowed. Any guard whose
      expected allocation count moves gets a comment saying why it moved.
- [x] **`tests/readme` compiles and asserts the README's examples**, with
      the README updated in the same motion so it cannot drift — the
      family's README-as-contract pattern. The quick start now opens a
      record store; follow odin-rdf-shacl's precedent of the README using
      `posix_file_ops()` over a directory where the tests use `Mem_FS`,
      and say so in both places.
- [x] **The fixtures respect two record facts** that odin-rdf-store hid:
      a candidate is the delta, so re-asserting a live quad is
      `.Already_Live` at the op and a fixture written as "the whole
      document again" must become "what the write adds"; and `ingest`
      emits a document's *set*, so a document stating a triple twice
      loads (that is what the `v0.2.0` floor buys).
- [x] **`blank_prefix` is derived from the test name and sanitized to
      label characters.** Two documents under one prefix sharing a label
      collide by construction — which is correct when that is the test,
      and a bug when it is not.
- [x] `make test` green at the single width on every package except
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

### 2026-08-25 — handed forward from SPARQL-T-0031

**The public type is `sparql.Query` and the AST node is now
`sparql.Parsed_Query`.** The two collided when the prepared query moved
into this package; the prepared query took the shorter name and the
parse tree was renamed. `tests/readme` and the README are written
against `sparql_kvstore.Query` and both change: the import goes, the
type is `sparql.Query`, and `query_init` takes a `record.Snapshot`.

**`query_init` does not take ownership of the snapshot.** The criterion
in SPARQL-T-0031 said `query_destroy` releases it; it does not, because
a `Validator`'s candidate is a borrowed handle record releases itself.
The call shape is `store_latest` / `defer snapshot_release` /
`query_init` / `defer query_destroy`. See that task's Status.

**`query_error` does not exist.** A read on record cannot fail, so every
call site that checked it is deleted rather than adapted.

**The Makefile has a `PENDING` variable** listing `tests/guards`,
`tests/w3c/harness` and `tests/readme`. Move each into `PKGS` as it is
ported, and delete the variable and its comment when the list empties at
SPARQL-T-0033.

**Two bridge packages are deleted at SPARQL-T-0033, not here**, unless
this task's ports make them redundant sooner: `tests/smoke` (the record
plumbing's own test) and `tests/portcheck` (one query of every operator
shape under the leak checker, written because SPARQL-T-0031 left the
repository with nothing that ran the engine). Whoever deletes
`tests/smoke` owns the `ci.yml` edit its Status flagged — already done
at SPARQL-T-0031, so there is nothing left there.

**There is no `Term_ID` width matrix.** `make test` runs once.


### 2026-08-25 — done: 198 tests, and the port has a suite again

`make test` is green on every package except `tests/w3c/harness`, which
is SPARQL-T-0033: **170 in `sparql`, 6 srj, 7 srx, 9 guards, 3 readme,
2 smoke, 1 portcheck**. `make check` is green on all of them plus both
`bench` builds.

#### The triage, file by file

Six of the nine `sparql/kvstore` test files moved into `sparql`
**without one assertion changing**, which is the finding: none of them
was ever about a backend.

- `blocking_test.odin` (17 tests) — aggregates, GROUP BY, ORDER BY,
  UNION, subqueries. Moved verbatim.
- `evaluation_test.odin` (13) — joins, DISTINCT, the solution
  modifiers. One test changed subject; see below.
- `graph_scope_test.odin` (7) — §18.5 GRAPH scoping. Each fixture is now
  one `apply` into one graph.
- `path_test.odin` (12) — §18.4 property paths. Moved verbatim.
- `forms_test.odin` (14) — CONSTRUCT and DESCRIBE. `describe_build`'s
  `Term_Finder` argument became the snapshot; the ownership test is
  stronger now (below).
- `eval_test.odin` — one of its two tests survives, narrowed and
  renamed; the other is deleted with its reason in the file.
- `snapshot_test.odin` — rewritten. Two tests kept, one replaced by a
  better one, one deleted, one strengthened. Details below.
- `scratch_test.odin` — **deleted outright.** It made unique temp
  directories for LMDB databases and cleaned them up. record's memory
  seam needs no path, no uniqueness and no cleanup, so there is nothing
  left for it to do.
- `as_of_test.odin` and `triple_terms_test.odin` — **not restored**, by
  the decomposition: they are SPARQL-T-0034's and SPARQL-T-0035's. They
  are in git at `333f3f8:sparql/kvstore/`.

#### What replaced what, where a test could not simply move

**`test_kvstore_query_setup_does_not_write` is deleted.** It closed a
store and reopened the path `read_only`, which is the sharpest possible
assertion that the term-binding bridge uses `find_term` and not
`intern_term` — a query that interned would fail outright. record has no
read-only open, no path to reopen, and no interning verb on the read
side at all. The property survives as arithmetic in
`test_absent_ground_term_short_circuits`: the store's term count, read
through a *fresh* snapshot taken after the query ran, must not have
moved.

**`test_query_init_txn_sees_the_callers_uncommitted_write` became
`test_a_validator_candidate_is_an_ordinary_snapshot`.** This is the one
worth reading. SPARQL-T-0031 deleted `query_init_txn` on the argument
that record's validation hook serves the same consumer better — it is
handed the dataset the write *would* produce, as an ordinary snapshot at
the epoch it would commit at. **That argument is now under test**: a
`record.Validator` wired at `store_open` runs a real `sparql.Query`
against the candidate and counts its solutions; the first commit's
candidate has two, the second has three — the third being the row the
uncommitted write carries. It also pins the half that makes the hook
usable at all: `query_destroy` runs inside the hook and must not release
the candidate, which is why `query_init` takes a snapshot it does not
own.

**`test_queries_do_not_exhaust_the_reader_table` is deleted.** It ran
300 queries past LMDB's 126-slot reader table, because a leaked read
transaction fails on the 127th query afterwards rather than on the one
that leaked it. record has no such table and no such failure mode, and
since SPARQL-T-0031 the query neither acquires nor releases a snapshot.
The deletion is recorded in the file rather than left silent.

**`test_a_failed_query_init_leaves_no_transaction` became
`test_a_failed_query_init_leaks_nothing`, and it caught a real gap.**
The old test proved the transaction was ended; there is no transaction,
so the honest replacement is the stronger property — that a failed
`query_init` frees its slot table, its builder and any EXISTS sub-plan
it had already built, for a caller that never calls `query_destroy`.
**It did not**, on record or before it: the old `query_prepare` released
only the transaction. `query_init` now cleans up fully and `unsupported`
survives the teardown (every value is a string literal from
`plan.odin`).

**`test_construct_graph_outlives_its_store` got sharper rather than
softer.** Against kvstore a graph that had not copied its terms would
read unmapped pages after `close`. On record `snapshot_term` *borrows
the dictionary arena* for most kinds, and `store_close` frees it, so the
same test now catches a use-after-free that the leak checker sees.

#### One real defect in SPARQL-T-0031, found by restoring the tests

`test_path_negated_property_set_splits_by_direction` failed with
`runtime assertion: UNBOUND leaked into a match pattern`. **There were
two copies of that assert and T-0031 removed one.** The second, in
`nps_next`, fired on any negated property set with an unbound endpoint —
because on record UNBOUND and WILDCARD are the same value, so it
asserted `0 != 0`. `make check` could not see it and `make bench` does
not run an NPS. This is exactly the class of bug the task's risk note
predicted, and it is the argument for the whole task: the port compiled
and benched clean with a crash in it.

#### The harness

**One `Test_DB` and one query driver, with the row renderer passed in**
(`sparql/testkit_test.odin`). The five files each carried their own copy
of "open, load, parse, translate, prepare, drain, render" — eighty lines
differing only in how a solution is spelled — and the renderer is the
only part that genuinely differs, so it is the only part that stayed
per-file. `tests/guards` keeps its own `Guard_DB` because a guard needs
to choose whether the store's memory is inside or outside the tracked
allocator, which no shared helper should decide for it.

`blank_prefix` is derived from the call site **and the document's
ordinal within the store**, sanitised to label characters, so two
fixtures cannot collide by accident; a caller that wants a shared scope
passes one.

#### The guards: not one expected count moved

All nine pass unchanged — including `test_evaluation_streams_without_
allocating` (5000 solutions, zero allocations after the first pull),
both boundedness guards at their original 8192-byte slack, and both leak
guards at zero live allocations. The comment about memstore merging
pending inserts on first read is now belt and braces: record's
permutations are built at `apply`.

The leak guards' fixtures include the triple-term N-Triples that record
refused outright before `v0.4.0`. They load.

#### The README

Rewritten in the same motion as `tests/readme`, so it cannot drift.
The quick start opens with `record.posix_file_ops()` over a directory —
what an application does — and the test substitutes `Mem_FS`; both say
so. The third example is no longer `query_init_txn` but the validator
hook, and the test asserts the candidate really carries the uncommitted
write. The width-matrix paragraph, the `sparql/kvstore` row, the
`query_error` sentence and the `store:` collection are gone. One
`kvstore` mention survives on purpose, in the sentence explaining that
the engine used to be two packages.

#### Left for SPARQL-T-0033

`tests/w3c/harness` alone, listed as `PENDING` in the Makefile; `make
test` names it and skips it rather than pretending it passed. Delete
`PENDING` and its uses when it lands, along with `tests/smoke` and
`tests/portcheck`.
