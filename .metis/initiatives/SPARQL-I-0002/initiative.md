---
id: sparql-evaluation-engine-algebra
level: initiative
title: "SPARQL evaluation engine: algebra to solutions"
short_code: "SPARQL-I-0002"
created_at: 2026-08-05T14:51:51.950831+00:00
updated_at: 2026-08-05T23:00:30.359458+00:00
parent: SPARQL-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/completed"


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

**Re-scoped 2026-08-06, at the exit verification (SPARQL-T-0019), with human review.** "All in-scope" excludes five vendored entries, each characterized rather than skipped and each recorded in `tests/w3c/README.md` with the item it waits on: `graph-optional` and `graph-minus` (GRAPH scoping for an operator that sees more than one solution at a time — SPARQL-T-0020, the only one of the three causes that is this engine's), `dawg-lang-3` and `normalization-2` (term identity — language-tag case and IRI normalization, which is the family's data-model question and has to hold for the RDF parser, both store dictionaries, and the SPARQL parser at once — SPARQL-T-0021), and `sq11` (an RDF/XML data document, which odin-rdf-parser does not implement). Their five directories stay disabled under the "enabled means fully green" discipline; the criterion is met by the other 35, which is 483 of the corpus's 488 entries.

## Status Updates

- **2026-08-06 — COMPLETED.** Ten tasks (SPARQL-T-0010 … T-0019) done in sequence, one commit each. The deliverable is the back half of the engine: algebra in, solution sequences out, over the store's match interface alone.

  **Exit criteria, all four met** (the verification run is the entry below; `make test` green at both Term_ID widths, `make check` clean):

  1. *W3C SPARQL 1.1 evaluation suites green, both backends, both widths* — **met, against the re-scoped criterion.** 483 entries across 35 enabled directories, pinned counts, no skip list. The criterion was re-scoped here with human review to exclude five entries in five directories — 483 of 488, 99.0% — because only two of their three causes belong to this engine at all; see the re-scope note in the Implementation Plan and the table in the entry below.
  2. *1.2 evaluation directories enabled to the extent published* — **met.** All four sparql12 evaluation directories at the pinned rdf-tests commit vendored and fully green (48 entries), completing the SPARQL-T-0008 handover.
  3. *Store-interface needs documented as evidence-backed upstream proposals* — **met.** Seven backlog items in odin-rdf-store (STORE-T-0015 … T-0021), each naming the operator that wants the capability and what it would buy, plus a Review Log in STORE-A-0002 discharging its first review trigger.
  4. *Public API documented to the family standard* — **met.** Package doc carrying the memory contract and allocator discipline, every exported symbol documented across the three public packages, and a compiled query-evaluation example in the README under the README-as-contract convention.

  **What the initiative proved beyond its criteria.** The store's procedure-set convention absorbed a whole query engine without an adapter and without an interface revision — every one of the seven upstream items *extends* the procedure set rather than changes it, which is what STORE-A-0002 predicted and had budgeted a revision for. The measured finding from the T-0011 spike stands as its counterweight: procedure-pointer dispatch on the match hot path costs nothing (−2%, noise), so the no-dynamic-dispatch rule is kept because it is free here, not because it was shown to pay.

  **Handovers.**
  - **SPARQL-T-0020** — `graph-optional` and `graph-minus`: what a GRAPH clause does to an operator inside it that sees more than one solution at a time. The only open item that is this engine's semantics. SPARQL-T-0013 declined to fit the code to the expected result without a spec reading it could defend, and that judgement is carried forward as the task's first acceptance criterion.
  - **SPARQL-T-0021** — term identity: language-tag case folding and RFC 3987 IRI normalization. The family's question, owned by odin-rdf-parser's data model; this repo holds the evidence (two suite entries) and would consume the answer.
  - **`sq11`** waits on RDF/XML in odin-rdf-parser. Not filed anywhere — recorded in `tests/w3c/README.md` and here, and belongs in that repo's backlog if it is ever wanted.
  - **Result serialization** (SPARQL JSON/XML writers, CONSTRUCT/DESCRIBE emission) was a non-goal throughout and is the natural next initiative: the harness has readers only, and `Result_Graph` plus the solution-row API are the shapes a writer would consume.
  - **The planner seam** is built and deliberately empty — `join_order` in `sparql/plan.odin` returns the identity permutation, and cost-based ordering waits on STORE-T-0018 (estimates) and STORE-T-0015 (ordered iteration, which is what gives a planner a second strategy to choose between).

- **2026-08-05 — Exit criteria verified (SPARQL-T-0019). Three of four met in full; the first needs a scope decision.**

  **The verification run.** `make test` — the whole matrix, both Term_ID
  widths — and `make check`, both green:

  | Package | Tests |
  |---|---|
  | `sparql` | 102 |
  | `sparql/memstore` | 64 |
  | `sparql/kvstore` | 2 |
  | `tests/guards` | 10 |
  | `tests/w3c/harness` | 100 |
  | `tests/readme` | 2 |

  **Criterion 1 — "all in-scope vendored W3C SPARQL 1.1 evaluation suite
  directories green with pinned counts and zero unexpected failures,
  against both backends, at both Term_ID widths": met for 35 of the 40
  vendored directories, and this is the one thing needing a human
  decision.**

  483 evaluation entries pass across 35 enabled directories, each run
  against memstore *and* kvstore at 64- and 32-bit Term_IDs, with pinned
  entry counts and no skip list. The remaining five directories each fail
  exactly **one** entry — five in a vendored corpus of 488, 99.0% — and
  each is characterized rather than skipped (recorded in
  `tests/w3c/README.md`):

  | Directory | | Entry | What it is |
  |---|---|---|---|
  | `sparql10-graph/` | 16/17 | `graph-optional` | this engine's semantics |
  | `sparql11-negation/` | 11/12 | `graph-minus` | this engine's semantics |
  | `sparql10-expr-builtin/` | 24/25 | `dawg-lang-3` | term identity (family) |
  | `sparql10-i18n/` | 4/5 | `normalization-2` | term identity (family) |
  | `sparql11-subquery/` | 4/5 | `sq11` | RDF/XML, odin-rdf-parser |

  Only **two** are the evaluation engine's own semantics, and they are one
  question: what a GRAPH clause does to an operator inside it that sees
  more than one solution at a time. SPARQL-T-0015 fixed that shape for the
  blocking operators; the fix transfers to neither of these. SPARQL-T-0013
  recorded that the §18 reading producing the DAWG's `graph-optional`
  answer could not be established from the spec text with confidence and
  declined to fit the code to the expected result — that judgement still
  stands and is why the entry is open rather than passing.

  Two more are **term identity**, not evaluation: `"string"@EN` against
  `"string"@en` (BCP 47 tags are case-insensitive; nothing in the family
  folds the case, so they intern as two keys) and an IRI against its RFC
  3987 syntax-normalized form. The engine compares Term_IDs; the decision
  is made upstream of it, and whatever the answer is it has to hold for
  the RDF parser, both store dictionaries, and the SPARQL parser at once.
  The fifth waits on a format odin-rdf-parser does not implement.

  Filed so the leftovers are actionable rather than remembered:
  **SPARQL-T-0020** (the two GRAPH-scoping entries) and **SPARQL-T-0021**
  (the two term-identity entries) in this repo's backlog.

  **The decision for review:** either re-scope this criterion — the five
  entries above declared out of the initiative's scope with the reasons
  recorded, three of them belonging to other repos — and close the
  initiative; or hold it open for SPARQL-T-0020, which is the only one of
  the three causes that is this engine's to fix. The recommendation is to
  re-scope and close: the initiative's deliverable was the evaluation
  engine, the engine is complete and 99% conformant, and the two open
  semantics entries are a well-characterized backlog item rather than an
  unfinished part of the build.

  *Resolved 2026-08-06: re-scoped as recommended and the initiative
  closed — see the entry above and the re-scope note in the
  Implementation Plan.*

  **Criterion 2 — "1.2 evaluation directories enabled to the extent
  published": met.** All four sparql12 evaluation directories at the
  pinned commit are vendored and fully green (SPARQL-T-0018): 38 + 5 + 2 +
  3 = 48 entries. The three `mf:UpdateEvaluationTest` entries in
  `eval-triple-terms/` are counted and acknowledged as out of engine scope
  by the vision, never silently skipped.

  **Criterion 3 — "store-interface needs documented as evidence-backed
  upstream proposals": met.** The evidence log accumulated across T-0011
  … T-0018 is consolidated into seven backlog items in odin-rdf-store's
  Metis, each naming the operator that wants the capability and what it
  would buy, in the STORE-T-0014 pattern. STORE-A-0002's first review
  trigger — "odin-rdf-sparql's basic graph pattern evaluation lands and
  demonstrates needs the convention cannot absorb" — is discharged in the
  ADR's new Review Log: the convention absorbed a whole query engine
  without an adapter or a revision, and all seven items *extend* the
  procedure set rather than change the convention.

  | Item | Capability | Asked for by |
  |---|---|---|
  | STORE-T-0015 (P1) | Ordered match iteration, and range reads | MIN/MAX, ORDER BY, top-N, merge joins, streaming DISTINCT |
  | STORE-T-0016 (P1) | The named-graph list, and a graph's terms | `Plan_Graph_Scan`, `path_collect_nodes` |
  | STORE-T-0017 (P2) | A named-graph wildcard in the graph position | every `GRAPH ?g { … }` |
  | STORE-T-0018 (P2) | Cardinality estimates for a pattern | `join_order`, the planner seam |
  | STORE-T-0019 (P2) | Snapshot reads: one query, one dataset | all five of a query's read paths |
  | STORE-T-0020 (P3) | `triple_parts`: a triple term's component IDs | SPARQL 1.2 triple-term patterns |
  | STORE-T-0021 (P2) | Reserving the Sentinel counters above UNBOUND | the engine's query-local term names |

  **Criterion 4 — "public API documented to the family standard": met.**
  `sparql`'s package doc now carries the evaluation memory contract (query
  text, algebra, solution rows, materialized terms, result graphs — who
  owns what until when) and the allocator discipline, including the
  per-solution zero-allocation promise and its three stated exceptions.
  Every exported symbol in `sparql`, `sparql/memstore`, and
  `sparql/kvstore` is documented. The README gained a compiled
  query-evaluation example — parse → evaluate against memstore → iterate
  solutions — asserted by `tests/readme` under the SPARQL-T-0009
  README-as-contract convention.

- **2026-08-05 — External dependency resolved: STORE-T-0014 implemented** in odin-rdf-store (commit a5b1d25). `find_term`/`find_graph_label` in both backends, `store.UNBOUND` reserved. Consequences applied: SPARQL-T-0011 no longer has an interim memstore-only path — dual-backend discipline holds from the first green suite; the engine uses `store.UNBOUND` rather than defining its own; over-long-language-tag terms are not-found by design; pattern-level binding composes `find_term` per position (no upstream `find_quad`, intentionally). Nothing now blocks transition to active.
- **2026-08-05 — Decomposed into 10 tasks** (SPARQL-T-0010 … SPARQL-T-0019): eval harness+readers → core runtime/spike/BGP → expression core+FILTER → algebra operators → §17 function library → aggregation+ORDER BY → property paths → result forms → 1.2 eval suites → store evidence+API docs. T-0010 and T-0011 can run in parallel; T-0013/T-0014 parallel after T-0012; T-0016/T-0017 need only T-0011 for their cores but gate suite enablement on the expression tasks; T-0018/T-0019 close out. External dependency: odin-rdf-store STORE-T-0014 (`find_term` + UNBOUND reservation) gates kvstore suite runs — filed in the store's backlog, to be executed in a separate session. Awaiting human review before transition to active.
- **2026-08-05 — Design decisions resolved with human review.** Store-interface audit corrected the draft (ID 0 is a valid term ID) and surfaced the term→ID lookup gap. Decided: distinct UNBOUND sentinel at Sentinel counter 2 (store asked to reserve); `find_term` + UNBOUND-reservation proposals go upstream to odin-rdf-store **now**, before evaluation starts (kvstore queries must not write); backend-binding mechanism picked via phase-1 spike against the real BGP join. Defaults accepted: in-repo test-only SRX/SRJ readers, Jena-compatible ORDER BY total order, BFS reachability for paths, snapshot needs tracked via the evidence log. Next: draft the upstream store proposal, then decompose.
- **2026-08-05 — Created in discovery.** Scope drafted: the full algebra-to-solutions evaluation engine, measured by the W3C evaluation suites, excluding result serialization writers and cost-based planning. Awaiting human review of scope and the design-phase decision list.