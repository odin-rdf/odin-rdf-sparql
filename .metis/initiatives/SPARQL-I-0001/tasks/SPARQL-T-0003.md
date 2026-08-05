---
id: ast-types-and-parser-core-prologue
level: task
title: "AST types and parser core: prologue, SELECT/ASK, patterns, modifiers"
short_code: "SPARQL-T-0003"
created_at: 2026-08-05T09:40:03.497559+00:00
updated_at: 2026-08-05T10:40:11.578946+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# AST types and parser core: prologue, SELECT/ASK, patterns, modifiers

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Define the AST and implement the recursive-descent parser core: prologue, SELECT/ASK skeletons, dataset clauses, triple patterns with all abbreviations, group graph patterns, GRAPH/OPTIONAL/UNION nesting, and solution modifiers — all under the family memory contract.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] AST types defined reusing `rdf.Term` as-is (no `Term_ID` anywhere); nodes carry positions for error reporting.
- [x] Prologue: BASE/PREFIX declarations; prefixed-name and relative-IRI resolution through a parser-owned `rdf.Intern_Table`; undeclared prefix is a positioned error (family precedent: `Undefined_Prefix`).
- [x] SELECT (DISTINCT/REDUCED, projection list, `*`) and ASK forms; FROM / FROM NAMED dataset clauses.
- [x] Triple patterns with predicate-object lists, object lists, collections, blank-node property lists, and `a`; blank-node label scoping rules enforced per spec.
- [x] Group graph patterns with GRAPH, OPTIONAL, UNION nesting; ORDER BY / LIMIT / OFFSET solution modifiers.
- [x] Family memory contract honored and guard-tested: AST borrows the caller-owned query text, the parser owns derived allocations until `parser_destroy`, tracking-allocator test shows zero leaks.
- [x] Sticky-error contract: parse failure returns `ok=false` with a positioned `p.err`; per-production unit tests assert exact error positions.

## Implementation Notes

### Technical Approach
Hand-written recursive descent over the token stream, one proc per grammar production, in the style of `../odin-rdf-parser/rdf/internal/ttl/parser.odin` (`fail_at`/`fail_here` helpers, sticky `p.err`). The parse result is a whole-query AST rather than the family's streaming iterator — the memory contract is the same, only the granularity differs (one query, not one statement).

### Dependencies
SPARQL-T-0002 (tokenizer, error type).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Landed as `sparql/ast.odin` (AST types + recursive destroy), `sparql/parser.odin` (parser core), `sparql/resolve.odin` (RFC 3986 resolver mirrored from odin-rdf-parser's internal `rdf/internal/iri`, which cannot be imported across the collection boundary), plus 11 unit tests and 2 leak guards. Shape notes for the next tasks: **API** is `parser_init(p, source, base := "", allocator)` / `parse(p) -> (^Query, bool)` / `parser_destroy(p)`; the parser owns the query tree, its intern table (all derived strings: prefix expansions, resolved IRIs, unescaped lexical forms, generated blank labels), and scratch buffers. **AST**: `Pattern_Node` flattens `rdf.IRI`/`Blank_Node`/`Literal`/`Var` into one union (triple terms join with T-0008); `Pattern` is `^Basic_Pattern`/`^Group_Pattern`/`^Optional_Pattern`/`^Union_Pattern`/`^Graph_Pattern` (FILTER/BIND extend it in T-0004); `Query.where_clause` (`where` is an Odin keyword). **Decisions**: collections and bnode property lists expand at parse time into `rdf:first/rest`-chained triple patterns with parser-generated labels (stem `.b` — impossible as user syntax, so no collision); bare `[ ]` is an ANON GraphTerm, `[ props ]` a TriplesNode; §19.6 blank-label scoping enforced per TriplesBlock (`Blank_Label_Reuse`); boolean literal lexical forms normalize to `true`/`false`; absolute escape-free IRIs borrow the source (pointer-range asserted in a test); ORDER BY conditions accept `?var` and `ASC/DESC(?var)` until T-0004 widens them to expressions; CONSTRUCT/DESCRIBE report `Expected_Query_Form` until T-0005. Guards: 100 parse/destroy cycles of a construct-dense query and 7 malformed queries all leave `allocation_map` empty. `make check` and `make test` green at both widths. Not committed; ready for review.