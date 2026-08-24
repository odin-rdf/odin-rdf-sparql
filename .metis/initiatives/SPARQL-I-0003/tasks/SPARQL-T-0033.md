---
id: the-w3c-harness-one-loader-no
level: task
title: "The W3C harness: one loader, no Backend enum, 474 of 474 across 36 directories"
short_code: "SPARQL-T-0033"
created_at: 2026-08-24T20:42:37.137938+00:00
updated_at: 2026-08-24T20:42:37.137938+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0032"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] **One loader, not two.** `tests/w3c/harness/dataset.odin`'s
      `Test_Dataset` and `eval_runner.odin`'s own kvstore loading path
      converge. They were separate because there were two backends and
      two instantiations; that reason is gone, and `readers_test.odin`'s
      guarantee — every suite's data documents are readable — should hold
      through the same loader the evaluator uses.
- [ ] **`Backend` and its dispatch are deleted.** `run_eval_suite` loses
      its parameter, `backend_name` goes, and the 37 `test_eval_*`
      procedures lose their `.Kvstore` argument. The enum was explicitly
      kept as "the seam a second backend would use"; owner decision 1
      retires that reason.
- [ ] **The dataset construction respects the entry's shape**: `qt:data`
      documents into the default graph, `qt:graphData` documents each into
      a named graph whose name is the document's absolute IRI
      (`suite.base + name`), and `FROM`/`FROM NAMED` documents loaded the
      way the runner already resolves them. Get the graph IRI wrong and a
      GRAPH test silently matches nothing — the existing comment says so
      and it is still true.
- [ ] **`base` is passed to `ingest` for every document with relative
      IRIs.** The harness already computes exactly this string for
      `load_turtle`; it must reach `ingest.turtle`/`ingest.trig`.
- [ ] **474 of 474 evaluated entries pass across 36 directories** — every
      enabled directory except `sparql12-eval-triple-terms`, which is
      disabled *with its reason stated in the source* and re-enabled by
      SPARQL-T-0035. The pinned per-suite entry counts in `suites.odin`
      are unchanged and still asserted: a manifest-reader regression must
      not be able to shrink what "green" covers.
- [ ] **`readers_test.odin`'s store loading is handled deliberately —
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
- [ ] **`zz_survey_test.odin` ports with the rest**, and is used rather
      than merely kept. It runs every entry of every vendored suite and
      reports pass / mismatch / unsupported / failed per directory while
      **asserting nothing, so it cannot fail** — which makes it the
      diagnosis tool for this task rather than a test of it. Its
      `evaluate_entry(…, .Kvstore)` call goes with the `Backend` enum.
      Set `DETAIL` to a directory's name to see its mismatches in full.
- [ ] **The term-identity corpus check is settled by running, not by
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
- [ ] **`Makefile`**: `WIDTHS` and the matrix loop deleted, `sparql/kvstore`
      out of `PKGS`, `store:` out of `COLL`. **`ci.yml`**: the
      `odin-rdf-store` checkout removed and any width override dropped.
      Adopt odin-rdf-shacl's redundant-import-alias grep at the end of
      `make check` while the imports are being rewritten anyway.
- [ ] `make test` green on all three CI runners with odin-rdf-parser and
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

*To be added during implementation*
