---
id: expression-grammar-operators-built
level: task
title: "Expression grammar: operators, built-ins, FILTER/BIND"
short_code: "SPARQL-T-0004"
created_at: 2026-08-05T09:40:08.063764+00:00
updated_at: 2026-08-05T10:55:18.116817+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Expression grammar: operators, built-ins, FILTER/BIND

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the full expression grammar: the operator precedence chain, every built-in call form, EXISTS/NOT EXISTS, custom function calls, FILTER and BIND, and expression projections (`AS`). Type promotion and evaluation semantics stay out of scope — this is syntax and tree shape only.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Precedence chain per the grammar: `||`, `&&`, relational (`=`, `!=`, `<`, `>`, `<=`, `>=`, IN, NOT IN), additive, multiplicative, unary, primary/bracketed — verified by precedence and associativity unit tests.
- [x] Every SPARQL 1.1 built-in call production parses, with arity checked at parse time where the grammar fixes it; SPARQL 1.2 built-ins (TRIPLE, SUBJECT, PREDICATE, OBJECT, isTRIPLE, and the directional-language functions per the current draft) included.
- [x] EXISTS / NOT EXISTS embed group graph patterns in the expression tree.
- [x] Custom function calls (IRI with argument list, DISTINCT where permitted) parse.
- [x] FILTER (all placements the grammar allows) and BIND parse in group graph patterns; `SELECT (expr AS ?var)` projections parse.
- [x] Positioned errors on malformed expressions asserted by unit tests.

## Implementation Notes

### Technical Approach
Classic recursive-descent precedence ladder, one proc per precedence level. The expression tree anticipates the evaluation initiative (operator enum + children; built-ins by enum, custom functions by IRI) without embedding any evaluation semantics. Aggregate call productions (COUNT etc.) are deferred to SPARQL-T-0005 where GROUP BY lands.

### Dependencies
SPARQL-T-0003 (parser core, AST infrastructure).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Landed as `sparql/expr.odin` (expression AST + destroy) and `sparql/expr_parse.odin` (precedence ladder + call forms), with `ast.odin`/`parser.odin` extended: `Filter_Pattern`/`Bind_Pattern` join the `Pattern` union, `Projection` replaces bare vars in `Query.projection` (expr nil for a plain variable), `Order_Condition` now holds an `Expr` and accepts all three OrderCondition forms (Var, Constraint call, ASC/DESC bracketted). **Expression AST**: `Binary_Expr`/`Unary_Expr` with operator enums, `Builtin_Call` identified by the scanner's `Keyword` enum (arity table in `builtin_arity`, checked at parse; BOUND takes a Var only), `Function_Call` by IRI with `is_distinct` (`distinct` is an Odin keyword, like `where` before it), `In_Expr`, `Exists_Expr` embedding a `^Group_Pattern`. **Grammar subtleties handled and pinned by tests**: relational operators do not chain (`?a < ?b = ?c` errors at the `=`); the signed-numeric-literal shorthand (`?x+2*3` scans `+2` as a literal, means `?x + (2*3)`, with the sign lifted into the operator and `*`/`/` binding to the literal first); `NOT` resolves to NOT IN at relational level and NOT EXISTS at primary level; ExpressionList/ArgList accept the NIL token for `()`; aggregates deliberately rejected with `Expected_Expression` until T-0005. Error kinds added: `Expected_Expression`, `Expected_Close_Paren`, `Wrong_Arity` (positioned at the call keyword), `Expected_As`. Tests: 11 new expression tests (39 total in the package); guards extended with an expression-heavy query and 5 more malformed inputs (12 total), all leak-free. `make check`/`make test` green at both widths. Not committed; ready for review.