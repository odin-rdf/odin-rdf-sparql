---
id: public-api-and-documentation-to
level: task
title: "Public API and documentation to family standard"
short_code: "SPARQL-T-0009"
created_at: 2026-08-05T09:40:27.618935+00:00
updated_at: 2026-08-05T12:09:30.424333+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Public API and documentation to family standard

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Finalize the public API and bring documentation to the family standard: entry-point signatures in the family shape, package doc comments, and a README whose examples are compiled and asserted by tests. This closes the initiative.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Public entry points follow the family shape — `parser_init(p, source, base := "", allocator := context.allocator)`, `parse` and `translate`, `parser_destroy` — with the memory/lifetime contract documented on them (in place since T-0003/T-0007; verified).
- [x] Every package opens with a multi-paragraph doc comment; every exported symbol has a why-not-what doc comment (audit found 22 undocumented exports — mostly AST structs — all now documented).
- [x] README to sibling standard: package table, quick-start (parse → translate → SSE), memory-model section, conformance section with the exact `odin test` commands — example compiled and asserted by `tests/readme` (passing on first run, SSE operator stack included).
- [x] Full matrix green at both widths: 68 unit + 4 guard + 10 W3C suite + 1 readme tests; initiative exit criteria confirmed against SPARQL-I-0001.

## Implementation Notes

### Technical Approach
Audit pass over the whole public surface against odin-rdf-parser's README and doc-comment conventions (sibling checkout at `../odin-rdf-parser`; the README-as-contract test pattern comes from `tests/readme/readme_test.odin` there). Naming is settled last, once the API has stopped moving.

### Dependencies
All prior tasks (SPARQL-T-0001 … SPARQL-T-0008); final task of the initiative.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review. This closes the initiative's task list.** As predicted, the smallest task: the API and most documentation were already at standard from the discipline of earlier tasks. Work done: (1) doc-comment audit — a heuristic sweep found 22 exported symbols without comments (AST structs and enums, `Parser`, `parser_destroy`, `Scanner`, `scanner_init`), all now documented in the why-not-what style; one stale scanner comment (pre-1.2 escape rule) fixed. (2) `README.md` written to the sibling standard: headline (342 in-scope W3C conformance tests passing), family-stack positioning, package table, quick-start showing `parser_init → parse → translate → algebra_to_string` with the expected SSE, the three-part memory model, and the conformance section with exact commands. (3) `tests/readme/readme_test.odin` compiles and asserts the quick-start (including the SSE operator stack) — green on first run; package added to the Makefile's pinned list. (4) Full matrix verified at both widths: 68 unit + 4 guard + 10 suite + 1 readme tests. **Initiative exit criteria all hold**: W3C SPARQL 1.1 syntax suites pass with zero unexpected failures (and 1.2 beyond the original bar); algebra translation covered by printer-asserted tests; the public parse API documented to the family's contract standard. Not committed; ready for review — and SPARQL-I-0001 is ready to transition to completed after this task is accepted.