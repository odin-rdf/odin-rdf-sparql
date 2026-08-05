---
id: evaluation-harness-vendored-eval
level: task
title: "Evaluation harness: vendored eval suites, SRX/SRJ readers, result comparison"
short_code: "SPARQL-T-0010"
created_at: 2026-08-05T15:15:32.945635+00:00
updated_at: 2026-08-05T15:15:32.945635+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Evaluation harness: vendored eval suites, SRX/SRJ readers, result comparison

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Extend the hermetic W3C harness from syntax to evaluation: vendor the SPARQL 1.1 *evaluation* suite directories, build the test-only expected-result readers, and implement result-set comparison. After this task the harness can run an evaluation test end to end (load data → evaluate → compare) — with zero suites enabled, because no evaluator exists yet. Pure infrastructure; no store dependency beyond the loaders.

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

*To be added during implementation*