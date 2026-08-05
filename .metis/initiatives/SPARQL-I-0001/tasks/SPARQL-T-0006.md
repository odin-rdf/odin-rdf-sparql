---
id: algebra-representation-and-sse
level: task
title: "Algebra representation and SSE-compatible printer"
short_code: "SPARQL-T-0006"
created_at: 2026-08-05T09:40:13.917930+00:00
updated_at: 2026-08-05T09:40:13.917930+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Algebra representation and SSE-compatible printer

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Define the algebra representation that the evaluation initiative will consume, plus the SSE-compatible printer used for translation tests and debugging. This is the contract type of the whole project — shape and documentation quality matter more than speed of delivery.

## Acceptance Criteria **[REQUIRED]**

- [ ] Algebra node types cover §18: BGP, Join, LeftJoin, Filter, Union, Minus, Graph, Extend, Group/Aggregation, path operators, Table (VALUES), and the solution-modifier layers Project/Distinct/Reduced/OrderBy/Slice.
- [ ] Terms in the algebra reuse `rdf.Term` and a variable type; ownership follows the family contract (borrowed from the parse, owned by the parser until destroy).
- [ ] Printer emits Jena-compatible SSE (operator names, term syntax, prefix handling) — verified by golden tests against representative Jena `arq.qparse --print op` outputs.
- [ ] Every exported type carries a doc comment stating invariants and intent (the family's why-not-what standard), since this is the evaluation initiative's input contract.

## Implementation Notes

### Technical Approach
Tagged-union tree in the family style (mirroring how `rdf.Term` is structured). The printer is a straightforward tree walk with an indentation writer over `io.Writer`, matching the emitters' conventions. Golden SSE outputs are generated once from Jena and vendored alongside the tests with provenance noted.

### Dependencies
SPARQL-T-0003 (AST types). Can proceed in parallel with SPARQL-T-0004/0005.

## Status Updates **[REQUIRED]**

*To be added during implementation*