---
id: sparql-evaluation-engine-algebra
level: initiative
title: "SPARQL evaluation engine: algebra to solutions"
short_code: "SPARQL-I-0002"
created_at: 2026-08-05T14:51:51.950831+00:00
updated_at: 2026-08-05T15:31:36.053386+00:00
parent: SPARQL-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: XL
initiative_id: sparql-evaluation-engine-algebra
---

# SPARQL evaluation engine: algebra to solutions Initiative

## Context **[REQUIRED]**

Second initiative under SPARQL-V-0001, consuming the contract the first one produced. SPARQL-I-0001 delivered the front half of the engine — query text → AST → algebra, all W3C syntax suites green — and recorded explicit handovers for this initiative: the algebra representation and its ownership rule (SPARQL-T-0006/0007 logs), and the sparql12 evaluation-suite directories deliberately left unvendored.

On the storage side, odin-rdf-store has shipped everything this initiative needs to start: the match contract (STORE-A-0002, `store/interface.odin`) with two conforming backends — memstore (in-memory) and kvstore (LMDB) — verified by one shared conformance suite at both Term_ID widths. Quads are `[4]Term_ID` with kind-tagged dense IDs, so joins and dedup are integer comparisons; `match` streams encoded quads with no ordering guarantee in v1.

The deliverable is the back half of the engine: algebra in, solution sequences out, correct against the W3C SPARQL 1.1 *evaluation* suites, running against any store backend through the public match interface alone. This initiative is also the vision's designated evidence generator for the store's planner-support revision (snapshot API, ordered iteration, cardinality estimates — STORE-I-0002 design decision 3): interface needs discovered here are recorded and proposed upstream, not worked around.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- A solution-sequence model over Term_IDs: bindings are variable-slot → Term_ID, joins and dedup compare integers, terms are materialized through the store dictionary only where semantics require (expression evaluation, ORDER BY, final results).
- A term-binding bridge at query setup: the algebra's `rdf.Term` constants are resolved to Term_IDs against the target store once per query; ground terms absent from the store short-circuit to empty results without scanning.
- BGP evaluation as streaming joins over `match()`, naive fixed join order, with bound variables substituted into subsequent match calls (index-probe joins, not scan-and-filter).
- The full algebra operator set: join, leftjoin (OPTIONAL), union, minus, filter, extend (BIND), VALUES, GRAPH, project, distinct/reduced, order by, slice, and subqueries.
- The expression engine: SPARQL operators and built-in functions with correct numeric type promotion, effective boolean value, error-as-unbound semantics, and RDF-star (triple term) handling.
- Aggregation: GROUP BY, HAVING, and the built-in aggregates with DISTINCT modifiers.
- Property-path evaluation per §18.4 semantics, including the zero-or-more/one-or-more forms with cycle-safe reachability over Term_IDs.
- Result forms evaluated: SELECT (solution sequences), ASK, CONSTRUCT (template instantiation to an in-memory graph), and minimal spec-conformant DESCRIBE.
- The W3C SPARQL 1.1 evaluation suites vendored and green — per-suite-directory progression with pinned entry counts, run against **both** memstore and kvstore, at both Term_ID widths.
- SPARQL 1.2 evaluation suites (triple terms in evaluation) vendored and enabled to the extent published and stable, completing the handover from SPARQL-T-0008.
- A store-evidence log maintained throughout: every point where evaluation wants a snapshot, an ordering guarantee, or a cardinality estimate is recorded with the concrete query/operator that wants it, and shaped into upstream proposals at the end.

**Non-Goals:**
- Result **serialization** — SPARQL JSON/XML result writers and CONSTRUCT/DESCRIBE emission through odin-rdf-parser's emitters belong to a later result-forms initiative. The harness needs expected-result *readers* only.
- Query planning beyond naive fixed join order — the planner seam is designed in (join order is a distinct, replaceable step), but cost-based ordering waits for store cardinality support.
- Implementing store-side changes (snapshot API, ordered iteration, estimates) — this initiative produces the evidence and proposals; evaluation must remain correct over today's per-operation reads.
- SPARQL Update, SERVICE/federation, HTTP protocol, full-text — out of scope per the vision.

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

### Overview

A pull-based streaming operator pipeline (Volcano-style, one `next()` per solution) mirroring the algebra tree:

1. **Query setup** — bind the algebra's ground terms to Term_IDs via the store dictionary; allocate the variable-slot table; fix the join order (naive: as-written, a single replaceable procedure).
2. **Operator iterators** — one iterator per algebra operator, composed into a tree; BGPs evaluate as nested index-probe joins over `match()` with bindings substituted into match patterns. Solutions flow as flat `[]Term_ID` rows indexed by variable slot.
3. **Materialization boundary** — expression evaluation, ORDER BY comparison, grouping keys that need term semantics, and final results are the only places a Term_ID is resolved back to an `rdf.Term`. Everything else compares integers.

Backend binding is compile-time via the store's procedure-set convention — no dynamic dispatch on the match/join hot path. Blocking operators (ORDER BY, GROUP BY, MINUS's right side, DISTINCT) materialize only their own inputs; everything else streams.

## Detailed Design **[REQUIRED]**

Decisions resolved in the design phase (2026-08-05, grounded in an audit of `store/interface.odin`, `store/term_id.odin`, both backends' dictionaries, and the conformance package; approved by human review):

- **Unbound sentinel — distinct UNBOUND, decided.** Not ID 0 (0 is a valid ID: IRI kind, counter 0). The engine defines UNBOUND at Sentinel counter 2 (DEFAULT_GRAPH = counter 0, WILDCARD = counter 1 are already reserved), and the upstream proposal asks the store to reserve it. Substitution into match patterns branches UNBOUND → WILDCARD; an UNBOUND that leaks into a pattern unbranched is an assertable bug, not a silent full scan. Solution rows are flat `[]Term_ID` with a per-query variable-slot map; row ownership/copy discipline under blocking operators gets the family's explicit memory-contract treatment.
- **Backend binding — spiked and RESOLVED 2026-08-05 (SPARQL-T-0011).** The two candidates were not alternatives; the answer is **both, at different layers**. *Structure*: backend-independent core (`sparql`) plus thin instantiation packages (`sparql/memstore`, `sparql/kvstore`). *Mechanism*: the core's hot path is monomorphized through compile-time `$`-procedure constants (`$MATCH`/`$NEXT`/`$DESTROY`), so every store call is direct.

  Decided by three findings, in order of weight:
  1. **Linkage is decisive.** kvstore `foreign import`s a static LMDB archive. A core that imported it would put LMDB into the link of every consumer of the public engine package, including ones that only ever want an in-memory store. This alone rules out a `when`-on-typeid backend switch inside the core.
  2. **The backends differ in three ways a core must not encode**: handle shape (memstore = Dictionary + Dataset, kvstore = one Store), fallibility (kvstore's operations return an Error, and the core's hot-path signatures have nowhere to put one), and materialization lifetime (memstore's `lookup_term` borrows, kvstore's allocates). The instantiation packages absorb all three — kvstore's is a `Session` struct carrying an error slot, so a failed read is reported rather than looking like an empty match.
  3. **Only three procedures need threading.** Term binding (`find_term`) and materialization (`lookup_term`) are cold or at the result boundary, so the instantiation package does them directly; `find_term` reaches the core as an ordinary procedure pointer, called a handful of times per query. Just match/match_next/match_destroy are compile-time constants.

  **Measured, and contrary to the assumption behind the constraint:** procedure-pointer dispatch on the match hot path costs nothing measurable — 200k-quad full scans × 20 rounds at `-o:speed`, static 1.0 ns/quad vs. dynamic 0.9 ns/quad (−2%, i.e. noise; the store's own work dominates even in this tight a loop). The no-dynamic-dispatch rule is kept as the default because it is free here, not because it was shown to pay; if the constraint it imposes (below) ever costs more than it saves, this measurement says procedure pointers are an acceptable fallback.

  **Constraint discovered, worth knowing before T-0013:** a generic procedure that takes `$`-procedure constants and calls itself sends the Odin compiler (dev-2026-07) into unbounded instantiation — it hangs rather than failing. Two consequences, both now load-bearing in the code: the operator tree is a flat array with children named by index (a parametric struct that points at itself hangs it too), and the tree walk is an explicit stack-driven loop rather than recursion. The driver is shaped so a node says which child it wants next, which is what the two-input operators (UNION, OPTIONAL, MINUS) will need.
- **Store proposals — raised now, not batched, decided; LANDED 2026-08-05.** Audit findings: `lookup_term` (ID → term, borrowing) exists in both backends, so materialization is covered; a non-interning term → ID lookup did not exist — `intern_term` assigns fresh IDs, which on kvstore makes query setup a write transaction. The `find_term` + UNBOUND proposal went upstream as STORE-T-0014 and is **implemented** (store commit a5b1d25): `find_term`/`find_graph_label` in both backends (kvstore fallible, with `_txn` variants), `store.UNBOUND` reserved at Sentinel counter 2. Two upstream judgment calls the engine consumes as-is: an over-long language tag is *not-found* on the find path (no storable literal can carry it), and there is deliberately no `find_quad` — the term-binding bridge composes `find_term` per position and short-circuits on the first miss. The end-of-initiative proposal batch (snapshot API, ordered iteration, cardinality estimates) is unchanged.
- **Expression value model** — a typed value union for evaluation (numeric tower, boolean, string+lang, dateTime, IRI, triple term) with a single Term_ID → value materialization point and spec-faithful promotion/coercion tables. Error propagation as a value variant (error-as-unbound at the FILTER/BIND boundary).
- **Expected-result readers for the harness** — the 1.1 evaluation suites encode expected results as `.srx` (SPARQL XML), some `.srj` (JSON), and `.ttl` graphs. Graphs read via odin-rdf-parser; a minimal test-only SRX/SRJ reader must be written in-repo (no external deps). Result-set comparison needs multiset semantics plus blank-node isomorphism on results.
- **Property-path algorithms** — reachability (BFS with a visited set over Term_IDs) for `*`/`+`; the spec's path-evaluation semantics for negated property sets and inverse paths.
- **ORDER BY total order** — the spec's partial order extended to the family-standard total order for stable suite results (Jena-compatible where the spec leaves it open; document choices).
- **Snapshot discipline** — one query = one snapshot is the target read model; until the store's snapshot API exists, define and document what per-operation reads mean for correctness (suites run single-threaded, so this is about API shape, not races — the evidence log captures where a snapshot would matter).

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

Suite-driven, inherited from SPARQL-I-0001 verbatim where applicable:

- **W3C evaluation suites** define done: vendored under `tests/w3c/<suite>/` from the same pinned `w3c/rdf-tests` commit, manifest-driven, per-directory enablement with pinned entry counts, no skip lists — enabled means fully green. Test data loaded through odin-rdf-parser into the store under test.
- **Dual-backend discipline**: every enabled suite runs against memstore and kvstore; identical results are asserted, extending the store's own conformance pattern.
- **Dual-width discipline**: the Makefile's 64/32 Term_ID matrix covers all evaluation code, which is width-sensitive by nature.
- **Unit tests**: per-operator iterator tests over hand-built stores; expression-function tests sourced from the spec's operator tables (promotion, EBV, error cases); property-path reachability with cycles.
- **Allocation guards**: `mem.Tracking_Allocator` guards extended to evaluation — iterators must free what they allocate; streaming paths should not allocate per-solution.

## Alternatives Considered **[REQUIRED]**

- **Split into several smaller initiatives (core evaluation / expressions / aggregates+paths)**: rejected — the evaluation suites interlock (most suite directories need FILTER, hence the expression engine; aggregates and paths have their own directories but share every mechanism). Per-suite-directory progression *inside* one initiative gives the same incrementality with one coherent design phase, exactly as the parser initiative did with syntax suites.
- **Materialize-then-join (build full binding tables, hash-join them)**: rejected as the default — the vision's CPU/memory frugality constraint and ~200-processes-per-machine deployment shape demand streaming; blocking operators materialize only where semantics force it.
- **Evaluate over `rdf.Term` values (materialize terms early, compare terms)**: rejected — the vision mandates Term_ID joins; term materialization is the exception, not the rule.
- **Land the store's snapshot API first, then build evaluation on it**: rejected — inverts the vision's evidence-first principle; the store's revision is meant to be shaped by this engine's demonstrated needs, and evaluation over per-operation reads is correct today.
- **Include result serialization here**: rejected — the suites need readers, not writers; writers are a self-contained later initiative and would widen an already-XL scope.

## Implementation Plan **[REQUIRED]**

Rough phasing; proper decomposition happens at the decompose phase:

1. **Foundations**: solution model, variable-slot table, term-binding bridge to the store dictionary; evaluation-suite vendoring plus the test-only SRX/SRJ readers and result-set comparison (multiset + blank-node isomorphism).
2. **BGP evaluation**: streaming index-probe joins over `match()`, naive join order — first evaluation suite directories green against both backends.
3. **Expression engine core + FILTER**: value model, promotion, EBV, comparison/arithmetic operators — unlocks the many FILTER-dependent suites.
4. **Algebra operators**: OPTIONAL/leftjoin, UNION, MINUS, BIND/extend, VALUES, GRAPH, project/distinct/reduced/slice, subqueries.
5. **Built-in function library**: the full §17 function set including string, numeric, dateTime, hash, and RDF-star accessors.
6. **Aggregation**: GROUP BY/HAVING, aggregate functions, grouping over Term_IDs with term-semantic keys where required.
7. **ORDER BY and solution modifiers**: total order, stable sorting, slice interaction.
8. **Property paths**: §18.4 evaluation semantics including reachability forms.
9. **Result forms**: ASK, CONSTRUCT instantiation (isomorphism-checked), minimal DESCRIBE.
10. **SPARQL 1.2 evaluation**: vendor and enable the sparql12 eval directories to the extent stable (completes the SPARQL-T-0008 handover).
11. **Store evidence + API**: consolidate the evidence log into concrete upstream proposals (snapshot API, ordered iteration, cardinality estimates); document the public evaluation API to the family contract standard.

Exit criteria: all in-scope vendored W3C SPARQL 1.1 evaluation suite directories green with pinned counts and zero unexpected failures, against both backends, at both Term_ID widths; 1.2 evaluation directories enabled to the extent published; store-interface needs documented as evidence-backed upstream proposals; public API documented to the family standard.

## Status Updates

- **2026-08-05 — External dependency resolved: STORE-T-0014 implemented** in odin-rdf-store (commit a5b1d25). `find_term`/`find_graph_label` in both backends, `store.UNBOUND` reserved. Consequences applied: SPARQL-T-0011 no longer has an interim memstore-only path — dual-backend discipline holds from the first green suite; the engine uses `store.UNBOUND` rather than defining its own; over-long-language-tag terms are not-found by design; pattern-level binding composes `find_term` per position (no upstream `find_quad`, intentionally). Nothing now blocks transition to active.
- **2026-08-05 — Decomposed into 10 tasks** (SPARQL-T-0010 … SPARQL-T-0019): eval harness+readers → core runtime/spike/BGP → expression core+FILTER → algebra operators → §17 function library → aggregation+ORDER BY → property paths → result forms → 1.2 eval suites → store evidence+API docs. T-0010 and T-0011 can run in parallel; T-0013/T-0014 parallel after T-0012; T-0016/T-0017 need only T-0011 for their cores but gate suite enablement on the expression tasks; T-0018/T-0019 close out. External dependency: odin-rdf-store STORE-T-0014 (`find_term` + UNBOUND reservation) gates kvstore suite runs — filed in the store's backlog, to be executed in a separate session. Awaiting human review before transition to active.
- **2026-08-05 — Design decisions resolved with human review.** Store-interface audit corrected the draft (ID 0 is a valid term ID) and surfaced the term→ID lookup gap. Decided: distinct UNBOUND sentinel at Sentinel counter 2 (store asked to reserve); `find_term` + UNBOUND-reservation proposals go upstream to odin-rdf-store **now**, before evaluation starts (kvstore queries must not write); backend-binding mechanism picked via phase-1 spike against the real BGP join. Defaults accepted: in-repo test-only SRX/SRJ readers, Jena-compatible ORDER BY total order, BFS reachability for paths, snapshot needs tracked via the evidence log. Next: draft the upstream store proposal, then decompose.
- **2026-08-05 — Created in discovery.** Scope drafted: the full algebra-to-solutions evaluation engine, measured by the W3C evaluation suites, excluding result serialization writers and cost-based planning. Awaiting human review of scope and the design-phase decision list.