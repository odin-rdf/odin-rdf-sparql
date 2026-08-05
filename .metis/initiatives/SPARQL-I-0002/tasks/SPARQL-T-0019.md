---
id: store-evidence-proposals-and
level: task
title: "Store-evidence proposals and public API documentation"
short_code: "SPARQL-T-0019"
created_at: 2026-08-05T15:15:44.553410+00:00
updated_at: 2026-08-05T15:15:44.553410+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Store-evidence proposals and public API documentation

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Close the initiative: consolidate the store-evidence log accumulated across every evaluation task into concrete, evidence-backed upstream proposals for odin-rdf-store's planner-support revision (snapshot API, ordered iteration, cardinality estimates — the STORE-I-0002/STORE-A-0002 review triggers), and document the public evaluation API to the family's contract standard.

## Acceptance Criteria **[REQUIRED]**

- [ ] Store-evidence log consolidated: each entry names the operator/query shape that wants the capability and what it would buy (e.g. ordered match → merge joins and streaming DISTINCT/MIN/MAX; cardinality estimates → join-order planning at the T-0011 seam; snapshot API → one-query-one-snapshot read model; term enumeration → both-free path reachability). Filed as one or more backlog items/ADR drafts in odin-rdf-store's Metis, in the STORE-T-0014 pattern.
- [ ] Public API documented to the family standard: package doc with the memory/lifetime contract (query text, algebra, solution rows, materialized terms — who owns what until when), every exported symbol documented, allocator discipline stated.
- [ ] README updated with a compiled query-evaluation example (parse → evaluate against memstore → iterate solutions) covered by a README-as-contract test, matching the SPARQL-T-0009 convention.
- [ ] Initiative exit criteria verified and recorded: all in-scope 1.1 evaluation directories green with pinned counts, both backends, both widths; 1.2 state per T-0018; the verification run documented in the initiative's status log.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The evidence log should have been appended throughout (each task's notes call out their entries); this task edits it into upstream-consumable proposals rather than reconstructing from memory. API docs follow the documented-contract style audited in SPARQL-I-0001's design phase.

### Dependencies
All prior tasks (SPARQL-T-0010 … T-0018).

### Risk Considerations
None technical; the risk is evidence loss if earlier tasks skip their log entries — each prior task's implementation notes flag what to record, and this task's first step is auditing the log against the enabled-suite history.

## Status Updates **[REQUIRED]**

*To be added during implementation*