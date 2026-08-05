---
id: sparql-1-2-syntax-suites-and
level: task
title: "SPARQL 1.2 syntax suites and triple-term completion"
short_code: "SPARQL-T-0008"
created_at: 2026-08-05T09:40:20.441001+00:00
updated_at: 2026-08-05T09:40:20.441001+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# SPARQL 1.2 syntax suites and triple-term completion

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Close out SPARQL 1.2 coverage: vendor the 1.2 syntax test suites, verify the grammar's day-one triple-term support against them, and make sure triple terms flow through algebra translation. Anything the draft leaves unstable is recorded, not silently dropped.

## Acceptance Criteria **[REQUIRED]**

- [ ] SPARQL 1.2 syntax suites vendored — from the `sparql12` directories of `w3c/rdf-tests` at the family's pinned commit if present there, otherwise from a newer pinned commit recorded separately in the provenance README.
- [ ] 1.2 suite directories enabled in the harness and fully green at pinned entry counts.
- [ ] Triple terms flow end-to-end: tokenizer → AST → §18.2 translation (BGPs containing triple-term patterns), with translation tests via the SSE printer.
- [ ] Directional language tags (`@lang--dir`) accepted everywhere literals appear and carried on `rdf.Literal.direction`.
- [ ] Any 1.2 draft forms deliberately deferred as unstable are listed in the provenance README with rationale.

## Implementation Notes

### Technical Approach
Mostly verification and gap-closing: 1.2 syntax has been in the tokenizer (SPARQL-T-0002) and grammar from the start, so this task's work is vendoring the suites, running them, and fixing whatever they flush out. Check the pinned commit first — the parser repo's vendored tree came from the same upstream repo that hosts the sparql12 suites.

### Dependencies
SPARQL-T-0007 (translation, for the algebra-side criteria).

## Status Updates **[REQUIRED]**

*To be added during implementation*