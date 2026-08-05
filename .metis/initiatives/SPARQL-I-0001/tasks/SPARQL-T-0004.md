---
id: expression-grammar-operators-built
level: task
title: "Expression grammar: operators, built-ins, FILTER/BIND"
short_code: "SPARQL-T-0004"
created_at: 2026-08-05T09:40:08.063764+00:00
updated_at: 2026-08-05T09:40:08.063764+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Expression grammar: operators, built-ins, FILTER/BIND

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the full expression grammar: the operator precedence chain, every built-in call form, EXISTS/NOT EXISTS, custom function calls, FILTER and BIND, and expression projections (`AS`). Type promotion and evaluation semantics stay out of scope — this is syntax and tree shape only.

## Acceptance Criteria **[REQUIRED]**

- [ ] Precedence chain per the grammar: `||`, `&&`, relational (`=`, `!=`, `<`, `>`, `<=`, `>=`, IN, NOT IN), additive, multiplicative, unary, primary/bracketed — verified by precedence and associativity unit tests.
- [ ] Every SPARQL 1.1 built-in call production parses, with arity checked at parse time where the grammar fixes it; SPARQL 1.2 built-ins (TRIPLE, SUBJECT, PREDICATE, OBJECT, isTRIPLE, and the directional-language functions per the current draft) included.
- [ ] EXISTS / NOT EXISTS embed group graph patterns in the expression tree.
- [ ] Custom function calls (IRI with argument list, DISTINCT where permitted) parse.
- [ ] FILTER (all placements the grammar allows) and BIND parse in group graph patterns; `SELECT (expr AS ?var)` projections parse.
- [ ] Positioned errors on malformed expressions asserted by unit tests.

## Implementation Notes

### Technical Approach
Classic recursive-descent precedence ladder, one proc per precedence level. The expression tree anticipates the evaluation initiative (operator enum + children; built-ins by enum, custom functions by IRI) without embedding any evaluation semantics. Aggregate call productions (COUNT etc.) are deferred to SPARQL-T-0005 where GROUP BY lands.

### Dependencies
SPARQL-T-0003 (parser core, AST infrastructure).

## Status Updates **[REQUIRED]**

*To be added during implementation*