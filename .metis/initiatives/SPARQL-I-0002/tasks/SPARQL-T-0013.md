---
id: algebra-operators-optional-union
level: task
title: "Algebra operators: OPTIONAL, UNION, MINUS, BIND, VALUES, GRAPH, subqueries"
short_code: "SPARQL-T-0013"
created_at: 2026-08-05T15:15:36.690800+00:00
updated_at: 2026-08-05T18:02:25.087049+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Algebra operators: OPTIONAL, UNION, MINUS, BIND, VALUES, GRAPH, subqueries

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The remaining non-blocking algebra operators, completing the operator tree for SELECT queries without aggregation/ordering: leftjoin (OPTIONAL, with the filter-scope semantics §18.2 assigns it), union, minus (with the shared-variable/disjoint-domain rules), extend (BIND), VALUES (join with the inline table), GRAPH (named-graph selection with both constant and variable graph terms), EXISTS/NOT EXISTS (pattern evaluation from inside expressions, per the spec's substitution semantics), projection, DISTINCT/REDUCED, slice (LIMIT/OFFSET), and subqueries (evaluated bottom-up with projection isolation).

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [ ] Each operator as a composable iterator; streaming wherever semantics allow (union, extend, projection, slice stream; DISTINCT keeps a seen-set of Term_ID rows; MINUS materializes its right side).
- [ ] OPTIONAL: leftjoin with the FILTER-inside-OPTIONAL placement the algebra translation produced; nested OPTIONALs correct.
- [ ] MINUS vs NOT EXISTS behavioral difference (disjoint-domain cases) demonstrably correct — unit cases plus the negation suite directories.
- [ ] GRAPH: variable graph iterates named graphs (WILDCARD graph position minus default-graph quads); constant graph binds directly; interaction with dataset description (FROM/FROM NAMED) as the algebra encodes it.
- [ ] EXISTS evaluates its pattern with the current row's bindings substituted, against the same dataset and operator machinery.
- [ ] Subqueries: inner projection isolates variables; DISTINCT/slice inside subqueries respected.
- [ ] Relevant evaluation directories enabled and fully green (candidates: optional, optional-filter, algebra, negation, exists, bind, bindings, graph, dataset, distinct, reduced, subquery, limit-offset per final harness mapping); dual-width matrix green.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
All joins remain Term_ID comparisons; row compatibility = shared slots equal or either UNBOUND. DISTINCT hashes rows of Term_IDs directly (no materialization). EXISTS reuses the operator tree recursively with a substituted-bindings wrapper — watch the spec's known EXISTS substitution subtleties; follow the errata/community consensus where the suites encode it.

### Dependencies
SPARQL-T-0012 (FILTER and expressions are interwoven with OPTIONAL/EXISTS semantics and appear throughout these suite directories).

### Risk Considerations
Largest task by operator count, but each operator is small once T-0011/T-0012 exist; the risk is semantic subtlety (MINUS domains, EXISTS substitution, OPTIONAL filter scope), not volume. The suites plus targeted unit cases are the guard.

## Status Updates **[REQUIRED]**

*To be added during implementation*