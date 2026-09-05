---
id: adopt-odin-rdf-record-v0-9-1
level: task
title: "Adopt odin-rdf-record v0.9.1: a test-only release, and a defect this repository never had"
short_code: "SPARQL-T-0051"
created_at: 2026-09-05T21:45:00.000000+00:00
updated_at: 2026-09-05T21:45:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"
  - "#tech-debt"


exit_criteria_met: true
initiative_id: NULL
---

# Adopt odin-rdf-record v0.9.1: a test-only release, and a defect this repository never had

## Objective

Move the CI pin from odin-rdf-record `v0.9.0` to `v0.9.1` and re-read this
engine's Current State for anything the release falsifies — the family's
walk-the-consumers rule.

## Context

**odin-rdf-record `v0.9.1` was tagged on 2026-09-05** (`RECORD-T-0047`),
filed by odin-rdf-app. Three of the record's own tests located what they
needed relative to the *process's working directory* rather than to their
own source file — the Python cross-implementation verifier and the
`record` CLI — so a consumer whose suite is one binary,
`odin test <main> -all-packages`, compiled those tests into it, ran them
from its own directory, and got three failures on a tree whose own tests
all pass. They are anchored to `#directory` now, and the CLI test reports
a missing build as a missing build.

**No source, format or API change.** A `v0.9.0` store reads and writes
identically, and nothing this engine names moved.

This repository never had the defect, and is cited in the record's task as
one of the three precedents for the fix: `tests/w3c/harness/dataset.odin`
has located the vendored corpus from its own source file since it was
written. Its suites are also per-package rather than one `-all-packages`
binary over the record, so they never carried the record's tests.

## Acceptance Criteria

- [x] `ci.yml` pins `odin-rdf-record@v0.9.1`, with a comment paragraph in
      the pin's history saying what the release was and why nothing here
      moved.
- [x] `make check`, `make test` and `make bench` green locally against the
      release's content, with every `bench/` count holding.
- [x] Current State re-read: `.metis/vision.md` carries a dated note.
      (README states no record version chain, so there is nothing to
      amend there.)

## Status Updates

- 2026-09-05 — done, pin only. `make check` clean; `make test` green
  across every package (202 + 6 + 7 + 9 + 73 + 3), the W3C survey
  byte-identical — `sparql11-subquery` still the only dark directory, its
  ten RDF/XML data documents the standing ceiling; `make bench` "all
  assertions passed", so every read-count and solution-count pin in
  `bench/config.odin` holds (they fail the run if moved). No source file
  changed. Run against the record's `main` at the release's content
  before the tag was pushed, the family's order for a walk.
