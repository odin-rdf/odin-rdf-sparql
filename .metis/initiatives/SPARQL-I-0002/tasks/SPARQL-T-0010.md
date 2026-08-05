---
id: evaluation-harness-vendored-eval
level: task
title: "Evaluation harness: vendored eval suites, SRX/SRJ readers, result comparison"
short_code: "SPARQL-T-0010"
created_at: 2026-08-05T15:15:32.945635+00:00
updated_at: 2026-08-05T15:35:13.034335+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Evaluation harness: vendored eval suites, SRX/SRJ readers, result comparison

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Extend the hermetic W3C harness from syntax to evaluation: vendor the SPARQL 1.1 *evaluation* suite directories, build the test-only expected-result readers, and implement result-set comparison. After this task the harness can run an evaluation test end to end (load data → evaluate → compare) — with zero suites enabled, because no evaluator exists yet. Pure infrastructure; no store dependency beyond the loaders.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [ ] SPARQL 1.1 evaluation suite directories vendored under `tests/w3c/` from the pinned `w3c/rdf-tests` commit (`767554e135eb6665949d870e6fa7bbc813837293`), with the provenance README updated (directory mapping, pinned entry counts per directory, exclusions per scope — no update/protocol/service dirs).
- [ ] Test-only SRX (SPARQL XML results) reader in-repo, no external deps: variables, bindings, all term forms (IRI, bnode, literal with datatype/lang, triple terms for 1.2 later), boolean results. Smoke test: every vendored `.srx` file parses.
- [ ] Test-only SRJ (JSON results) reader to the same standard, for directories that use it.
- [ ] Result comparison: multiset (bag) semantics by default, sequence semantics for ordered queries, blank-node bijection between actual and expected result sets; expected-graph comparison for later CONSTRUCT tests reuses/extends the family's graph-isomorphism approach.
- [ ] Manifest handling extended to evaluation test types (`mf:QueryEvaluationTest`): action query + data + graphData resolved and loaded through the store loaders.
- [ ] Comparison unit tests: order-insensitivity, bnode renaming accepted, wrong-multiplicity rejected, ordered-result mismatch rejected.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Mirror the syntax-suite harness mechanics (plain `odin test`, manifests parsed with the family's Turtle parser, pinned counts as the circularity guard). SRX reader is a minimal hand-written XML-subset scanner over the fixed SRX element set — not a general XML parser; document that boundary in the reader. Readers and comparison live under `tests/`, never in the public API.

### Dependencies
None — runs in parallel with SPARQL-T-0011. Consumed by every later task.

### Risk Considerations
SRX files in the wild use a narrow, regular XML subset; the smoke test over all vendored files is the guard that the subset assumption holds. Comparison must not be weaker than the spec (bnode bijection, not "ignore bnodes").

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete.** All acceptance criteria met; `make test` green at both Term_ID widths (29 harness tests), `make check` clean.

  **Vendored** 33 evaluation suite directories from the pinned commit `767554e135eb6665949d870e6fa7bbc813837293`: 24 `sparql10-*` and 9 new `sparql11-*`, joining the 3 sparql11 directories the parser initiative already had — 36 evaluation suites in total. **Scope correction worth recording:** the task said "SPARQL 1.1 evaluation suites", but the core of the algebra — BGP matching, OPTIONAL, GRAPH, FILTER, ORDER BY, DISTINCT, dataset construction — has its evaluation tests under `sparql10/` (the DAWG data-r2 corpus the 1.1 suite carries forward), not under `sparql11/`. Vendoring only `sparql11/` would have left BGP evaluation (SPARQL-T-0011) with no suite at all. Both are vendored; exclusions (Update, federation, protocol, entailment, 1.0 syntax, csv/tsv/json result-format suites) are enumerated in `tests/w3c/README.md`.

  **Readers** (`tests/w3c/harness/`, test-only, no external deps):
  - `xml.odin` — a minimal XML-subset tree reader (elements, attributes, CDATA, the five predefined entities, numeric character references; namespace prefixes reduced to local names, not resolved). The subset is stated explicitly at the top of the file.
  - `srx.odin` — SPARQL Results XML: all term forms including the 1.2 `<triple>`, and `<boolean>`.
  - `srj.odin` — SPARQL Results JSON over `core:encoding/json`.
  - `rsvocab.odin` — the DAWG result-set vocabulary from Turtle (via the family's parser), and **from RDF/XML**. The RDF/XML side was an unplanned necessity: `sparql10-sort` states 10 of its 14 expectations in RDF/XML and odin-rdf-parser implements no RDF/XML. Rather than drop ORDER BY coverage or take on a general RDF/XML parser, those files are read structurally against the exact striped shape they use — documented as a shape reader, not an RDF/XML parser.
  - `expected.odin` — dispatch by extension; `.csv`/`.tsv` are named as out-of-scope so an accidental reference fails loudly.
  - `graph.odin` — a small subject-indexed graph shared by the manifest reader and the rs-vocabulary reader; `manifest.odin` was rewritten on top of it.
  - `dataset.odin` — the manifest-to-store path: `qt:data` into the default graph, `qt:graphData` into a named graph whose name is the document's absolute IRI (suite base + file name), through memstore's own bulk loaders. Format dispatch covers `.ttl` and `.nt`.

  **Comparison** (`results.odin`): one `Result_Set` type for all four formats and, later, for engine answers. §12.2 semantics — a solution is a partial function, so an unbound header variable is not a difference; multiset equality by default; sequence equality when the query has ORDER BY; blank-node **bijection** (not "ignore blank nodes") by backtracking search narrowed with a blank-node-blind key, so the common bnode-free case stays linear; `mf:LaxCardinality` collapses both sides to sets for the REDUCED tests; graph isomorphism for CONSTRUCT/DESCRIBE; triple terms unify structurally.

  **Manifest** extended with `qt:data`, `qt:graphData`, and `mf:resultCardinality`.

  **Verification.** `test_expected_result_readers` reads every expectation the 36 manifests name — 508 files (340 `.srx`, 156 `.ttl`, 10 `.rdf`, 2 `.srj`) — against each suite's independently counted pinned entry count, and asserts every format is exercised. `test_entry_datasets_load` loads 478 entry datasets (4587 quads) through the store loaders. `test_evaluation_queries_parse` confirms all 508 evaluation queries parse and translate — the syntax-suite guard extended to the new corpus for free, and a clean bill of health for SPARQL-I-0001's parser against evaluation queries. 11 comparison unit tests pin order-insensitivity, ordered strictness, multiplicity, bnode renaming accepted / bnode collapse rejected, unbound-as-absent, literal-form distinctions, graph isomorphism, and triple-term structure.

  **Two findings handed forward:**
  1. A result set may legitimately contain a *solution that binds nothing* — the "empty tuple", produced by a query projecting no variables over a matching pattern. 21 such solutions appear across the corpus, and it is a different answer from an empty solution sequence. The comparison distinguishes them; an evaluator that conflates them fails `sparql10-graph/graph-exist` and `sparql11-property-path/pp36`.
  2. **10 entries in `sparql11-subquery` have RDF/XML *data*** (`sq01/04/05/08/09/10.rdf`), which no family parser reads. The count is pinned in `readers_test.odin` as `RDF_XML_DATA_ENTRIES` so it can neither grow nor shrink unnoticed; the decision — a harness-side striped-RDF/XML data reader, or an acknowledged exclusion — belongs to SPARQL-T-0013.

  **No suites are enabled for evaluation**, as intended: no evaluator exists yet. That begins with SPARQL-T-0011.