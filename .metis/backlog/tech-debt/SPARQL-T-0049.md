---
id: adopt-odin-rdf-record-v0-9-0
level: task
title: "Adopt odin-rdf-record v0.9.0: snapshot_history, a verb SPARQL has no syntax for"
short_code: "SPARQL-T-0049"
created_at: 2026-09-04T20:30:00.000000+00:00
updated_at: 2026-09-04T20:30:00.000000+00:00
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

# Adopt odin-rdf-record v0.9.0: snapshot_history, a verb SPARQL has no syntax for

## Objective

Move the CI pin from odin-rdf-record `v0.8.0` to `v0.9.0`, re-run `bench/`
against it, and re-read this engine's Current State for anything the release
falsifies — the family's walk-the-consumers rule.

## Context

**odin-rdf-record `v0.9.0` was tagged on 2026-09-04** (`eb270c1`,
`RECORD-T-0044`). One new name, `snapshot_history(snap, p) -> Range`: every
generation a pattern ever matched, visible at the snapshot's epoch or not,
over the same prefix window `snapshot_match` computes and driven by the same
`range_iter` / `scan_next` with the interval test omitted and nothing else. It
is a separate entry point and not a `Filter` option, by `api.md` §12.6's
audit argument — no filter combination may make `snapshot_match` return a
retracted generation, which is the property this engine's every read relies
on. Filed by odin-rdf-app. Not a format change.

**For this engine the release is nothing.** A query evaluates one snapshot's
visible state; as-of is `store_at` where the present uses `store_latest`
(`SPARQL-T-0034`), and SPARQL has no syntax for "at any time". `Exec.filter`
is unchanged, `range_len` is the same exact count `SPARQL-T-0037` plans with,
and `snapshot_match_as` — the merge join's input — is untouched.

## Acceptance Criteria

- [x] `ci.yml` pins `odin-rdf-record@v0.9.0` with a comment paragraph in the
      pin's history.
- [x] `make test` green against the record at the tagged commit; the W3C
      survey byte-identical (546/546 over the evaluable corpus).
- [x] `make bench`: every read count and solution count in `bench/config.odin`
      unmoved — `bgp2` 2 scans / 4,002 candidates, `graph` 4,122 for 4,122,
      `bgp2-narrow-left` 5 scans / 13 — at both sizes; nothing re-pinned.
- [x] The vision's Current State carries the dated note.
- [x] CI green on the pin bump.

## Notes

The verb's one implementation detail worth knowing here: `scan_next` gained
a branch on a `Scan` field that is false for every range this engine makes,
and the candidate-visit cost that `MERGE_SCAN_PRICE` was measured against
did not move within the bench's noise. If a temporal extension were ever
wanted — a `GRAPH`-like operator over epochs — the store-side verb exists.
