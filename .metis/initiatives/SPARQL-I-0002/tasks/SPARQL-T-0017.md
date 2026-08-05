---
id: result-forms-ask-construct
level: task
title: "Result forms: ASK, CONSTRUCT instantiation, minimal DESCRIBE"
short_code: "SPARQL-T-0017"
created_at: 2026-08-05T15:15:42.340585+00:00
updated_at: 2026-08-05T15:15:42.340585+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Result forms: ASK, CONSTRUCT instantiation, minimal DESCRIBE

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The non-SELECT result forms as evaluated structures (serialization stays out of scope per the initiative): ASK returning a boolean; CONSTRUCT instantiating its template per solution into an in-memory graph — fresh blank nodes per solution scope, ground-term templates, dropping of invalid triples (unbound variables, literal subjects), set semantics on the output graph; and minimal spec-conformant DESCRIBE (implementation-defined projection — document the chosen form, e.g. outgoing triples of the described resources).

## Acceptance Criteria **[REQUIRED]**

- [ ] ASK evaluates to a boolean; harness compares against SRX/SRJ boolean expected results.
- [ ] CONSTRUCT: template instantiation per §16.2 — per-solution blank-node relabeling, solutions with unbound template variables produce no triple for that pattern (not an error), duplicate triples deduplicated; output is a set of `rdf.Triple`/quads over materialized terms.
- [ ] CONSTRUCT expected-result comparison via graph isomorphism against the vendored `.ttl` expected graphs.
- [ ] DESCRIBE: documented minimal semantics; returns a graph; no suite dependency (W3C evaluation suites do not pin DESCRIBE output — verify at vendoring and record in the harness README).
- [ ] ask and construct evaluation directories enabled and fully green; dual-width matrix green.
- [ ] Result-graph ownership contract documented (caller-owned via stated allocator, family convention).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
CONSTRUCT materializes solution bindings through the dictionary once per solution, instantiates template triples, and inserts into a small in-repo triple set (hash on terms). This is also the future path for the CONSTRUCT round-trip criterion (emit via odin-rdf-parser, re-parse, isomorphic) — that criterion completes in the later serialization initiative; here the graph comparison in tests stands in for it.

### Dependencies
SPARQL-T-0011 (evaluation core); most construct suite entries exercise only basic patterns, some need T-0012/T-0013 — enablement follows.

### Risk Considerations
Blank-node scoping in CONSTRUCT templates (per-solution freshness, template labels vs. query bnodes) is the main correctness trap; the isomorphism comparison hides label choices but not scoping errors.

## Status Updates **[REQUIRED]**

*To be added during implementation*