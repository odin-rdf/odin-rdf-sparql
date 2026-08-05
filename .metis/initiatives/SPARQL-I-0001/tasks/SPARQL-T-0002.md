---
id: tokenizer-full-sparql-terminal-set
level: task
title: "Tokenizer: full SPARQL terminal set with positions"
short_code: "SPARQL-T-0002"
created_at: 2026-08-05T09:39:59.873374+00:00
updated_at: 2026-08-05T10:19:05.927492+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Tokenizer: full SPARQL terminal set with positions

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Implement the SPARQL tokenizer: every terminal of the SPARQL 1.1 Query grammar plus the SPARQL 1.2 triple-term additions, with byte offset and 1-based line/column on every token, and the family-shaped sticky error type for the whole package.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] All SPARQL 1.1 terminals: IRIREF, PNAME_NS/PNAME_LN (with PN_LOCAL escapes and interior dots), BLANK_NODE_LABEL, VAR1/VAR2, LANGTAG, numeric forms (integer/decimal/double, signed), string literals (single/double, long forms, ECHAR/UCHAR escapes), NIL/ANON, case-insensitive keywords, operators and punctuation including the path operators.
- [x] SPARQL 1.2 additions tokenized from day one: reified-triple/triple-term delimiters (`<<`/`>>` and `<<(`/`)>>` per the current draft) and the directional language-tag suffix (`@lang--dir`).
- [x] `Error :: struct { kind, offset, line, column }`, flat `Error_Kind` enum, and static allocation-free `error_message(kind)` whose messages end with the violated grammar production name in parentheses — the family shape, defined in this package (the sibling's type is internal and cannot be imported).
- [x] Unit tests: escape processing, Unicode boundaries, numeric edge forms, keyword case-insensitivity, and exact line/column assertions on malformed input.
- [x] Zero-allocation token path (tokens borrow source slices) proven by a `mem.Tracking_Allocator` guard test.

## Implementation Notes

### Technical Approach
Single-pass scanner over the caller-owned `[]byte`, modeled on `rdf/internal/scanner` in odin-rdf-parser (sibling checkout at `../odin-rdf-parser`, the path this repo's collection flags point to). Tokens carry offset/line/column; text is a borrowed slice of the source. Scanner errors are sticky and later promoted verbatim by the parser (`scanner_failed` pattern).

### Dependencies
SPARQL-T-0001 (scaffolding, Makefile, guard-test infrastructure).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Tokenizer landed as `sparql/scanner.odin` + `sparql/token.odin` + `sparql/error.odin`, mirroring odin-rdf-parser's internal scanners. Token design: keywords collapse into one `.Keyword` kind carrying a `Keyword` enum value (~100 keywords incl. the 1.2 built-ins); `'a'` is its own case-sensitive kind; `true`/`false` are `.Boolean`. Key semantic decisions, each pinned by a unit test: (1) **Codepoint escapes** (§19.2, pre-grammar, legal anywhere) are handled by `decode_char_at` treating an escape as the single character it denotes at every character-read site — no preprocessing buffer, zero-copy preserved, and an escape-produced character is never re-interpreted (the W3C codepoint-escape-bad-04/05 semantics fall out naturally; a keyword whose first letter is written as a codepoint escape still matches — see test_keyword_through_codepoint_escape). Documented simplification: an escape-produced quote/backslash/newline inside a string is content, not re-tokenized. (2) **Maximal munch on `<`**: speculative IRIREF scan backtracks to `<=`/`<` when the character set rules an IRI out. (3) **SPARQL DECIMAL** requires digits after the dot (`1.` = Integer, Dot), unlike Turtle. (4) **NIL/ANON** are single tokens (`( WS* )` / `[ WS* ]`) with line tracking through the swallowed whitespace. (5) **LANGTAG** has no BCP47 length caps (SPARQL grammar has none) and accepts the 1.2 `--dir` suffix; `ltr`/`rtl` validity is the parser's concern. Tests: 17 unit tests (keywords/case, positions incl. exact error line/column, escapes incl. surrogate rejection, Unicode boundaries, numbers, NIL/ANON, paths/operators, triple terms, lang tags, blank nodes, pnames) + zero-allocation guard (1,000 scans of a token-family-complete query, `total_allocation_count == 0`). `make check` and `make test` green at both widths. Not committed; ready for review.