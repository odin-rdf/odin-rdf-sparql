---
id: sparql-1-2-syntax-suites-and
level: task
title: "SPARQL 1.2 syntax suites and triple-term completion"
short_code: "SPARQL-T-0008"
created_at: 2026-08-05T09:40:20.441001+00:00
updated_at: 2026-08-05T12:03:05.505392+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# SPARQL 1.2 syntax suites and triple-term completion

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Close out SPARQL 1.2 coverage: vendor the 1.2 syntax test suites, verify the grammar's day-one triple-term support against them, and make sure triple terms flow through algebra translation. Anything the draft leaves unstable is recorded, not silently dropped.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] SPARQL 1.2 syntax suites vendored — six `sparql12` directories from `w3c/rdf-tests` at the family's pinned commit (present there; no newer commit needed).
- [x] 1.2 suite directories enabled in the harness and fully green at pinned entry counts (188 in-scope tests; 20 Update tests explicitly acknowledged out of engine scope).
- [x] Triple terms flow end-to-end: tokenizer → AST → §18.2 translation (BGPs containing triple-term patterns), with translation tests via the SSE printer.
- [x] Directional language tags (`@lang--dir`) accepted everywhere literals appear and carried on `rdf.Literal.direction` (sparql12-lang-basedir green).
- [x] Out-of-scope forms recorded in the provenance README: SPARQL Update tests (vision-level exclusion, type-based, counted by the harness) and the pure-evaluation sparql12 directories left for the evaluation initiative. Nothing draft-unstable needed deferral.

## Implementation Notes

### Technical Approach
Mostly verification and gap-closing: 1.2 syntax has been in the tokenizer (SPARQL-T-0002) and grammar from the start, so this task's work is vendoring the suites, running them, and fixing whatever they flush out. Check the pinned commit first — the parser repo's vendored tree came from the same upstream repo that hosts the sparql12 suites.

### Dependencies
SPARQL-T-0007 (translation, for the algebra-side criteria).

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review. All ten W3C suite directories green at both widths: 154 SPARQL 1.1 + 188 in-scope SPARQL 1.2 tests (20 Update tests explicitly out of engine scope).** The task turned out far larger than "verification and gap-closing" — the 1.2 suites demanded a substantial surface beyond day-one triple-term tokens: **(1) Reifiers and annotations**: `~ reifier` and `{| … |}` (three new tokens: Tilde, Annotation_Open/Close), with reified triples `<< s p o ~ r >>` and annotation suffixes desugaring at parse time into `rdf:reifies` triples over `Triple_Term` nodes (`sparql/parser12.odin`). Triple_Term joined `Pattern_Node` and `Expr`; nodes live in a parser-owned registry freed flatly, because desugaring shares nodes between pattern and reifies triples (recursive destroy would double-free). **(2) The 1.2 codepoint-escape restriction**: escapes confined to strings and IRIs — escaped keywords, prefixed names, and variables now rejected (revising 1.1's anywhere-rule; scanner design made this a clean subtraction). One unit test flipped accordingly. **(3) VERSION declaration** in the prologue (short strings only). **(4) Position/context rules pinned by the suites**: triple-term subjects exclude literals and nested terms in VALUES/expression contexts but not patterns; no blank nodes in expression terms; VALUES terms ground; NIL never a constituent; annotations illegal on path triples; collections DO admit triple terms (my first guess was backwards — the tests corrected it). **(5)** Nested aggregates rejected (`Nested_Aggregate`); grouped-query SELECT-AS freshness now checks the post-grouping visible set (group keys), fixing group-by-scope-1/bad-1/bad-2; VALUES duplicate variables rejected. **Harness**: six sparql12 dirs vendored from the same pinned commit (it contains them — no new pin needed); Update test types (`mf:*UpdateSyntaxTest`/`UpdateEvaluationTest`) acknowledged out-of-scope explicitly and counted in the log — type-level scoping per the vision, not a skip file; README updated. Totals: 68 unit tests + 4 guards (1.2-extended queries) + 10 suites, green at both widths. Not committed; ready for review.