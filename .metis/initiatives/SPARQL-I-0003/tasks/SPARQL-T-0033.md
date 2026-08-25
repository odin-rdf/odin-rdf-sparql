---
id: the-w3c-harness-one-loader-no
level: task
title: "The W3C harness: one loader, no Backend enum, 474 of 474 across 36 directories"
short_code: "SPARQL-T-0033"
created_at: 2026-08-24T20:42:37.137938+00:00
updated_at: 2026-08-25T15:00:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0032"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# The W3C harness: one loader, no Backend enum, 474 of 474 across 36 directories

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

The verdict. Port the W3C evaluation harness onto record and hold the
engine to the same standard it meets today, minus only the directory that
waits on the record release: **474 of 474 evaluated entries across 36
enabled directories**, no skip list and no expected-failure file. This is
the task that decides whether the port worked.

It also removes the last store-era scaffolding: the `Backend` enum, the
two separate loading paths, the `Term_ID` width matrix, and the last
`store:` references in `Makefile` and `ci.yml`.

## Acceptance Criteria

- [x] **One loader, not two.** `tests/w3c/harness/dataset.odin`'s
      `Test_Dataset` and `eval_runner.odin`'s own kvstore loading path
      converge. They were separate because there were two backends and
      two instantiations; that reason is gone, and `readers_test.odin`'s
      guarantee — every suite's data documents are readable — should hold
      through the same loader the evaluator uses.
- [x] **`Backend` and its dispatch are deleted.** `run_eval_suite` loses
      its parameter, `backend_name` goes, and the 37 `test_eval_*`
      procedures lose their `.Kvstore` argument. The enum was explicitly
      kept as "the seam a second backend would use"; owner decision 1
      retires that reason.
- [x] **The dataset construction respects the entry's shape**: `qt:data`
      documents into the default graph, `qt:graphData` documents each into
      a named graph whose name is the document's absolute IRI
      (`suite.base + name`), and `FROM`/`FROM NAMED` documents loaded the
      way the runner already resolves them. Get the graph IRI wrong and a
      GRAPH test silently matches nothing — the existing comment says so
      and it is still true.
- [x] **`base` is passed to `ingest` for every document with relative
      IRIs.** The harness already computes exactly this string for
      `load_turtle`; it must reach `ingest.turtle`/`ingest.trig`.
- [x] **474 of 474 evaluated entries pass across 36 directories** — every
      enabled directory except `sparql12-eval-triple-terms`, which is
      disabled *with its reason stated in the source* and re-enabled by
      SPARQL-T-0035. The pinned per-suite entry counts in `suites.odin`
      are unchanged and still asserted: a manifest-reader regression must
      not be able to shrink what "green" covers.
- [x] **`readers_test.odin`'s store loading is handled deliberately —
      this is the trap in this task.** It loads **every vendored suite's**
      data documents into a real store (`:232`–`:235`, `Test_Dataset` +
      `load_entry_dataset`), including directories the evaluator does not
      enable. So disabling `sparql12-eval-triple-terms` in `eval_test.odin`
      does **not** stop `readers_test` from trying to load its 20
      triple-term data files, and on record without triple terms they
      fail at `apply` with `.Unsupported_Term`. Decide and record which:
      report the refusal as a pinned, named count the way
      `RDF_XML_DATA_ENTRIES :: 10` and `UPDATE_ENTRIES :: 3` already are
      (`readers_test.odin:194`, `:202`) — the lean, because it
      keeps the reader guarantee honest and the count disappears in
      SPARQL-T-0035), or narrow what `readers_test` loads. **Do not
      silently skip it.**
- [x] **`zz_survey_test.odin` ports with the rest**, and is used rather
      than merely kept. It runs every entry of every vendored suite and
      reports pass / mismatch / unsupported / failed per directory while
      **asserting nothing, so it cannot fail** — which makes it the
      diagnosis tool for this task rather than a test of it. Its
      `evaluate_entry(…, .Kvstore)` call goes with the `Backend` enum.
      Set `DETAIL` to a directory's name to see its mismatches in full.
- [x] **The term-identity corpus check is settled by running, not by
      argument.** record lowercases language tags on intern and
      `rdf.equal_term` is byte-wise on the tag, so a result can render
      `@en-nz` where a document said `@en-NZ`. odin-rdf-shacl found two
      uppercase-tagged literals and neither reached an expected report;
      **this corpus is five times larger and `sparql/srj`/`sparql/srx`
      render tags into results.** Whatever the run finds is recorded here
      and folded into SPARQL-T-0021's family question by SPARQL-T-0039.
      The same for non-canonical numerics (`"01"^^xsd:integer` is a
      different term from `"1"`) and always-resolvable inlined literals
      (a small canonical integer named in a query is *bound* even when
      absent from the data).
- [x] **`Makefile`**: `WIDTHS` and the matrix loop deleted, `sparql/kvstore`
      out of `PKGS`, `store:` out of `COLL`. **`ci.yml`**: the
      `odin-rdf-store` checkout removed and any width override dropped.
      Adopt odin-rdf-shacl's redundant-import-alias grep at the end of
      `make check` while the imports are being rewritten anyway.
- [x] `make test` green on all three CI runners with odin-rdf-parser and
      odin-rdf-record as the only dependencies. No LMDB in any link.

## Implementation Notes

### Technical Approach

**Load per entry, into a store that dies with the entry.** That is what
`open_ephemeral` gave and `Mem_FS` gives more cheaply: no directory, no
path uniqueness, no cleanup, and no cross-thread collision — the suites
run on several threads and two datasets sharing a path used to fail as a
store error that reproduced only under load. The comment in
`dataset.odin` recording that history should survive the port in some
form; it is the reason the struct has no path field.

**`blank_prefix` per document, derived from the entry id**, sanitized to
label characters. Entries whose expected results depend on blank-node
isomorphism (CONSTRUCT, `bnode-coreference`) are the ones this affects;
the comparison is already isomorphism-based, so a stable prefix is enough.

**RDF/XML stays refused, and stays reported.** The ten
`sparql11-subquery` entries whose data is RDF/XML fail with a stated
reason today and that directory is not enabled; nothing here changes
that, and the reason string should keep naming the parser decision rather
than becoming a record limitation.

### Dependencies

Blocked by SPARQL-T-0032.

### Risk Considerations

**This is where SPARQL-T-0031's default-graph/unbound hazard surfaces if
it was got wrong** — as wrong answers in `sparql10-graph` (17 entries),
`sparql10-dataset` (12) and `sparql11-negation`, not as crashes. If those
directories fail together, read §4 of the initiative before debugging
anything else. **Run `zz_survey` first**: it separates "this directory
mismatches" from "this directory fails to load", which is the difference
between a semantics bug and a harness bug, and it does so for all 40
directories in one run without aborting on the first failure.

**The `GRAPH` cost regression lands here as wall-clock, not as failure.**
record has no graph-first permutation (`RECORD-A-0004`), so a bound graph
is always residual and `GRAPH <g> { ?s ?p ?o }` scans. The suites are
small enough that this should not time anything out; if a directory gets
conspicuously slower, that is the §12 finding arriving early and it
belongs in SPARQL-T-0036's baseline rather than in a fix here.

**Do not add a skip list.** If an entry cannot pass, the initiative wants
to know that as a failure with a reason, not as a quietly shorter suite.

## Status Updates


### 2026-08-25 — handed forward from SPARQL-T-0032

**The harness is the last package naming `store:`.** It is listed as
`PENDING` in the Makefile; `make test` names it and skips it. Delete
`PENDING`, its comment and both of its uses when this lands, and drop
the "partial suite" note from `ci.yml`'s test step.

**Two bridge packages go with it**: `tests/smoke` (the record plumbing's
own test, from SPARQL-T-0030) and `tests/portcheck` (one query of every
operator shape under the leak checker, from SPARQL-T-0031, written
because the port otherwise left nothing running the engine). Both say so
in their own headers. `ci.yml`'s record-pin argument no longer rests on
`tests/smoke` — SPARQL-T-0031 moved it onto the engine — so deleting
them costs nothing there.

**The harness's store code is `dataset.odin`**, which is the file to
rewrite; `eval_runner.odin` and `readers_test.odin` name the query API.
The patterns that worked are in `sparql/testkit_test.odin` (a `Test_DB`
over `Mem_FS`, a snapshot pinned once after the last load, one query
driver with the renderer passed in) and `tests/guards/guard_db.odin` (the
same with the allocator chosen by the caller). A W3C dataset loads
several documents into several graphs, which is `graph_scope_test.odin`'s
shape: one `apply` per graph, each with its own `blank_prefix`.

**Three record facts a harness will meet that odin-rdf-store hid**, all
of them already costed elsewhere in this initiative:

- **A changeset is a delta.** `apply` refuses an assert of a quad that is
  already live with `.Already_Live` at the offending op. A fixture
  written as "the whole document again" fails where LMDB's idempotent
  insert accepted it.
- **`ingest` emits a document's set**, so a document stating one triple
  twice loads. That is what record `v0.2.0` bought.
- **Term identity differs in two places that touch value semantics**:
  language tags fold to lowercase on intern, and a non-canonical numeric
  lexical form (`"01"^^xsd:integer`) is a *different term* from the
  inlined canonical one. If an evaluation entry moves, look here first —
  and note that these are the two the initiative predicted.

**`query_error` does not exist** and neither does `query_init_txn`; the
AST type is `sparql.Parsed_Query` and the prepared query is
`sparql.Query`. See SPARQL-T-0031's Status.


### 2026-08-25 — done: 537 of 537 across 38 directories, which is more than the port started with

`make test` is green on every package and `make check` on every one plus
both `bench` builds. odin-rdf-parser and odin-rdf-record are the only
dependencies; nothing links LMDB.

**The verdict: 537 of 537 evaluated entries across 38 enabled
directories**, no skip list and no expected-failure file. The task asked
for 474 across 36 and the pre-port standard was 512 across 37. Both
numbers were beaten, for two separate reasons, and neither was a
judgement call about what to count.

#### `sparql12-eval-triple-terms` never needed disabling

The criteria were written when record refused a triple term at `apply`,
so they had this directory disabled here and restored at
SPARQL-T-0035. `RECORD-I-0004` landed in between and SPARQL-T-0030 moved
the pin to `v0.4.0`, so it was simply enabled and simply green: **38 of
38, first run.** SPARQL-T-0035's "restore 512/512" is satisfied by this
task; what is left there is the `triple_adapter` note it also owns.

#### `sparql10-expr-builtin` is enabled, and the port is what enabled it

**This is the finding of the task, and it is a scope addition the owner
can reverse trivially.** The directory sat out for exactly one entry —
`dawg-lang-3`, `?x :p "string"@EN` against `"string"@en` — and
`eval_test.odin`'s header said why at length: neither parser normalized
a language tag's case, so the two terms were different keys in
odin-rdf-store's dictionary and `find_term` missed. It ended "fixing it
means normalizing on both sides of the family, which is a data-model
change rather than a function-library one."

odin-rdf-record made that change, for its own reasons: its canonical
term encoding folds a language tag to lowercase on intern. All 25
entries pass. **It passes for the right reason** — RDF 1.1 Concepts §3.3
says the value space of language tags is lower case, and the DAWG entry
expects exactly this match — so this is conformance arriving, not an
accident.

It was enabled rather than noted because the discipline is "enabled
means fully green", it is, and leaving it out would have meant replacing
a false comment with a stranger one. +25 entries, +1 directory.

#### The term-identity check, settled by running

The criterion asked for this to be measured rather than argued. It was,
across all 40 vendored directories:

- **Language-tag folding cost nothing and gained the directory above.**
  No enabled entry regressed. `sparql/srj` and `sparql/srx` render tags
  into results and no expected result in the corpus carries an uppercase
  tag that survives to a comparison.
- **Non-canonical numerics cost nothing.** No mismatch anywhere traces
  to `"01"^^xsd:integer` being a different term from `"1"`.
- **Always-resolvable inlined literals cost nothing** in the corpus, and
  they are visible in the benchmark instead — see SPARQL-T-0031's note
  on the two `group` read-count pins.

The one mismatch anywhere in the corpus is `sparql10-i18n/
normalization-02`, in a directory that has never been enabled, and it is
**not a store difference**. Measured directly: the SPARQL parser leaves
`eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz` as written while
odin-rdf-parser's Turtle parser resolves it to
`eXAMPLE://a/b/%63/%7bfoo%7d#xyz` — two parsers, two answers, no record
involved. It belongs to the family's IRI-normalization question and is
recorded in `tests/w3c/README.md` and in `eval_test.odin`'s header.

#### One real defect found, in the loader

**record refuses an empty changeset** (`.Empty`, log.md decision 6: a
commit that says nothing is a caller mistake). Several suites ship an
empty data document deliberately — `sparql11-aggregates`' empty-group
entries are the point of the exercise — and the first survey run showed
15 entries failing across five directories with "the store rejected the
document". An empty document is now a no-op rather than an apply. This
is the class of thing `zz_survey` exists for: it separated "this
directory mismatches" from "this directory fails to load" in one run,
across all 40 directories, without aborting on the first failure.

#### The scaffolding that went

**One loader.** `dataset.odin` and `eval_runner.odin` each had a full
copy of "read the file, dispatch on extension, load into a graph",
because there were two backends to load into. The reader guarantee in
`readers_test.odin` now holds through the same code the evaluator uses,
which is what it was always meant to assert.

**`Backend` and its dispatch.** The enum had one arm and was kept as
"the seam a second backend would use"; owner decision 1 retires the
reason. `backend_name`, the dispatch, the `_kvstore` suffix on 37 test
procedures and the `[%s]` in every failure message all go with it.

**`query_error` and every path behind it.** A read on record cannot
fail, so `evaluate_algebra`'s three "the store failed" arms are deleted
rather than adapted, and `Eval_Status.Failed` now means only what its
name says: the data would not load, or the query would not parse.

**The `Term_ID` width matrix, `store:`, and `PENDING`.** `WIDTHS` and
the matrix loop are gone from the Makefile and from CI; `store:` is out
of `COLL`; `PENDING` — which listed what did not yet compile for two
tasks — is empty and deleted, with the two bridge packages that stood in
for the suite (`tests/smoke`, `tests/portcheck`).

**And `make check` ends with an import-alias grep**, odin-rdf-shacl's,
adopted while every import in the repository was being rewritten anyway.
It found seven redundant aliases (`import sparql "../../sparql"` and
friends) and they are gone. `import rdf "rdf:rdf"` deliberately does not
match: the collection prefix makes that alias worth stating.

#### Notes for what follows

`readers_test.odin`'s `RDF_XML_DATA_ENTRIES :: 10` is unchanged and
still pinned; the reason string still names the parser decision rather
than a record limitation, as the criteria asked. The criterion's worry
about `readers_test` meeting `.Unsupported_Term` on the 20 triple-term
data files never arose — `v0.4.0` stores them.

The `GRAPH` cost regression the risk note predicted did not show as
wall-clock: `sparql10-graph` is 17 of 17 and the whole harness runs in
1.7 s. Whether it shows as reads is SPARQL-T-0036's.
