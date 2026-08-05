---
id: solution-model-term-binding-bridge
level: task
title: "Solution model, term-binding bridge, backend-binding spike, and BGP joins"
short_code: "SPARQL-T-0011"
created_at: 2026-08-05T15:15:33.868806+00:00
updated_at: 2026-08-05T15:54:26.338445+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Solution model, term-binding bridge, backend-binding spike, and BGP joins

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The engine's core runtime, in four connected pieces: (1) the solution model — flat `[]Term_ID` rows, per-query variable-slot table, the UNBOUND sentinel (Sentinel counter 2), row ownership/copy contract; (2) the term-binding bridge — resolve the algebra's ground terms to Term_IDs once at query setup, short-circuiting to empty on absent terms; (3) the **backend-binding spike** — prototype both candidate mechanisms (generic $-param executor vs. per-backend instantiation packages) against the real BGP join and record the winner in SPARQL-I-0002 before any further operator work; (4) BGP evaluation — streaming index-probe joins over `match()`, bindings substituted into patterns (UNBOUND → WILDCARD), naive as-written join order behind a single replaceable join-order procedure (the planner seam).

## Acceptance Criteria

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

- **2026-08-05 — Complete.** All acceptance criteria met. `make test` green at both Term_ID widths (sparql 68, sparql/memstore 9, sparql/kvstore 2, guards 6, harness 33), `make check` clean.

  **Spike outcome — full rationale recorded in SPARQL-I-0002's Detailed Design.** The two candidates were not alternatives. *Structure* is candidate 2 (backend-independent core plus `sparql/memstore` and `sparql/kvstore` instantiation packages); *mechanism* is candidate 1 (compile-time `$`-procedure constants for the three hot-path operations). Decided by linkage first — kvstore foreign-imports a static LMDB archive, so a core that imported it would drag LMDB into every consumer of the public engine package — then by the three shape differences the instantiation packages absorb (one handle vs. two, fallible vs. infallible, borrowing vs. allocating materialization). Only match/match_next/match_destroy need threading; `find_term` and `lookup_term` are cold or at the result boundary, so `find_term` reaches the core as an ordinary procedure pointer called a handful of times per query.

  **Two spike findings that changed the design, measured rather than assumed:**
  1. **Dynamic dispatch is free here.** 200k-quad scans × 20 rounds at `-o:speed`: static `$`-constants 1.0 ns/quad, procedure pointers 0.9 ns/quad — a −2% "overhead", i.e. noise; the store's own work dominates even in that tight a loop. The no-dynamic-dispatch rule is kept because it costs nothing, not because it was shown to pay. Recorded so a future task can trade it away on evidence instead of re-arguing it.
  2. **The Odin compiler (dev-2026-07) hangs on two shapes this design reaches for naturally**: a parametric struct that points at itself (`Exec_Node($It)` with an `^Exec_Node(It)` field), and a generic procedure taking `$`-procedure constants that calls itself. Both spin to multiple GB rather than erroring. So the operator tree is a flat array with children named by index, and the tree walk is an explicit stack-driven loop. The driver is deliberately shaped as "a node says which child it wants next" — which is what UNION/OPTIONAL/MINUS need in SPARQL-T-0013, so the constraint pushed the design somewhere it should probably have gone anyway.

  **Delivered.**
  - `sparql/plan.odin` — `Var_Slots` (variables *and* pattern blank nodes get dense slots; blank-node slots are marked internal and never projected, which is what makes `SELECT *` mean "every variable" rather than "every slot"), the `Plan_*` node types, and plan construction. The term-binding bridge resolves every ground term through the backend's non-interning `find_term`; an absent term collapses the pattern to `Plan_Nothing` instead of scanning for something that cannot be there. `join_order` is the planner seam — one procedure, identity permutation today, and nothing above it assumes that. `Join(BGP, BGP)` is concatenated into a single BGP, which matters more than it looks: the translation emits it for adjacent triple blocks, and running it as a general join would turn an index probe into a cross product.
  - `sparql/exec.odin` — the pull-based executor. A BGP runs as a chain of index probes: bindings substituted into the pattern, UNBOUND → WILDCARD, backtracking that undoes exactly what each depth bound, and unification that catches a variable repeated within one pattern. An UNBOUND reaching a match pattern asserts rather than silently becoming a full scan.
  - `sparql/memstore/`, `sparql/kvstore/` — the instantiations, written to stay recognizably parallel so a change to one is a question about the other.
  - `tests/w3c/harness/eval_runner.odin` + `eval_test.odin` — the end-to-end suite runner, against both backends.

  **Suites enabled** (fully green, both backends, both widths; the AC asked for one directory against memstore alone): `sparql10-triple-match` 4/4 and `sparql10-basic` 27/27. kvstore was wired from the start rather than deferred, so the dual-backend discipline holds from the first green suite.

  **Allocation guards** (`tests/guards`): streaming 5000 solutions from a two-pattern join performs **zero** allocations after the first pull; a prepare/run/destroy cycle over five query shapes — including runs abandoned mid-stream, which leave match iterators open — leaks nothing. One honest caveat is encoded in the guard rather than hidden by it: the first `match` does allocate, because memstore merges pending inserts into its indexes lazily on first read. That is the store's business and it happens once, not per solution.

  **The read-only proof for the term-binding bridge.** `sparql/kvstore/eval_test.odin` opens a store read-only and evaluates against it. If the bridge used `intern_term` anywhere, preparing the query would be a write and the test would fail outright — a sharper assertion than counting dictionary entries, and it exercises both the found and the not-found path.

  **Known gaps, reported by name and never as empty answers.** `plan_build` refuses FILTER, OPTIONAL, UNION, MINUS, GRAPH, BIND, VALUES, GROUP BY, ORDER BY, property paths, triple-term patterns, and joins of non-basic patterns (subqueries), naming each; the harness refuses non-SELECT result forms and FROM/FROM NAMED the same way. This distinction is load-bearing for every remaining task: an unimplemented operator must never be mistaken for a query with no solutions.