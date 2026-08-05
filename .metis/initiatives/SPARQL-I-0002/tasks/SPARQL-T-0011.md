---
id: solution-model-term-binding-bridge
level: task
title: "Solution model, term-binding bridge, backend-binding spike, and BGP joins"
short_code: "SPARQL-T-0011"
created_at: 2026-08-05T15:15:33.868806+00:00
updated_at: 2026-08-05T15:15:33.868806+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Solution model, term-binding bridge, backend-binding spike, and BGP joins

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The engine's core runtime, in four connected pieces: (1) the solution model — flat `[]Term_ID` rows, per-query variable-slot table, the UNBOUND sentinel (Sentinel counter 2), row ownership/copy contract; (2) the term-binding bridge — resolve the algebra's ground terms to Term_IDs once at query setup, short-circuiting to empty on absent terms; (3) the **backend-binding spike** — prototype both candidate mechanisms (generic $-param executor vs. per-backend instantiation packages) against the real BGP join and record the winner in SPARQL-I-0002 before any further operator work; (4) BGP evaluation — streaming index-probe joins over `match()`, bindings substituted into patterns (UNBOUND → WILDCARD), naive as-written join order behind a single replaceable join-order procedure (the planner seam).

## Acceptance Criteria **[REQUIRED]**

- [ ] Spike outcome documented in this task and the decision recorded in SPARQL-I-0002's Detailed Design (mechanism, measured rationale — codegen size, inlining, ergonomics).
- [ ] SELECT-over-BGP queries evaluate end to end: parse → algebra → solutions, against memstore through the public match interface only.
- [ ] Term-binding bridge uses the store's non-interning `find_term`/`find_graph_label` (STORE-T-0014, landed 2026-08-05, store commit a5b1d25) — no `intern_term` calls from evaluation on any backend. Quad/pattern-level binding composes `find_term` per position and short-circuits on the first miss (upstream deliberately ships no `find_quad`; the composition shape is this engine's to define).
- [ ] kvstore wired through the same code path (compile-time binding) and enabled from the start — both backends green together, per the initiative's dual-backend discipline. kvstore's fallible signatures (`find_term -> (id, found, err)`) handled explicitly; prefer the `_txn` variants once a per-query read transaction exists.
- [ ] At least one evaluation suite directory enabled and fully green against memstore (candidates: the basic triple-match directories needing no FILTER); pinned counts per the harness convention.
- [ ] Join iterators allocate nothing per solution on the streaming path; allocation guards extended to evaluation; dual-width (64/32) matrix green.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Operator structs with `next()` procedures per the initiative's architecture. BGP join = for each triple pattern in order, a probe iterator that substitutes the current row's bindings into the pattern and scans `match()`; unification checks for repeated variables within a pattern. The join-order procedure takes the BGP and returns a permutation — naive returns identity; this is the only seam the future planner replaces.

### Dependencies
SPARQL-T-0010 for suite enablement (the code itself can start in parallel). External dependency **resolved**: odin-rdf-store STORE-T-0014 landed (store commit a5b1d25) — `store.UNBOUND` is reserved upstream (use it, do not define an engine-local sentinel) and `find_term`/`find_graph_label` exist in both backends.

### Risk Considerations
The spike decision shapes every later operator signature — that is why it happens here, on the smallest real operator, and is recorded before T-0012+ build on it. UNBOUND leaking into a match pattern must assert (debug) rather than silently wildcard. One upstream semantic to preserve, not "fix": a literal whose language tag exceeds the store format's one-byte field is *not-found* on the find path (interning would raise Language_Too_Long) — no storable literal can carry it, so the bridge's empty-result short-circuit is the correct behavior; don't special-case it.

## Status Updates **[REQUIRED]**

*To be added during implementation*