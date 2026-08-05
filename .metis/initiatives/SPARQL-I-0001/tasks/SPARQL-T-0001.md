---
id: scaffolding-vendored-w3c-suites
level: task
title: "Scaffolding, vendored W3C suites, and harness skeleton"
short_code: "SPARQL-T-0001"
created_at: 2026-08-05T09:38:18.018261+00:00
updated_at: 2026-08-05T10:03:21.686787+00:00
parent: SPARQL-I-0001
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0001
---

# Scaffolding, vendored W3C suites, and harness skeleton

## Parent Initiative

[[SPARQL-I-0001]]

## Objective **[REQUIRED]**

Set up the repository skeleton in the family style and land the W3C test infrastructure: vendored SPARQL 1.1 query syntax suites with a provenance record, and a manifest-driven harness with per-suite-directory enablement. Deliverable is a green `make test` at both Term_ID widths, with the harness proven able to read manifests — the foundation every later task hangs its suites on.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Package layout established (public package plus internal packages, `tests/w3c/`, `tests/guards/`) and `make test` / `make check` green at both widths (`WIDTHS := 64 32`) with `-vet -strict-style`.
- [x] W3C SPARQL 1.1 query syntax suites vendored under `tests/w3c/` verbatim from `w3c/rdf-tests` at the family's pinned commit `767554e135eb6665949d870e6fa7bbc813837293`; update and federation directories excluded per scope.
- [x] `tests/w3c/README.md` provenance record mirroring odin-rdf-parser's: upstream repo, pinned commit, retrieval date, license, local-directory → upstream-path table, explicit exclusions.
- [x] Harness package parses suite manifests with the family's own Turtle parser (`rdf:` collection), walks `mf:entries` preserving order, and asserts a pinned entry count per suite directory (circularity guard).
- [x] Suite directories are individually enabled; an unhandled `mf:type` fails hard ("nothing may be silently skipped"). Manifest reading is verified against at least one vendored directory now; pass/fail execution wires up when the first directory is enabled (SPARQL-T-0005).

## Implementation Notes

### Technical Approach
Mirror `tests/w3c/harness/` from odin-rdf-parser (manifest.odin pattern, `MANIFEST_BASE`, plain `odin test` — no custom runner). Sibling checkouts sit next to this repo: odin-rdf-parser at `../odin-rdf-parser` and odin-rdf-store at `../odin-rdf-store` (relative to the repo root — the same paths this repo's Makefile and `ols.json` collection flags point to). All family-convention references in this initiative's tasks resolve against those checkouts. Makefile pins an explicit package list the way odin-rdf-store's does (the existing `SRC_DIRS` discovery block already carries a note to do this). Collections wiring (`rdf:`, `store:`) already exists from commit 362cad1.

### Dependencies
None — first task of the initiative.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Complete, awaiting review.** Layout: `sparql/` (public package, doc-only until SPARQL-T-0002), `tests/guards/` (placeholder package for allocation guards), `tests/w3c/harness/` (package `w3c`). Vendored four suite directories verbatim from `w3c/rdf-tests` at the family's pinned commit — `sparql11-syntax-query` (94 entries), `sparql11-aggregates` (47), `sparql11-construct` (7), `sparql11-grouping` (6); selection rule: every sparql11 directory whose manifest contains query syntax tests, update/federation excluded. Provenance recorded in `tests/w3c/README.md`. Harness mirrors odin-rdf-parser's `manifest.odin` with two adaptations: collection imports (`rdf:rdf`, `rdf:rdf/turtle`), and mf:action resolution handles both the syntax-test shape (direct IRI) and the eval-test shape (blank node → `qt:query`) so no entry is dropped; entries with unresolvable actions are returned and asserted on, not discarded. Suite tests assert pinned entry counts and on-disk presence of every action/result file. Makefile `PKGS` pinned to the explicit three-package list. `make check` (vet + strict-style) and `make test` green at both Term_ID widths; memory tracking clean. The pinned rdf-tests commit also contains `sparql/sparql12/` — SPARQL-T-0008 can vendor from the same commit. Not committed to git yet; ready for review.