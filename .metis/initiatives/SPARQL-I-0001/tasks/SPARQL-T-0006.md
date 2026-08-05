---
id: algebra-representation-and-sse
level: task
title: "Algebra representation and SSE-compatible printer"
short_code: "SPARQL-T-0006"
created_at: 2026-08-05T09:40:13.917930+00:00
updated_at: 2026-08-05T11:21:54.544407+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Algebra representation and SSE-compatible printer

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Define the algebra representation that the evaluation initiative will consume, plus the SSE-compatible printer used for translation tests and debugging. This is the contract type of the whole project — shape and documentation quality matter more than speed of delivery.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Algebra node types cover §18: BGP, Join, LeftJoin, Filter, Union, Minus, Graph, Extend, Group/Aggregation, path operators, Table (VALUES), and the solution-modifier layers Project/Distinct/Reduced/OrderBy/Slice.
- [x] Terms in the algebra reuse `rdf.Term` and a variable type; ownership follows the family contract (borrowed from the parse, owned by the parser until destroy).
- [x] Printer emits Jena-compatible SSE (operator names, term syntax, prefix handling) — verified by golden tests in ARQ's format (hand-derived; no Jena on the build host — noted in the tests, with live regeneration flagged as a T-0007 option).
- [x] Every exported type carries a doc comment stating invariants and intent (the family's why-not-what standard), since this is the evaluation initiative's input contract.

## Implementation Notes

### Technical Approach
Tagged-union tree in the family style (mirroring how `rdf.Term` is structured). The printer is a straightforward tree walk with an indentation writer over `io.Writer`, matching the emitters' conventions. Golden SSE outputs are generated once from Jena and vendored alongside the tests with provenance noted.

### Dependencies
SPARQL-T-0003 (AST types). Can proceed in parallel with SPARQL-T-0004/0005.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Landed as `sparql/algebra.odin` (16 operator types + `destroy_algebra`), `sparql/algebra_print.odin` (SSE printer), `sparql/algebra_test.odin` (6 golden tests). **Contract decisions for T-0007 and the evaluation initiative:** `Algebra` is a union of `^Alg_*` node pointers covering §18 (BGP with simple-predicate `Alg_Triple`s, `Alg_Path` for composite paths, Join/LeftJoin/Filter/Union/Minus/Graph/Extend/Group/Order/Project/Distinct/Reduced/Slice/Table); the unit table (`Alg_Table.unit`) is the empty group's translation. **Ownership rule (documented in the package comment):** `destroy_algebra` frees the operator tree and its arrays only — `Expr` trees referenced by Filter/Extend/Group/LeftJoin nodes are owned by whoever built them (AST or translation), which destroys them exactly once. Group aggregates bind translation-generated variables named `.0`, `.1`, … (impossible as user syntax, prints as ARQ's `?.0`). `Exists_Expr` gained an `algebra` field the translation fills, so EXISTS prints and evaluates from algebra. **Printer:** ARQ layout (header line + two-space-indented algebra children, parens accumulating), ARQ term syntax (bare lexical forms for xsd:integer/decimal/double/boolean, `_:label`, quoted strings with escapes, `@lang--dir`), ARQ tags incl. the camelCase family (`sameTerm`, `isIRI`, …), n-ary seq/alt folded to nested binary, `(notoneof …)`, `(table unit)`, UNDEF cells omitted from rows, `(slice _ 10 …)` underscores. Goldens are hand-derived in ARQ's exact format — no Jena on this host (checked); the tests carry that provenance note and live regeneration is flagged for T-0007. 53 package tests green; full matrix green at both widths. Not committed; ready for review.