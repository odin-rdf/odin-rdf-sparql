---
id: blocking-operators-aggregation
level: task
title: "Blocking operators: aggregation, ORDER BY total order, solution modifiers"
short_code: "SPARQL-T-0015"
created_at: 2026-08-05T15:15:39.520940+00:00
updated_at: 2026-08-05T15:15:39.520940+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Blocking operators: aggregation, ORDER BY total order, solution modifiers

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The blocking operators: aggregation — GROUP BY (explicit and implicit single-group), the aggregate functions (COUNT, SUM, MIN, MAX, AVG, GROUP_CONCAT with SEPARATOR, SAMPLE) with DISTINCT modifiers and error semantics, HAVING; and ordering — ORDER BY with the spec's partial order extended to a documented total order (Jena-compatible where the spec is silent), stable sort, and its interaction with projection, DISTINCT, and slice per the §18.2 modifier layering.

## Acceptance Criteria **[REQUIRED]**

- [ ] Grouping keys computed over Term_IDs where term identity suffices, materialized values where the group expression requires value semantics; group storage bounded by group count, not input size.
- [ ] All aggregates with DISTINCT variants; error handling per spec (an errored input makes the aggregate error → unbound in results, except COUNT/GROUP_CONCAT rules); implicit grouping (aggregate in SELECT without GROUP BY) produces exactly one solution, including over empty input.
- [ ] HAVING filters groups using the aggregate-aware expression scope.
- [ ] ORDER BY: the extended total order documented in code (order across term kinds, within-kind ordering, unbound first); stable sort; multi-key with ASC/DESC; comparator materializes each row's sort keys once.
- [ ] Slice after sort per the algebra layering; LIMIT with ORDER BY does not sort more than needed only if trivially achievable — correctness first, no premature optimization beyond key caching.
- [ ] Aggregation and sorting evaluation directories enabled and fully green (candidates: aggregates, grouping, sort per final harness mapping); dual-width matrix green; blocking materialization goes through the query allocator, guard-checked.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Group hash map keyed on the grouping-key row (Term_IDs + materialized-value keys where needed); aggregates accumulate incrementally per group — no per-group input buffering except GROUP_CONCAT. ORDER BY materializes (row, keys) pairs and sorts with the total-order comparator. Both record their store-evidence notes: ordered iteration from the store would let MIN/MAX/ORDER-BY-by-ID stream — log it, don't build it.

### Dependencies
SPARQL-T-0012 (expressions in group keys, aggregate arguments, HAVING, sort keys). Some suite entries also touch T-0013 operators; enablement follows whichever lands last.

### Risk Considerations
Aggregate error semantics differ per function and are easy to get subtly wrong — encode the spec's definitions as unit cases before suite debugging. The total order beyond the spec's partial order must match what the sorted expected results assume (Jena as tiebreak oracle).

## Status Updates **[REQUIRED]**

*To be added during implementation*