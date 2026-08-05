---
id: sparql-query-parser-grammar-to
level: initiative
title: "SPARQL query parser: grammar to algebra"
short_code: "SPARQL-I-0001"
created_at: 2026-08-05T09:15:06.259647+00:00
updated_at: 2026-08-05T09:52:41.926468+00:00
parent: SPARQL-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: L
initiative_id: sparql-query-parser-grammar-to
---

# SPARQL query parser: grammar to algebra Initiative

## Context **[REQUIRED]**

First initiative under SPARQL-V-0001. The vision's "parser first, evaluation incrementally" principle makes this the natural starting point: the grammar → AST → algebra pipeline has zero dependency on odin-rdf-store, so it can start immediately in an empty repo while the evaluation engine (a later initiative) lands operator by operator behind it.

The sibling project odin-rdf-parser sets the house style this initiative must match: hand-written recursive descent, precise position-carrying error reporting with spec references, hermetic vendored W3C test suites as the definition of done, idiomatic Odin with explicit allocator discipline.

The deliverable is the front half of the query engine: SPARQL query text in, SPARQL algebra out. The algebra representation this initiative defines becomes the contract the evaluation initiative consumes, so its shape (and the translation's fidelity to the spec's algebra semantics) is the highest-leverage design decision here.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**
- Full SPARQL 1.1 Query grammar: tokenizer + hand-written recursive-descent parser producing an abstract syntax tree, in the odin-rdf-parser family style.
- Translation from AST to SPARQL algebra per the spec's defined transformation (W3C SPARQL 1.1 Query §18.2), including OPTIONAL/UNION/MINUS, FILTER placement, GROUP BY/aggregates, solution modifiers, subqueries, property paths, and VALUES.
- Error reporting with line/column positions and spec-grammar references, matching odin-rdf-parser's established error style.
- Vendored W3C SPARQL 1.1 syntax test suites (positive and negative) running hermetically; passing them is the completion measure.
- RDF 1.2 / SPARQL 1.2 syntax additions (quoted-triple / triple-term syntax) to the extent their specs are stable, following the RDF-star support already shipped in odin-rdf-parser.
- An algebra representation designed to be consumed by the future evaluation initiative: Term_ID-friendly, allocator-aware, serializable/printable for debugging and tests.

**Non-Goals:**
- Query evaluation of any kind — no store dependency, no execution semantics beyond what the algebra translation itself requires.
- Query planning or algebra optimization (beyond the simplifications the spec's translation itself mandates).
- SPARQL Update grammar (deferred with Update as a whole per the vision).
- The W3C *evaluation* test suites — vendoring may happen here for convenience, but running them belongs to the evaluation initiative.
- Result serialization (SELECT JSON/XML output) — belongs with evaluation/result forms.

## Architecture **[CONDITIONAL: Technically Complex Initiative]**

### Overview

Three-stage pipeline, each stage independently testable:

1. **Tokenizer** — SPARQL terminals (IRIs, prefixed names, literals with datatype/language tags, variables, keywords, punctuation, comments), tracking line/column for every token.
2. **Parser** — hand-written recursive descent over the SPARQL 1.1 grammar producing an AST that mirrors the grammar's structure, including prologue handling (BASE/PREFIX resolution) and blank-node label scoping rules.
3. **Algebra translator** — the spec's §18.2 transformation from AST to algebra: pattern translation (BGP formation, join/leftjoin/union/minus construction, filter attachment), property-path translation, aggregate/projection/solution-modifier layering, and the mandated simplifications.

The AST is a faithful syntax representation (useful for error messages and future tooling); the algebra is the semantic contract the evaluation initiative consumes. Keeping them separate follows the spec's own structure and keeps the translation auditable against §18.2.

## Detailed Design **[REQUIRED]**

Decisions resolved in the design phase (2026-08-05), grounded in an audit of odin-rdf-parser and odin-rdf-store conventions:

- **Memory/lifetime contract — family contract adopted.** Query text is caller-owned `[]byte` and must stay valid for the parser's lifetime; AST/algebra terms borrow from it (zero-copy where possible, matching the RDF-A-0001 discipline), and the parser owns all derived allocations (expanded prefixed names, resolved IRIs, synthesized labels — via an internal `rdf.Intern_Table`, as the Turtle parser does) until `parser_destroy`. `*_init` takes trailing `allocator := context.allocator`; the object owns what it allocates until `*_destroy`. Allocation guards (`mem.Tracking_Allocator`, as in odin-rdf-parser `tests/guards/`) enforce the zero-copy promise in CI. No arena-per-parse — the family has none.
- **Term representation.** The AST reuses `rdf.Term` from the parser collection as-is (`IRI`/`Blank_Node`/`Literal`/`^Triple` union). No `Term_ID` appears anywhere in this initiative; the dictionary belongs to the store, and the evaluation initiative binds terms to IDs later. Parser code must be width-independent; the Makefile's 64/32 test matrix proves it.
- **Error type — family shape mirrored, not imported.** `Error :: struct { kind: Error_Kind, offset, line, column: int }` with a flat SPARQL-specific `Error_Kind` enum; no message string in the struct. Static, allocation-free `error_message(kind)` switch whose messages end with the violated grammar production name in parentheses (production names are stable across spec revisions; numbers are not). Errors are sticky on the parser (`p.err`); `ok=false` with `kind == .None` means clean end of input. The family's type lives in `rdf/internal/scanner` and cannot be imported across the collection boundary, so this package defines its own identical-shaped type.
- **Algebra printer — SSE-compatible.** Jena's s-expression algebra notation, so §18.2 translations can be diffed against Jena's output as an independent correctness oracle, in addition to hand-written expected forms.
- **SPARQL 1.2 syntax — in from the start.** Tokenizer and parser handle quoted-triple/triple-term syntax from day one, matching odin-rdf-parser (RDF 1.2 shipped across all four formats) and `rdf.Term`'s existing `^Triple` variant. Retrofitting triple terms later would touch the tokenizer, the term production, and every pattern rule. The 1.2 *suites* still land as the final phase.
- **Suite progression — enable per suite directory.** The W3C SPARQL 1.1 suites are split across directories (syntax-query, aggregates, property-path, …). Each directory is enabled in the harness only once its features are implemented, with its pinned entry count; once enabled it must be fully green. No skip list, no expected-failure file — the family convention ("nothing may be silently skipped") is preserved; the unit of progression is a whole suite directory.
- **Harness mechanics — inherited verbatim.** Plain `odin test`, no custom runner. Suites vendored under `tests/w3c/<suite>/` from `w3c/rdf-tests`, pinned to the same upstream commit odin-rdf-parser pins (`767554e135eb6665949d870e6fa7bbc813837293`), with a provenance README (commit, license, directory mapping, exclusions). Manifests parsed with the family's own Turtle parser, pinned entry counts per suite as the circularity guard. Update/federation suite directories are excluded per scope.
- **Collections wiring — already in place.** `-collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store` in the Makefile and `ols.json` (commit 362cad1); this initiative uses only `rdf:`.
- **Expression AST**: operators and built-in function calls parse into an expression tree mirroring the grammar; type promotion/evaluation semantics are out of scope, but the tree shape anticipates them (arity checked at parse time where the grammar fixes it).
- **Property paths**: parse to path expressions, translate per §18.4 including the mandated simplification of link-only paths to triple patterns.

## Testing Strategy **[CONDITIONAL: Separate Testing Initiative]**

Suite-driven, per the vision:

- **W3C syntax suites**: vendor the SPARQL 1.1 syntax-query test collections (positive: must parse; negative: must be rejected) and run them hermetically, in the same offline-reproducible style odin-rdf-parser runs its format suites. These define done.
- **Algebra translation tests**: assert translated algebra against expected forms via the algebra printer, sourced from the spec's §18.2 examples and hand-written cases per operator.
- **Unit tests**: tokenizer terminals (escapes, unicode, numeric forms), prologue/prefix resolution, error positions (asserting exact line/column on malformed input).
- **Dual-width discipline**: parser code should be Term_ID-independent; wherever any width sensitivity appears, test both widths per the family convention.

## Alternatives Considered **[REQUIRED]**

- **Vertical slice first (minimal parser + naive evaluation against memstore)**: rejected as the first initiative — earliest end-to-end demo, but risks shaping the grammar work around one query form and reworking the parser later; the vision explicitly sequences parser first. Evaluation follows as its own initiative with a stable algebra contract to build on.
- **Foundations/harness-only initiative**: rejected as too thin — scaffolding and suite vendoring are the natural first tasks *inside* this initiative rather than a deliverable on their own.
- **Parser generator or grammar tooling**: rejected — the family convention is hand-written recursive descent (established by odin-rdf-parser), which also yields the precise, position-carrying errors the vision requires; no external dependencies allowed regardless.
- **Parse straight to algebra (skip the AST)**: rejected — conflates syntax with semantics, makes §18.2 fidelity hard to audit, and loses the syntax tree for error reporting and future tooling. The spec itself defines translation as a separate step.

## Implementation Plan **[REQUIRED]**

Rough phasing; proper decomposition happens at the decompose phase:

1. **Scaffolding + suites**: repo layout in the family style, vendor W3C SPARQL 1.1 syntax suites, harness skeleton that runs manifest-driven tests, with suite directories enabled one at a time as features land (pinned entry counts; enabled = fully green).
2. **Tokenizer**: full SPARQL terminal set with positions; unit tests.
3. **Parser core**: SELECT/ASK skeleton, prologue, triple patterns and group graph patterns, solution modifiers — enough to start passing the easy majority of positive syntax tests.
4. **Parser completion**: expressions and built-ins, property paths, aggregates/GROUP BY/HAVING, subqueries, VALUES, CONSTRUCT/DESCRIBE templates, negation forms.
5. **Algebra translation**: §18.2 transformation with the algebra printer and translation test corpus.
6. **SPARQL 1.2 syntax**: triple-term/quoted-triple forms to the extent stable, plus 1.2 syntax tests if published in vendorable form.

Exit criteria: vendored W3C SPARQL 1.1 syntax suites pass (positive and negative) with zero unexpected failures; algebra translation covered by printer-asserted tests; public parse API documented to the family's contract standard.

## Status Updates

- **2026-08-05 — Decomposed into 9 tasks** (SPARQL-T-0001 … SPARQL-T-0009): scaffolding+suites → tokenizer → parser core → expressions → grammar completion → algebra types+SSE printer → §18.2 translation → 1.2 suites → API/docs. Dependency chain is linear except SPARQL-T-0006 (algebra types), which can run in parallel with T-0004/T-0005. Awaiting human review before transition to active.