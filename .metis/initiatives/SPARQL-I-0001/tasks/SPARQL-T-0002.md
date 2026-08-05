---
id: tokenizer-full-sparql-terminal-set
level: task
title: "Tokenizer: full SPARQL terminal set with positions"
short_code: "SPARQL-T-0002"
created_at: 2026-08-05T09:39:59.873374+00:00
updated_at: 2026-08-05T09:39:59.873374+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Tokenizer: full SPARQL terminal set with positions

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the SPARQL tokenizer: every terminal of the SPARQL 1.1 Query grammar plus the SPARQL 1.2 triple-term additions, with byte offset and 1-based line/column on every token, and the family-shaped sticky error type for the whole package.

## Acceptance Criteria **[REQUIRED]**

- [ ] All SPARQL 1.1 terminals: IRIREF, PNAME_NS/PNAME_LN (with PN_LOCAL escapes and interior dots), BLANK_NODE_LABEL, VAR1/VAR2, LANGTAG, numeric forms (integer/decimal/double, signed), string literals (single/double, long forms, ECHAR/UCHAR escapes), NIL/ANON, case-insensitive keywords, operators and punctuation including the path operators.
- [ ] SPARQL 1.2 additions tokenized from day one: reified-triple/triple-term delimiters (`<<`/`>>` and `<<(`/`)>>` per the current draft) and the directional language-tag suffix (`@lang--dir`).
- [ ] `Error :: struct { kind, offset, line, column }`, flat `Error_Kind` enum, and static allocation-free `error_message(kind)` whose messages end with the violated grammar production name in parentheses — the family shape, defined in this package (the sibling's type is internal and cannot be imported).
- [ ] Unit tests: escape processing, Unicode boundaries, numeric edge forms, keyword case-insensitivity, and exact line/column assertions on malformed input.
- [ ] Zero-allocation token path (tokens borrow source slices) proven by a `mem.Tracking_Allocator` guard test.

## Implementation Notes

### Technical Approach
Single-pass scanner over the caller-owned `[]byte`, modeled on `rdf/internal/scanner` in odin-rdf-parser (sibling checkout at `../odin-rdf-parser`, the path this repo's collection flags point to). Tokens carry offset/line/column; text is a borrowed slice of the source. Scanner errors are sticky and later promoted verbatim by the parser (`scanner_failed` pattern).

### Dependencies
SPARQL-T-0001 (scaffolding, Makefile, guard-test infrastructure).

## Status Updates **[REQUIRED]**

*To be added during implementation*