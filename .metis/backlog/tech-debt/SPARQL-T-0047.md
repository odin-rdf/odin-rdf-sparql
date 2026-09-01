---
id: adopt-odin-rdf-record-v0-7-0-195
level: task
title: "Adopt odin-rdf-record v0.7.0: 195 exported names become 73, and this engine names none of the missing"
short_code: "SPARQL-T-0047"
created_at: 2026-09-01T12:07:25.996978+00:00
updated_at: 2026-09-01T12:07:25.996978+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#tech-debt"


exit_criteria_met: false
initiative_id: NULL

# Adopt odin-rdf-record v0.7.0: 195 exported names become 73, and this engine names none of the missing

## Objective

Bump the record pin from `v0.6.0` to `v0.7.0` — the first record release that
*removes* names from the store's API rather than adding to it.

## Context

**odin-rdf-record `v0.7.0` was tagged on 2026-09-01** (`61cdfa6`,
`RECORD-I-0005` and `RECORD-I-0007`). Odin exports every top-level declaration
not marked `@(private)`, so the store's surface had been a residue rather than a
decision: **195 exported names, 65 of them the API.** It is **73** now, stated
normatively in `doc/api-surface.txt` with `make api` failing that repository's
build on any drift.

**122 names stopped being exported and this engine missed none of them.** That
is the whole result. `SPARQL-I-0003` claimed this engine reaches the store
through its published read API alone — no backend-specific workaround, no
reaching past the interface, the family convention that "capability gaps become
evidence, not workarounds." A release that deletes two thirds of the surface is
the strongest test that claim will get, and it passed without a line changing.

## Acceptance Criteria

- [x] `.github/workflows/ci.yml` pins `odin-rdf-record@v0.7.0`, with the
      comment beside it saying what the release was.
- [x] `make check` and `make test` green with **no source change**.
- [x] The W3C survey is **byte-identical** to the previous run — 546 of the
      corpus's 556 evaluable entries, 39 directories, `sparql11-subquery` still
      dark on its RDF/XML ceiling.
- [x] `make bench`: `all assertions passed` — every read count and solution
      count unmoved, the `graph` case still 4,122 candidates for 4,122 answers.
- [x] `.metis/vision.md` amended at both sites naming the pin.

## Notes

**The three reads this engine leans on hardest are all in the 73**, which was
worth checking rather than assuming:

- `snapshot_triple_parts` — takes a stored triple term apart into three ids
  with no allocation, no decode and no recursion. `SPARQL-T-0019`'s cost, and
  the reason triple terms are cheaper here than they were on odin-rdf-store.
- `snapshot_match_as` — the ordered read the merge join is built on
  (`SPARQL-T-0029`). Note that it names an `Order` explicitly rather than
  letting the store choose, so `Order`, `Component` and `order_key` surviving
  the cull matters too; they did.
- `range_len` — the exact O(1) candidate count that makes `join_order`
  connected-first-then-cheapest (`SPARQL-T-0037`) rather than the identity
  permutation.

**What is gone that this engine never named:** `replay`, `Consumer`,
`term_decode`, `inline_term`, `Fact_Op`, `Resolve_Iri`, `Resolve_Term`,
`DEFAULT_GRAPH`, `INLINE_FLAG`, `TERM_TAG_IRI`, the encode and writer surfaces,
and the projection builders. Worth one moment's attention: `DEFAULT_GRAPH` is
the *log's* sentinel and is now private, while `MATCH_DEFAULT_GRAPH` — the one
this engine actually uses, to bind the default graph in a `Pattern`'s G
position — is API and unchanged. Two constants with similar names on opposite
sides of the boundary, and the right one survived.

**What is new:** `log_read`, the decoded counterpart to `replay` — walks a log
and hands over `rdf.Quad`s without booting a store. No use here; this engine
queries snapshots. Listed so that a later session does not rediscover it as a
gap.

**Not a format change**, and this engine would still compile against `v0.6.0`.
The floor rises because the family walks its consumers on release, and because
a pin naming the release that made the store's surface a decision is the one
worth stating.
