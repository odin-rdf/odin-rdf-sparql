---
id: adopt-odin-rdf-record-v0-10-0-the
level: task
title: "Adopt odin-rdf-record v0.10.0: the record's CLI release, and a library byte-identical to v0.9.1"
short_code: "SPARQL-T-0052"
created_at: 2026-09-07T19:23:00+00:00
updated_at: 2026-09-07T19:23:00+00:00
parent: 
blocked_by: []
archived: true

tags:
  - "#task"
  - "#phase/completed"
  - "#tech-debt"


exit_criteria_met: true
initiative_id: NULL
---

# Adopt odin-rdf-record v0.10.0

## Objective

Move the CI pin from odin-rdf-record `v0.9.1` to `v0.10.0` and re-read this
engine's Current State for anything the release falsifies — the family's
walk-the-consumers rule.

## Context

**odin-rdf-record `v0.10.0` was tagged on 2026-09-07**, and it is the
record's CLI release rather than the library's:

- `RECORD-T-0048`: the tool installs as **`rdfrecord`**, one word, so it sits
  on PATH beside vsuite-be's `rdfgen`, `rdfcheck`, `rdffmt` and `rdfseed`
  instead of claiming a word as common as "record". `make install` builds it
  at `-o:speed` into `build/rdfrecord-release`, never over the debug binary
  the record's own suite asserts exit codes against.
- `RECORD-T-0050`/`-T-0052`: a fourth subcommand, `stats` — live facts, graph
  count, an `rdf:type` class census, with `--prefix` and
  `--format=plain|json`. Folded from the log rather than answered from a
  booted store, and that is the constraint rather than an oversight:
  `store_open` recovers, resumes the writer, rewrites `HEAD` and can append
  an environment note, and an auditor's tool must not mutate the thing it is
  auditing.
- `RECORD-T-0053`: the §5.5 environment note states the real format version.
  It had `"format":1` as a literal in both `log.md` and the writer, and the
  format became 2 at `RECORD-I-0004` without either moving, so every store
  written between `v0.4.0` and this fix carries a note claiming format 1
  above a header saying 2. Nothing reads the note — the open path compares it
  byte-for-byte and never parses it — so no behaviour depended on it, and
  existing stores correct themselves at their next boot.

**The library is byte-identical to `v0.9.1`**: `doc/api-surface.txt` unmoved
at 74 exported names, no format change, a `v0.9.1` store read and written
identically. This engine links the library and never the tool, so there is
nothing here to adapt — the same shape as `SPARQL-T-0051`, one release
earlier.

## Acceptance Criteria

- [x] `ci.yml` pins `odin-rdf-record@v0.10.0`, with a comment paragraph in
      the pin's history saying what the release was and why nothing here
      moved.
- [x] `make check`, `make test` and `make bench` green locally against the
      release's content, the survey byte-identical and every read and
      solution count in `bench/` unmoved.
- [x] Current State re-read: `.metis/vision.md`'s pin chain carries a dated
      note.

## Status Updates

- 2026-09-07 — done, pin only, no source file changed. `make check` clean
  (every package vetted at both builds, import aliases clean); `make test`
  green with the survey byte-identical — every enabled directory at its
  pinned count, `sparql11-subquery`'s ten RDF/XML data documents the only
  failures and the permanent ceiling they have always been; `make bench`
  "all assertions passed" on both builds, the `graph` case still 4,122
  candidates for 4,122 answers at both sizes and every other read and
  solution count unmoved.