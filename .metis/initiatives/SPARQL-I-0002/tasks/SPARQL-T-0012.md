---
id: expression-engine-core-value-model
level: task
title: "Expression engine core: value model, promotion, EBV, FILTER"
short_code: "SPARQL-T-0012"
created_at: 2026-08-05T15:15:35.283163+00:00
updated_at: 2026-08-05T17:48:36.841597+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Expression engine core: value model, promotion, EBV, FILTER

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The expression engine's core and the FILTER operator: the typed value union (numeric tower xsd:integer/decimal/float/double, boolean, string+lang, dateTime, IRI, blank node, triple term), the single Term_ID → value materialization point through `lookup_term`, spec-faithful numeric type promotion, effective boolean value (EBV), the comparison and arithmetic operator tables (`= != < > <= >=`, `+ - * /`, unary), `sameTerm`/`IN`/`NOT IN`, logical `&& || !` with SPARQL's three-valued error handling, and error-as-unbound at the FILTER boundary. This unlocks the majority of FILTER-dependent evaluation directories.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [ ] Value model with one materialization point; lexical-form parsing for the numeric/dateTime/boolean datatypes with invalid lexical forms producing type errors (not panics).
- [ ] Promotion and comparison per SPARQL §17.3/XPath rules: numeric tower promotion, string/simple-literal comparison, dateTime comparison, open-world `!=` vs unknown-type errors — test cases sourced from the spec's operator tables.
- [ ] EBV per §17.2.2, including the error cases.
- [ ] Three-valued logic: `||`/`&&` recover from one errored branch per spec; FILTER drops rows whose condition errors or is false.
- [ ] FILTER iterator wired into the operator tree at the positions the algebra translation placed them.
- [ ] Evaluation suite directories dominated by operator/EBV semantics enabled and fully green against enabled backends (candidates: expr-ops, expr-equals, boolean-effective-value, bound, open-world, type-promotion — final list pinned in the harness README as they turn green).
- [ ] Dual-width matrix green; expression evaluation allocates only through the query's stated allocator, guard-checked.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Expression trees come from the parser initiative as-is. Evaluate recursively over the value union with an explicit error variant; only FILTER/BIND convert error to drop/unbound. Constant subexpressions may pre-materialize at query setup (small, optional). Numeric literals compare by value within the tower. Keep xsd lexical parsing in one module — the function library (SPARQL-T-0014) and casts reuse it.

### Dependencies
SPARQL-T-0011 (solution rows, operator tree, suite enablement machinery).

### Risk Considerations
The promotion/comparison tables are dense with edge cases (mixed integer/decimal/double, negative zero, NaN, timezone-less dateTimes) — the suites are the oracle; do not improvise beyond spec text.

## Status Updates **[REQUIRED]**

*To be added during implementation*