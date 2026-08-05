---
id: scaffolding-vendored-w3c-suites
level: task
title: "Scaffolding, vendored W3C suites, and harness skeleton"
short_code: "SPARQL-T-0001"
created_at: 2026-08-05T09:38:18.018261+00:00
updated_at: 2026-08-05T09:38:18.018261+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Scaffolding, vendored W3C suites, and harness skeleton

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Set up the repository skeleton in the family style and land the W3C test infrastructure: vendored SPARQL 1.1 query syntax suites with a provenance record, and a manifest-driven harness with per-suite-directory enablement. Deliverable is a green `make test` at both Term_ID widths, with the harness proven able to read manifests — the foundation every later task hangs its suites on.

## Acceptance Criteria **[REQUIRED]**

- [ ] Package layout established (public package plus internal packages, `tests/w3c/`, `tests/guards/`) and `make test` / `make check` green at both widths (`WIDTHS := 64 32`) with `-vet -strict-style`.
- [ ] W3C SPARQL 1.1 query syntax suites vendored under `tests/w3c/` verbatim from `w3c/rdf-tests` at the family's pinned commit `767554e135eb6665949d870e6fa7bbc813837293`; update and federation directories excluded per scope.
- [ ] `tests/w3c/README.md` provenance record mirroring odin-rdf-parser's: upstream repo, pinned commit, retrieval date, license, local-directory → upstream-path table, explicit exclusions.
- [ ] Harness package parses suite manifests with the family's own Turtle parser (`rdf:` collection), walks `mf:entries` preserving order, and asserts a pinned entry count per suite directory (circularity guard).
- [ ] Suite directories are individually enabled; an unhandled `mf:type` fails hard ("nothing may be silently skipped"). Manifest reading is verified against at least one vendored directory now; pass/fail execution wires up when the first directory is enabled (SPARQL-T-0005).

## Implementation Notes

### Technical Approach
Mirror `tests/w3c/harness/` from odin-rdf-parser (manifest.odin pattern, `MANIFEST_BASE`, plain `odin test` — no custom runner). Sibling checkouts sit next to this repo: odin-rdf-parser at `../odin-rdf-parser` and odin-rdf-store at `../odin-rdf-store` (relative to the repo root — the same paths this repo's Makefile and `ols.json` collection flags point to). All family-convention references in this initiative's tasks resolve against those checkouts. Makefile pins an explicit package list the way odin-rdf-store's does (the existing `SRC_DIRS` discovery block already carries a note to do this). Collections wiring (`rdf:`, `store:`) already exists from commit 362cad1.

### Dependencies
None — first task of the initiative.

## Status Updates **[REQUIRED]**

*To be added during implementation*