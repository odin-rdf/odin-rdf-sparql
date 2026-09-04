---
id: adopt-odin-rdf-record-v0-8-0-the
level: task
title: "Adopt odin-rdf-record v0.8.0: the permutations are B+trees, matches faster, every pin unmoved"
short_code: "SPARQL-T-0048"
created_at: 2026-09-04T19:40:00.000000+00:00
updated_at: 2026-09-04T19:40:00.000000+00:00
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

# Adopt odin-rdf-record v0.8.0: the permutations are B+trees, matches faster, every pin unmoved

## Objective

Move the CI pin from odin-rdf-record `v0.7.0` to `v0.8.0`, re-run `bench/`
against it, and re-read this engine's Current State for anything the release
falsifies — the family's walk-the-consumers rule.

## Context

**odin-rdf-record `v0.8.0` was tagged on 2026-09-04** (`975693b`,
`RECORD-I-0009`, `RECORD-A-0012`). Each of the record's seven permutations is
now a copy-on-write B+tree of fact ids instead of a flat sorted slice re-sorted
on every commit: a commit there is **0.24 ms** where it was 37, and the
read side changed shape without changing contract — `snapshot_match` and
`snapshot_match_as` are two rank descents comparing keys held in inner nodes,
`range_len` is the difference of two ranks and still the exact O(1) candidate
count `SPARQL-T-0037` plans with, and `scan_next` walks a cursor over leaves.
Not a format change.

**Two things this engine depends on were re-proven on the record's side.**
`snapshot_match_as`'s output order — fact id breaking ties within the named
order, which the merge join of `SPARQL-T-0029` walks in step — is asserted by
a record test over every order and nine prefixes on a duplicate-heavy corpus.
And `range_len` stays exact, so `join_order` and `MERGE_SCAN_PRICE` price the
same numbers they did.

## Acceptance Criteria

- [x] `ci.yml` pins `odin-rdf-record@v0.8.0` with a comment paragraph in the
      pin's history.
- [x] `make test` green against the tag; the W3C survey byte-identical
      (546/546 over the evaluable corpus).
- [x] `make bench`: every read count and solution count in `bench/config.odin`
      unmoved — `bgp2` 2 scans / 4,002 candidates, `graph` 4,122 for 4,122,
      `bgp2-narrow-left` 5 scans / 13 — at both sizes; nothing re-pinned.
- [x] The vision's Current State carries the dated note.
- [x] CI green on the pin bump.

## Notes

The record's own benchmark shows matches 10–30% faster; `bench/`'s timings
are not pinned and moved within noise here, since this engine's cases are
dominated by candidate visits rather than bound searches. `Range.main`,
`Range.delta` and `Scan.ids` are gone from the record's structs; this engine
never named them, which is the "consume the interface" convention doing its
work for the third release running.
