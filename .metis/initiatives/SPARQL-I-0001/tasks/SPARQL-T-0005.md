---
id: grammar-completion-paths
level: task
title: "Grammar completion: paths, aggregates, subqueries, VALUES, templates, negation"
short_code: "SPARQL-T-0005"
created_at: 2026-08-05T09:40:11.068466+00:00
updated_at: 2026-08-05T11:12:17.727346+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Grammar completion: paths, aggregates, subqueries, VALUES, templates, negation

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Complete the SPARQL 1.1 Query grammar — property paths, aggregates with GROUP BY/HAVING, subqueries, VALUES, CONSTRUCT/DESCRIBE templates, MINUS — and turn on the vendored 1.1 syntax suite directories. At the end of this task the parser accepts the full 1.1 language.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Property paths: full path grammar with precedence — alternative (`|`), sequence (`/`), inverse (`^`), `*`/`+`/`?` modifiers, negated property sets, grouping.
- [x] Aggregates: COUNT/SUM/MIN/MAX/AVG/SAMPLE/GROUP_CONCAT (with DISTINCT and SEPARATOR), GROUP BY (expression and `AS` forms), HAVING.
- [x] Subqueries (SubSelect) with their scoping rules; VALUES in both inline and trailing forms.
- [x] CONSTRUCT (including the WHERE-shorthand form) and DESCRIBE templates; MINUS and FILTER (NOT) EXISTS negation forms.
- [x] All vendored SPARQL 1.1 query syntax suite directories enabled in the harness and fully green — positive tests parse, negative tests are rejected — each with its pinned entry count.
- [x] Both-width test matrix green.

## Implementation Notes

### Technical Approach
Continues the recursive-descent parser from SPARQL-T-0003/0004. Path grammar gets its own precedence ladder. This is the task where the harness's pass/fail execution goes live and suite directories flip on one by one as their features land — the per-suite-directory enablement decided in the initiative's design (no skip lists; enabled = fully green).

### Dependencies
SPARQL-T-0004 (expression grammar). SPARQL-T-0001's harness for suite enablement.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review. All four W3C suite directories enabled and green: 154/154 at both widths.** New code: `sparql/parser_full.odin` (paths, aggregates, VALUES, the §19.8 scope checks), extensions through `ast.odin`/`expr.odin`/`parser.odin`/`expr_parse.odin`, and the harness's pass/fail execution (`tests/w3c/harness/harness_test.odin`). **Shapes**: paths are a single `Path_Expr` node type (`Path_Op` enum: Link/Sequence/Alternative/Inverse/modifiers/Negated_Set) joining `Pattern_Node`, with bare-link paths collapsing back to plain `rdf.IRI` predicates; `^Aggregate` joins `Expr` (COUNT(*) via `star`, GROUP_CONCAT separator); `Query` gains `group_by`/`having`/`values`/`template`/`construct_where`/`describe`; `Pattern` gains `^Minus_Pattern`/`^Values_Pattern`/`^Sub_Select`. **§19.8 static rules implemented** (each demanded by a negative suite test or the spec's grammar notes): BIND-target freshness against the preceding elements of its group (in-scope walk per §18.2.1 — MINUS contributes nothing, subselects contribute their projection); SELECT/GROUP BY AS-target freshness; the grouped-query projection restriction (bare projected vars must be grouped; expression vars outside aggregates must be grouped; HAVING likewise); SELECT * with GROUP BY rejected (syn-bad-01 — the only first-run failure, 153/154 before it); VALUES row arity (syn-bad-values tests). **Harness**: positive syntax tests and eval-test queries must parse, negative must be rejected, unhandled mf:type fails hard; base IRI = upstream suite location + file name. One leak found and fixed (partial path tree on error paths, caught by FAIL_ON_BAD_MEMORY). CONSTRUCT templates: no paths, template-scoped blank labels, `construct_where` flags the shorthand (template doubles as pattern; no second copy). One prior unit test updated: aggregates now parse inside FILTER (grammar-legal; placement is the evaluation layer's concern). Totals: 47 unit tests, 3 guards (17 malformed queries), 154 conformance tests — all green at both widths. Not committed; ready for review.