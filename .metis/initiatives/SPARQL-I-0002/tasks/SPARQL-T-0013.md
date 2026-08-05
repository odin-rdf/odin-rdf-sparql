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

- **2026-08-05 — Substantially implemented, NOT complete. Left active deliberately.** All the operators are in and everything committed is green (`make test` at both widths, `make check` clean, 53 harness tests), but six directories still have mismatches and EXISTS is not started, so the acceptance criteria are not met. Everything needed to pick this up is below.

  **Done.**
  - **Driver generalized from a chain to a tree.** The walk carries `(node, child)` pairs and an operator returns which child it wants next, so a two-input operator can be suspended mid-right-side and resume there. This is the shape T-0011's compiler constraint forced (no recursion in a generic proc taking `$`-procedure constants) and it turned out to be exactly what the binary operators need. `node_reset` re-runs a subtree without recursing, using the fact that a subtree is a contiguous index range (children are built before parents).
  - **OPTIONAL** (`Plan_Left_Join`) — the right side is re-run per left solution with the left's bindings already in the row, so it probes rather than scans. The hoisted conditions are part of the *match*: a right solution failing them is not a match, and the left solution still comes back unextended. Putting them in a Filter above the join instead is the classic way to get this wrong, and it is commented as such.
  - **UNION**; **MINUS** (right side materialized once — its variables are not in the left's scope — with the shared-variable requirement that distinguishes it from NOT EXISTS); **general Join** (correlated, with a scoped side materialized); **BIND**/Extend; **VALUES**; **GRAPH** (scoped graph position, `GRAPH ?g` binding the variable).
  - **Suites enabled** (fully green, both backends, both widths): `sparql10-boolean-effective-value` 7, `sparql10-bound` 1, `sparql10-distinct` 11, `sparql10-open-world` 18, `sparql10-optional` 7, `sparql10-reduced` 2 — **127 evaluation tests across twelve directories.**

  **Two findings that are store evidence, for SPARQL-T-0019:**
  1. **`GRAPH ?g` cannot be expressed as a match pattern.** It ranges over named graphs; the interface's wildcard in the graph position spans the default graph too, and there is no "any named graph" sentinel. The engine over-fetches and excludes `DEFAULT_GRAPH` during unification. Correct, but it is the interface being unable to say what the query means.
  2. **A computed value has no term ID.** `BIND(?a + ?b AS ?c)` produces a value the store has never seen, and a solution row holds IDs. Interning would make a query a write — the thing the term-binding bridge exists to prevent — so the engine names computed terms itself in the Sentinel ID space (counters from 3 up, which the store reserves and never assigns) and resolves them before asking the store. It works and is safe; that it *had to invent a term space* is the evidence.

  **What remains (measured, not guessed).** Per directory, memstore, from the survey harness:
  - `sparql10-expr-ops` 13/18 — 5 mismatches, most likely the canonical lexical forms of computed numeric values (`value_to_term`'s xsd:decimal / xsd:double rendering).
  - `sparql11-bindings` 7/11 and `sparql11-bind` 7/10 — VALUES and BIND edge cases.
  - `sparql10-graph` 15/17 and `sparql10-algebra` 10/14 — GRAPH and nested-OPTIONAL semantics.
  - `sparql10-optional-filter` 4/5 — one LeftJoin-condition case.
  - `sparql11-exists` 0/6 and `sparql11-negation` 1/12 — **EXISTS is not implemented**; `expr_check` refuses it by name.
  - `sparql10-dataset` 0/12 — FROM / FROM NAMED dataset construction, refused by name in the harness runner.
  - `sparql11-subquery` — blocked on the 10 RDF/XML data documents recorded in SPARQL-T-0010.

  **How to resume.** Re-add the survey harness first: a ~50-line `@(test)` in `tests/w3c/harness` that runs every entry of every `EVAL_SUITES` directory and logs pass/mismatch/unsupported counts plus the got/want text for mismatches. It was removed before committing (it is a development instrument, not a guard), but it is what made every decision in T-0012 and T-0013 measurable rather than speculative. Work down the list above, enabling each directory as it reaches 100%.

  **Session note.** SPARQL-T-0010, T-0011, and T-0012 are complete and committed. SPARQL-T-0014 through T-0019 have not been started.

- **2026-08-05 (later) — Operators finished. Two acceptance criteria remain open; see the end.** Four more directories green — `sparql10-algebra` 14, `sparql10-expr-ops` 18, `sparql10-optional-filter` 5, `sparql11-bind` 10 — for **174 evaluation tests across sixteen directories**, both backends, both widths. `make check` clean.

  **The substantial fix: when a join's right side may be correlated.** Running the right side with the left's bindings already in the row is what makes a join an index probe, and it is wrong in general — SPARQL evaluates a join's operands independently and merges compatible solutions. Pre-binding changes what the right side computes unless it is a pure pattern, where restricting the search and filtering the results coincide. Two failures made this concrete:
  - `{ :x :p ?v } { FILTER(?v = 1) }` has no solutions: inside the second group ?v is not in scope, so the filter errors. Correlated, it sees ?v bound and succeeds.
  - `?X :name "paul" { ?Y :name "george" OPTIONAL { ?X :email ?Z } }` has none either: evaluated independently the OPTIONAL binds ?X to whoever has an email and the join fails on the mismatch. Correlated, the OPTIONAL is restricted to paul's email, finds none, and emits the left row.

  `probe_safe` in plan.odin now decides this: a right side is correlated only when it is built from patterns (BGPs, unions and joins of them, inline tables) plus filters whose every variable the subtree itself binds. Everything else is materialized and merged. This turned `sparql10-algebra` from 10/14 to 14/14 in one change.

  **Four smaller fixes, each found by a disagreeing test rather than by inspection:**
  1. **Result comparison is by value within a datatype.** The DAWG writes the sum of two xsd:floats as `"6"`; XSD canonical form is `"6.0E0"`; elsewhere it writes `"1.0E0"`. No implementation matches both by string, and both denote the same value. Comparing within a datatype keeps the distinctions the tests are about — `"1"^^xsd:integer` and `"1.0"^^xsd:decimal` stay different answers. (This is a harness change, `results.odin`.)
  2. **Unary minus carried the source term ID of the value it negated**, so `BIND(-?v AS ?x)` bound the *un-negated* term. A computed value must not inherit the identity of its input.
  3. **A computed value the store already holds now gets the store's own ID**, so `BIND(?o+1 AS ?z) . ?s ?p ?z` matches — with a synthetic ID it matched nothing. Only a term the data does not contain needs an engine-invented name.
  4. **UNDEF in a VALUES row was conflated with a term the store does not hold.** The first is a solution that leaves the variable unbound; the second makes the row unmatchable. `Plan_Table_Cell` now distinguishes them.

  **A translation bug (SPARQL-I-0001 code).** §18.2.2.6 was hoisting a *nested* group's FILTER onto the enclosing LeftJoin as though it were the OPTIONAL's own. Only a filter that is an element of the OPTIONAL's own group moves. The DAWG ships both expectations for the same query (`optional-filter-005` "simplified" and "not-simplified"), which is exactly how the difference is meant to be caught.

  **Two memory bugs the guards caught**, both on paths the enabled suites do not reach: `value_to_term` produced literals borrowing constant datatype IRIs, which `rdf.destroy_term` then freed (it owns all three strings, so a computed term must own all three); and a binary plan node leaked its already-built left side when its right side turned out to be unsupported.

  **The survey harness is now committed** as `tests/w3c/harness/zz_survey_test.odin`. It asserts nothing and cannot fail; it runs every vendored directory and logs pass/mismatch/unsupported counts, with a `DETAIL` list that prints a directory's got/want. Every enablement decision in T-0012 and T-0013 came out of it, and T-0014 onward will want it.

  **Still open, and why this task is not marked complete:**
  - **EXISTS / NOT EXISTS is not implemented** — an explicit acceptance criterion. `expr_check` refuses it by name. `sparql11-exists` 0/6, `sparql11-negation` 1/12.
  - **FROM / FROM NAMED dataset construction is not implemented** — also an acceptance criterion (`sparql10-dataset` 0/12); the harness runner refuses it by name.
  - `sparql10-graph` 15/17. `graph-empty` needs `GRAPH ?g {}` to enumerate the named graphs, which the match interface cannot express directly — a third store-evidence item for T-0019. `graph-optional` is a separate GRAPH/OPTIONAL scoping case, not yet diagnosed.
  - `sparql11-bindings` 10/11 — the remaining entry is VALUES inside GRAPH binding the same variable as the graph name.
  - `sparql11-subquery` still blocked on the 10 RDF/XML data documents (SPARQL-T-0010).
  - Out of this task's scope but visible in the survey: `sparql10-expr-builtin` 22/25 and `sparql10-i18n` 4/5 (Unicode normalization of IRIs — a parser/store question).