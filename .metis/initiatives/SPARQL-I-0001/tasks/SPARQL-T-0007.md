---
id: algebra-translation-the-18-2-18-4
level: task
title: "Algebra translation: the §18.2/§18.4 transformation with test corpus"
short_code: "SPARQL-T-0007"
created_at: 2026-08-05T09:40:17.082296+00:00
updated_at: 2026-08-05T11:44:25.553964+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Algebra translation: the §18.2/§18.4 transformation with test corpus

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the spec's AST-to-algebra transformation (SPARQL 1.1 Query §18.2, paths §18.4) with a printer-asserted test corpus. This is where the parser's output becomes the semantic contract the evaluation engine executes.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Pattern translation per §18.2.2: expand syntax forms, collect FILTERs, form BGPs, build Join/LeftJoin/Union/Minus/Graph/Extend, then apply the mandated simplification step.
- [x] Path translation per §18.4, including the required simplification of link-only paths to plain triple patterns.
- [x] Aggregation and projection layering per §18.2.4: GROUP/aggregate substitution, HAVING, projection expressions, and solution modifiers applied in spec order (ToList → OrderBy → Project → Distinct/Reduced → Slice).
- [x] Subqueries and VALUES translated; in-scope variable rules per §18.2.1 honored (assignment collisions rejected at parse time, SPARQL-T-0005).
- [x] Translation test corpus: the spec's own §18.2 example shapes plus hand-written cases per operator, asserted via the SSE printer in ARQ's notation (hand-derived — no Jena on the build host, as recorded in T-0006).

## Implementation Notes

### Technical Approach
A separate translation pass over the AST producing the SPARQL-T-0006 algebra types — never parse-to-algebra directly (initiative design decision: keeping the steps separate keeps §18.2 fidelity auditable). Follow the spec's transformation pseudocode closely enough that code review can be done against the spec text side by side.

### Dependencies
SPARQL-T-0005 (complete grammar/AST), SPARQL-T-0006 (algebra types and printer).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Landed as `sparql/translate.odin` (~420 lines, written to review side-by-side with the spec) and `sparql/translate_test.odin` (9 corpus tests, 24 full pipeline assertions). **API**: `translate(p)` after a successful `parse(p)`; result stored as `p.algebra`, freed by `parser_destroy` — the parser owns text-derived strings, AST, and algebra alike. **The ownership twist** (documented in the file header): aggregate substitution rewrites projection/HAVING/ORDER expressions in place, replacing each `^Aggregate` subtree with its generated `.N` variable; detached subtrees move to `p.detached`, freed by `parser_destroy` — so every Expr is destroyed exactly once and the AST shows post-substitution forms after translate. **§18.2.2**: filters collect group-wide and wrap last; nil-accumulator makes Join(Z, A) = A (the §18.2.2.8 simplification); OPTIONAL hoists the inner filter's whole condition list onto the LeftJoin (`Alg_Left_Join.condition` widened to `conditions: [dynamic]Expr` mid-task — hoisting only single conditions would have silently changed OPTIONAL semantics); MINUS/Extend/LeftJoin consume the accumulated left side; unions fold left-leaning. **§18.4**: inv(P) recurses with swapped endpoints (so `^(p/q)` reverses the chain), sequences decompose through fresh `.pN` variables, alt/mods/negated-sets stay `Alg_Path`, mixed blocks join in order (deviation noted: Join where ARQ prints its `sequence` optimization). **§18.2.4/18.2.5 layering**: Group (explicit or implicit) → HAVING filter → trailing VALUES join → one Extend for SELECT expressions → Order → Project (dropped for SELECT *, as ARQ drops it) → Distinct/Reduced → Slice. EXISTS anywhere in any expression gets its `algebra` field filled (idempotent walk). CONSTRUCT/DESCRIBE translate their pattern only; `construct_where` uses the template as the pattern. New guard: 50 parse+translate+destroy cycles of a query exercising aggregates, EXISTS in HAVING, subselect, paths, OPTIONAL-with-two-filters — zero leaks. Totals: 62 package tests + 4 guards + 154 conformance tests green at both widths. Not committed; ready for review.