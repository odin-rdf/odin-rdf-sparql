---
id: ast-types-and-parser-core-prologue
level: task
title: "AST types and parser core: prologue, SELECT/ASK, patterns, modifiers"
short_code: "SPARQL-T-0003"
created_at: 2026-08-05T09:40:03.497559+00:00
updated_at: 2026-08-05T09:40:03.497559+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# AST types and parser core: prologue, SELECT/ASK, patterns, modifiers

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Define the AST and implement the recursive-descent parser core: prologue, SELECT/ASK skeletons, dataset clauses, triple patterns with all abbreviations, group graph patterns, GRAPH/OPTIONAL/UNION nesting, and solution modifiers — all under the family memory contract.

## Acceptance Criteria **[REQUIRED]**

- [ ] AST types defined reusing `rdf.Term` as-is (no `Term_ID` anywhere); nodes carry positions for error reporting.
- [ ] Prologue: BASE/PREFIX declarations; prefixed-name and relative-IRI resolution through a parser-owned `rdf.Intern_Table`; undeclared prefix is a positioned error (family precedent: `Undefined_Prefix`).
- [ ] SELECT (DISTINCT/REDUCED, projection list, `*`) and ASK forms; FROM / FROM NAMED dataset clauses.
- [ ] Triple patterns with predicate-object lists, object lists, collections, blank-node property lists, and `a`; blank-node label scoping rules enforced per spec.
- [ ] Group graph patterns with GRAPH, OPTIONAL, UNION nesting; ORDER BY / LIMIT / OFFSET solution modifiers.
- [ ] Family memory contract honored and guard-tested: AST borrows the caller-owned query text, the parser owns derived allocations until `parser_destroy`, tracking-allocator test shows zero leaks.
- [ ] Sticky-error contract: parse failure returns `ok=false` with a positioned `p.err`; per-production unit tests assert exact error positions.

## Implementation Notes

### Technical Approach
Hand-written recursive descent over the token stream, one proc per grammar production, in the style of `../odin-rdf-parser/rdf/internal/ttl/parser.odin` (`fail_at`/`fail_here` helpers, sticky `p.err`). The parse result is a whole-query AST rather than the family's streaming iterator — the memory contract is the same, only the granularity differs (one query, not one statement).

### Dependencies
SPARQL-T-0002 (tokenizer, error type).

## Status Updates **[REQUIRED]**

*To be added during implementation*