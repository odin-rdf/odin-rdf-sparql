---
id: algebra-translation-the-18-2-18-4
level: task
title: "Algebra translation: the §18.2/§18.4 transformation with test corpus"
short_code: "SPARQL-T-0007"
created_at: 2026-08-05T09:40:17.082296+00:00
updated_at: 2026-08-05T09:40:17.082296+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Algebra translation: the §18.2/§18.4 transformation with test corpus

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the spec's AST-to-algebra transformation (SPARQL 1.1 Query §18.2, paths §18.4) with a printer-asserted test corpus. This is where the parser's output becomes the semantic contract the evaluation engine executes.

## Acceptance Criteria **[REQUIRED]**

- [ ] Pattern translation per §18.2.2: expand syntax forms, collect FILTERs, form BGPs, build Join/LeftJoin/Union/Minus/Graph/Extend, then apply the mandated simplification step.
- [ ] Path translation per §18.4, including the required simplification of link-only paths to plain triple patterns.
- [ ] Aggregation and projection layering per §18.2.4: GROUP/aggregate substitution, HAVING, projection expressions, and solution modifiers applied in spec order (ToList → OrderBy → Project → Distinct/Reduced → Slice).
- [ ] Subqueries and VALUES translated; in-scope variable rules per §18.2.1 honored (assignment collisions rejected where the spec requires).
- [ ] Translation test corpus: the spec's own §18.2 examples plus hand-written cases per operator, asserted via the SSE printer; representative outputs cross-checked against Jena.

## Implementation Notes

### Technical Approach
A separate translation pass over the AST producing the SPARQL-T-0006 algebra types — never parse-to-algebra directly (initiative design decision: keeping the steps separate keeps §18.2 fidelity auditable). Follow the spec's transformation pseudocode closely enough that code review can be done against the spec text side by side.

### Dependencies
SPARQL-T-0005 (complete grammar/AST), SPARQL-T-0006 (algebra types and printer).

## Status Updates **[REQUIRED]**

*To be added during implementation*