---
id: expression-engine-core-value-model
level: task
title: "Expression engine core: value model, promotion, EBV, FILTER"
short_code: "SPARQL-T-0012"
created_at: 2026-08-05T15:15:35.283163+00:00
updated_at: 2026-08-05T18:01:31.518266+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Expression engine core: value model, promotion, EBV, FILTER

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The expression engine's core and the FILTER operator: the typed value union (numeric tower xsd:integer/decimal/float/double, boolean, string+lang, dateTime, IRI, blank node, triple term), the single Term_ID → value materialization point through `lookup_term`, spec-faithful numeric type promotion, effective boolean value (EBV), the comparison and arithmetic operator tables (`= != < > <= >=`, `+ - * /`, unary), `sameTerm`/`IN`/`NOT IN`, logical `&& || !` with SPARQL's three-valued error handling, and error-as-unbound at the FILTER boundary. This unlocks the majority of FILTER-dependent evaluation directories.

## Acceptance Criteria

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

- **2026-08-05 — Complete.** `make test` green at both Term_ID widths (sparql 77, sparql/memstore 13, sparql/kvstore 2, guards 6, harness 41), `make check` clean.

  **Delivered.** `sparql/value.odin` — the value model (numeric tower including the derived integer types, simple/language strings, boolean, dateTime, **date**, and an unknown-value literal kind), lexical parsing that rejects forms XSD does not accept even where `strconv` would (`1e5` is not an xsd:decimal; no hexadecimal integers), promotion, comparison, EBV, and the term-inspection functions the operator suites need (DATATYPE, STR, LANG, LANGMATCHES, sameTerm, isIRI/isBLANK/isLITERAL/isNUMERIC). `sparql/expr_eval.odin` — evaluation over the parser's expression trees with a `Term_Loader` procedure pointer for materialization (justified by T-0011's measurement: indirect calls at per-solution frequency are free), three-valued `&&`/`||`, `IN`/`NOT IN`, BOUND, and `expr_check`, which refuses an unimplemented construct **at plan time and by name**. `Plan_Filter` and the `.Filter` operator complete the wiring.

  **Suites enabled** (fully green, both backends, both widths): `sparql10-ask` 4, `sparql10-bnode-coreference` 1, `sparql10-expr-equals` 15, `sparql10-type-promotion` 30 — joining T-0011's two directories for **81 evaluation tests across six directories**.

  **ASK was pulled forward from SPARQL-T-0017.** Its answer is whether the pattern has at least one solution, so it needed no new machinery — and without it this task could have enabled almost nothing, because `sparql10-expr-ops` and `sparql10-type-promotion` state their expectations as ASK queries. T-0017 keeps CONSTRUCT, DESCRIBE, and the rest of the result-form work.

  **Two spec rules the suites forced into shape.** Both were wrong in the first implementation, and both are the kind of wrong that returns rows rather than failing:
  1. **A language tag is a term-level distinction.** `"xyz"@en != "xyz"^^xsd:integer` is *definitely true* — a tagged literal is never an untagged one, whatever the untagged one's ill-typed value might be — while `"xyz" != "xyz"^^xsd:integer` is a *type error*. Derived from the open-eq-08 expectation table, which is exhaustive over the eight literal shapes and is the clearest statement of the rule I found anywhere.
  2. **Partially timezoned dates are indeterminate, not unequal.** A date written without a timezone denotes any instant in a 28-hour window, so it compares definitely against a timezoned value only when the window clears it entirely. `"2006-08-23" = "2006-08-23Z"` is neither true nor false; `"2006-08-23" = "2001-01-01Z"` is definitely false. Three DAWG date tests disagree with every simpler rule (Z-implicit; "mixed timezone is always an error"); only the ±14-hour window satisfies all three.

  With both in place, **`sparql10-open-world` is 17/18 with zero mismatches** — semantically clean, waiting only on a single OPTIONAL. So are `sparql10-boolean-effective-value` (5/7), `sparql10-distinct` (8/11), and `sparql10-algebra` (4/5); `sparql10-expr-ops` (12/18) and `sparql11-functions` (5/12) wait on BIND. That is a useful map for T-0013: the next operator task should turn several directories green at once.

  **Known gaps.** `sparql10-i18n` has one genuine mismatch (`normalization-2`, Unicode normalization of IRIs — a parser/store question, not an expression one). `sparql10-expr-builtin` has three (STR/LANG edge cases) and belongs to SPARQL-T-0014 with the rest of the function library. Decimals are carried as `f64`, so a decimal beyond double precision would compare imprecisely; no vendored test reaches that, and it is stated in `value.odin` rather than left to be discovered.