---
id: grammar-completion-paths
level: task
title: "Grammar completion: paths, aggregates, subqueries, VALUES, templates, negation"
short_code: "SPARQL-T-0005"
created_at: 2026-08-05T09:40:11.068466+00:00
updated_at: 2026-08-05T09:40:11.068466+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Grammar completion: paths, aggregates, subqueries, VALUES, templates, negation

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Complete the SPARQL 1.1 Query grammar — property paths, aggregates with GROUP BY/HAVING, subqueries, VALUES, CONSTRUCT/DESCRIBE templates, MINUS — and turn on the vendored 1.1 syntax suite directories. At the end of this task the parser accepts the full 1.1 language.

## Acceptance Criteria **[REQUIRED]**

- [ ] Property paths: full path grammar with precedence — alternative (`|`), sequence (`/`), inverse (`^`), `*`/`+`/`?` modifiers, negated property sets, grouping.
- [ ] Aggregates: COUNT/SUM/MIN/MAX/AVG/SAMPLE/GROUP_CONCAT (with DISTINCT and SEPARATOR), GROUP BY (expression and `AS` forms), HAVING.
- [ ] Subqueries (SubSelect) with their scoping rules; VALUES in both inline and trailing forms.
- [ ] CONSTRUCT (including the WHERE-shorthand form) and DESCRIBE templates; MINUS and FILTER (NOT) EXISTS negation forms.
- [ ] All vendored SPARQL 1.1 query syntax suite directories enabled in the harness and fully green — positive tests parse, negative tests are rejected — each with its pinned entry count.
- [ ] Both-width test matrix green.

## Implementation Notes

### Technical Approach
Continues the recursive-descent parser from SPARQL-T-0003/0004. Path grammar gets its own precedence ladder. This is the task where the harness's pass/fail execution goes live and suite directories flip on one by one as their features land — the per-suite-directory enablement decided in the initiative's design (no skip lists; enabled = fully green).

### Dependencies
SPARQL-T-0004 (expression grammar). SPARQL-T-0001's harness for suite enablement.

## Status Updates **[REQUIRED]**

*To be added during implementation*