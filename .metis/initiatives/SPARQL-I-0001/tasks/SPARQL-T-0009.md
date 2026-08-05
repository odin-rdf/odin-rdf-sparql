---
id: public-api-and-documentation-to
level: task
title: "Public API and documentation to family standard"
short_code: "SPARQL-T-0009"
created_at: 2026-08-05T09:40:27.618935+00:00
updated_at: 2026-08-05T09:40:27.618935+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Public API and documentation to family standard

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Finalize the public API and bring documentation to the family standard: entry-point signatures in the family shape, package doc comments, and a README whose examples are compiled and asserted by tests. This closes the initiative.

## Acceptance Criteria **[REQUIRED]**

- [ ] Public entry points follow the family shape — `parser_init(p, source, base := "", allocator := context.allocator)`, a parse/translate call returning the query and its algebra, `parser_destroy` — with the memory/lifetime contract documented where the sibling packages document theirs.
- [ ] Every package opens with a multi-paragraph `// Package …` doc comment (scope, memory contract, cross-references to sibling packages and Metis short codes); every exported symbol has a why-not-what doc comment.
- [ ] README to sibling standard: package table, quick-start example (parse a query, print its SSE algebra), memory-model section, conformance section listing the exact `odin test` commands — with examples compiled and asserted by a `tests/readme` package.
- [ ] Full matrix green: all enabled W3C suites (1.1 and 1.2), guard tests, and readme tests at both Term_ID widths; initiative exit criteria checked off against SPARQL-I-0001.

## Implementation Notes

### Technical Approach
Audit pass over the whole public surface against odin-rdf-parser's README and doc-comment conventions (sibling checkout at `../odin-rdf-parser`; the README-as-contract test pattern comes from `tests/readme/readme_test.odin` there). Naming is settled last, once the API has stopped moving.

### Dependencies
All prior tasks (SPARQL-T-0001 … SPARQL-T-0008); final task of the initiative.

## Status Updates **[REQUIRED]**

*To be added during implementation*