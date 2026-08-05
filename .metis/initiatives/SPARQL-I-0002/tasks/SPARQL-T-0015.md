---
id: blocking-operators-aggregation
level: task
title: "Blocking operators: aggregation, ORDER BY total order, solution modifiers"
short_code: "SPARQL-T-0015"
created_at: 2026-08-05T15:15:39.520940+00:00
updated_at: 2026-08-05T20:19:40.873226+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Blocking operators: aggregation, ORDER BY total order, solution modifiers

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The blocking operators: aggregation — GROUP BY (explicit and implicit single-group), the aggregate functions (COUNT, SUM, MIN, MAX, AVG, GROUP_CONCAT with SEPARATOR, SAMPLE) with DISTINCT modifiers and error semantics, HAVING; and ordering — ORDER BY with the spec's partial order extended to a documented total order (Jena-compatible where the spec is silent), stable sort, and its interaction with projection, DISTINCT, and slice per the §18.2 modifier layering.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Grouping keys computed over Term_IDs where term identity suffices, materialized values where the group expression requires value semantics; group storage bounded by group count, not input size. — `Plan_Group_Key.source` is the fast path: a bare `GROUP BY ?x` keys on the row's Term_ID and never materializes a term. The bound is measured rather than asserted: `test_grouping_is_bounded_by_its_groups` puts 10× the solutions into the same two groups and fails if the query's peak follows the input.
- [x] All aggregates with DISTINCT variants; error handling per spec (an errored input makes the aggregate error → unbound in results, except COUNT/GROUP_CONCAT rules); implicit grouping (aggregate in SELECT without GROUP BY) produces exactly one solution, including over empty input.
- [x] HAVING filters groups using the aggregate-aware expression scope. — falls out of the §18.2.4.1 translation: HAVING is an `Alg_Filter` over the group, reading the `.N` slots the group binds.
- [x] ORDER BY: the extended total order documented in code (order across term kinds, within-kind ordering, unbound first); stable sort; multi-key with ASC/DESC; comparator materializes each row's sort keys once. — `sparql/order.odin`'s header states the extension in full, in four numbered rules.
- [x] Slice after sort per the algebra layering; LIMIT with ORDER BY does not sort more than needed only if trivially achievable — correctness first, no premature optimization beyond key caching. — the slice stays a separate operator; the top-N shortcut is logged as store evidence, not built.
- [x] Aggregation and sorting evaluation directories enabled and fully green (candidates: aggregates, grouping, sort per final harness mapping); dual-width matrix green; blocking materialization goes through the query allocator, guard-checked. — **final mapping: aggregates (42), grouping (4), sort (14), solution-seq (13), project-expression (7)**.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Group hash map keyed on the grouping-key row (Term_IDs + materialized-value keys where needed); aggregates accumulate incrementally per group — no per-group input buffering except GROUP_CONCAT. ORDER BY materializes (row, keys) pairs and sorts with the total-order comparator. Both record their store-evidence notes: ordered iteration from the store would let MIN/MAX/ORDER-BY-by-ID stream — log it, don't build it.

### Dependencies
SPARQL-T-0012 (expressions in group keys, aggregate arguments, HAVING, sort keys). Some suite entries also touch T-0013 operators; enablement follows whichever lands last.

### Risk Considerations
Aggregate error semantics differ per function and are easy to get subtly wrong — encode the spec's definitions as unit cases before suite debugging. The total order beyond the spec's partial order must match what the sorted expected results assume (Jena as tiebreak oracle).

## Status Updates **[REQUIRED]**

### Baseline (survey, memstore)

Before this task: `sparql10-sort` 0/14 and `sparql10-solution-seq` 0/13
(both "unsupported: ORDER BY"), `sparql11-aggregates` 0/42 and
`sparql11-grouping` 0/4 (both "unsupported: GROUP BY"),
`sparql11-project-expression` 6/7, `sparql11-negation` 9/12.

### Results

| Directory | Before | After |
| --- | --- | --- |
| `sparql11-aggregates` | 0/42 | **42/42** |
| `sparql11-grouping` | 0/4 | **4/4** |
| `sparql10-sort` | 0/14 | **14/14** |
| `sparql10-solution-seq` | 0/13 | **13/13** |
| `sparql11-project-expression` | 6/7 | **7/7** |
| `sparql11-negation` | 9/12 | 11/12 |

All five are enabled in `eval_test.odin` and green against both backends
at both Term_ID widths — **392 evaluation tests across twenty-eight
directories**, up from 312 across twenty-three. `make test` green,
`make check` clean.

### Done

Two new engine files, two new test files, four edited.

- **`sparql/order.odin`** — the ORDER BY ordering. §15.1 gives a partial
  order and permits an extension; the header states the extension in
  four numbered rules (across kinds: unbound < blank < IRI < literal <
  triple term; within blank nodes and IRIs by codepoint; within literals
  by value where §15.1 defines one and by lexical form → datatype →
  language where it does not; within triple terms componentwise), so a
  future reader can check the choice rather than reverse-engineer it. The
  sort is a bottom-up merge over a permutation of row indices — stable by
  construction rather than by an index tiebreak that would be stable only
  in a comment.
- **`sparql/aggregate.odin`** — the §18.5.1 set functions as
  accumulators. One accumulator per aggregate per group, fed one
  solution at a time; nothing buffers a group's input. Also `value_key` /
  `term_key` / `id_key`, the term-identity rendering that GROUP BY
  partitions on and DISTINCT deduplicates on.
- **`sparql/plan.odin`, `sparql/exec.odin`** — `Plan_Group` and
  `Plan_Order`, and the two exec nodes. A blocking operator is
  input-driven until its input runs out and a source afterwards, which is
  the shape that lets it be re-run (see the GRAPH note below).
- **`sparql/memstore/blocking_test.odin`** — 13 cases written from
  §18.5.1 and §15.1 directly, one per rule that the suites only test
  incidentally.
- **`tests/guards/guards_test.odin`** — eight blocking queries added to
  the no-leaks loop, plus the group-memory measurement.

Three decisions worth keeping:

**Aggregate error semantics are per function, and are stated per
function.** §18.5.1 does not treat errors uniformly and the difference is
observable: COUNT does not count an error or an unbound value and still
answers; SAMPLE and GROUP_CONCAT skip them and still answer; SUM, AVG,
MIN, and MAX are poisoned by one and come back as an error, which
Extend turns into an unbound variable. `agg-err-01` is exactly that —
one blank node among a group's numbers, and the group's average is
absent while its key is bound. Encoded as unit cases first, as the task's
risk note asked.

**The decimal total is exact, and it has to be.** The value model
evaluates xsd:decimal as a double and says so. An aggregate is where that
stops being a rounding choice: `SUM` over 1.0, 2.2, 3.5, 2.2, 2.2 is
11.1, and *no* order of f64 additions gives the double nearest 11.1 —
every one of them lands a bit above, printing 11.100000000000001
(checked against `math.fsum`, so it is not an association-order artefact
either). The integer and decimal rungs therefore accumulate as an exact
scaled i128 and the result is written from that; a float or a double
anywhere in the group drops the accumulator to f64, where the tower says
the answer is approximate anyway. AVG divides exactly when the quotient
terminates within 18 fraction digits and falls back to f64 otherwise.

**A blocking operator under `GRAPH ?g` has to run once per graph.**
`agg-empty-group-count-graph` is the case: `GRAPH ?g { SELECT (count(*)
AS ?c) … }` expects one answer per named graph, including 0 for the graph
whose FILTER removed everything. Putting ?g in the triple patterns' graph
position — which is how GRAPH is normally compiled away — would match
every graph and collapse them into one answer. So a GRAPH whose body
blocks now enumerates the graphs and evaluates the body per graph, as a
*correlated* materialization: still collected, so its solutions merge
into the enclosing row rather than replacing it (a subquery projects its
own variables and nothing else, so its rows would otherwise arrive with
?g masked back out), but collected once per graph instead of once per
query. The trade is narrow and recorded in `plan.odin`: the body's own
variables are correlated too, which a subquery's scoping says they
should not be, and the alternative is a wrong answer for every query of
this shape.

### One bug found and fixed on the way

A synthetic ID was a serial number, not a name: every computed term got
a fresh one, so `SELECT DISTINCT ?x { VALUES ?x { 1 1 } }` over a store
that had never seen 1 answered twice, and `COUNT(DISTINCT *)` counted
identical solutions separately. Deduplication compares the row's IDs, so
two equal terms have to *be* the same ID. `Exec.computed_index` interns
them; the VALUES-cell path and `bindable_id` both go through it. This
also made the group key's Term_ID fast path sound — a bare `GROUP BY ?x`
now keys on the raw ID, which is only correct because equal IDs are now
equal terms in both directions.

### Left undone, deliberately

- **`sparql11-negation` stays disabled at 11/12.** `graph-minus`
  ("outer GRAPH operator does not affect MINUS disjointness") fails
  because a MINUS inside a GRAPH clause is evaluated against the merge of
  the named graphs rather than against each in turn. It is the same shape
  as the aggregation-inside-GRAPH case fixed here, and MINUS's right side
  is materialized for a *different* reason (its variables are out of
  scope), so the fix is not the same one. It belongs with the rest of the
  GRAPH work; recorded in `tests/w3c/README.md`. Note the directory
  improved from 9/12 to 11/12 here — its two ORDER BY entries now pass.
- **`sparql10-graph` stays at 16/17** and `sparql10-expr-builtin` at
  24/25, both unchanged by this task and both already recorded.
- **Top-N is not special-cased.** `ORDER BY … LIMIT 10` sorts everything.
  The shortcut needs either a bounded heap or an ordered store iterator;
  the second is the one worth having, and it is logged as store evidence
  for SPARQL-T-0019 in `Plan_Order`'s comment alongside MIN/MAX, which
  would become a single range read on the same interface.