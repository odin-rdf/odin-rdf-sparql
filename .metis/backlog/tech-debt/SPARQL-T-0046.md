---
id: adopt-odin-rdf-record-v0-6-0-gpos
level: task
title: "Adopt odin-rdf-record v0.6.0: GPOS reaches this engine with no source change, and the GRAPH case re-measured"
short_code: "SPARQL-T-0046"
created_at: 2026-08-26T22:54:48.096200+00:00
updated_at: 2026-08-26T22:58:10.110230+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#tech-debt"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# Adopt odin-rdf-record v0.6.0: GPOS reaches this engine with no source change, and the GRAPH case re-measured

## Objective **[REQUIRED]**

**odin-rdf-record `v0.6.0` was tagged on 2026-08-27** (`4bf700c`, `RECORD-T-0028`): a
seventh permutation, `GPOS`, with `G` leading — `RECORD-A-0004`'s escape hatch, spent on
its own review trigger for the application's workspace design (a named graph per
workspace; "which `risk:Risk` are in this workspace" not to scan every Risk in the store).
`snapshot_match` chooses it whenever G is bound, S is not, and O is not bound without P.

This task is the family's walk-the-consumers step, and it is the one this repository's
own evidence asked for. `RECORD-T-0026` — filed from here at the close of the port — measured
that a bound graph was always a scan: `GRAPH <g1> { ?s ?p ?o }` considered 169,055
candidates to return 4,122, the whole store, and grew with the store rather than the
answer. This engine calls `snapshot_match`, so **no source changes**; what changes is
what it costs, and `bench/` — built before the port precisely so this kind of thing would
be a number — is the instrument.

## The measurement

`make bench` at `v0.6.0`, instrumented run, `candidates` asserted: **8 pins moved, every
one downward, every solution count identical, no `match`/`next`/`store_ops` count
moved.**

| case | config | candidates before | after | why |
| --- | --- | --- | --- | --- |
| `graph` | small | 20,617 | **4,122** | the window is exactly the graph |
| `graph` | large | 169,055 | **4,122** | the same — flat across a 10× store |
| `optional` | small / large | 2,995 / 25,433 | 2,495 / 24,933 | −500: the named graph's facts are no longer in a default-graph window |
| `order` | small / large | 2,500 / 20,500 | 2,000 / 20,000 | −500, the same |
| `order-limit` | small / large | 2,500 / 20,500 | 2,000 / 20,000 | −500, the same |

Timing, `graph`: **0.064 ms small, 0.065 ms large**, where `SPARQL-T-0036` measured 0.078
and 0.244 against `v0.4.0` and `SPARQL-T-0040` measured 0.100 and 0.101 against the
graph-first LMDB store. So the property `RECORD-T-0026` was built to check — does naming a
graph cost you the data you did not name? — is now "no" here too, and at a lower absolute
cost than the store the comparison was made against. The eight rows are re-pinned in
`bench/config.odin` with a dated note beside the `T-0036` paragraph; `bench/queries.odin`'s
`graph` case says the regression is gone.

The −500s are worth one sentence: every default-graph pattern binds `g =
MATCH_DEFAULT_GRAPH`, so `(G, P, O)` and `(G, P)` patterns now open `GPOS` windows over the
default graph alone, where `POSG`/`PSOG` windows held the named graph's facts too and
`scan_next` dropped them. The benchmark's named graph is 500 entities, and that is the
number.

## What else the seventh order touches here

- **`merge_order_for`** (`sparql/plan.odin`) iterates `record.Order` and now sees `GPOS`.
  It selects it exactly when G and P are ground and the join is on O — a correct window,
  ascending in O within a `(G, P)` prefix, and narrower than `POSG`'s — and never when G
  is a variable. Its comment carries a dated note. The `(G, P, O)`-ground join on S,
  which would find its narrowest window in `GPOS` at depth 3, is outside the loop's
  `0 ..< 3` bound and is left as a measured change to make later, not this walk's.
- **The planner's `range_len` costing** (`plan.odin:2115`) is now exact per graph for
  a G-bound pattern, which is what `SPARQL-T-0044` noted it would become.
- `make test` green — 196 + 6 + 7 + 9 + 73 + 3 tests, the W3C survey unchanged — and
  `make check` clean through the import-alias grep.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Tech Debt - Code improvement or refactoring

### Priority
- [x] P2 - Medium. Nothing breaks below this pin; it is taken the day of the tag under
      the family's release convention, and because the bench's assertions would fail
      against the sibling checkout on every machine until re-pinned.

## Acceptance Criteria

**[REQUIRED]**

- [x] `.github/workflows/ci.yml` pins `odin-rdf-record@v0.6.0`, with the comment beside
      the `v0.5.0` paragraph, which stands.
- [x] `make test` and `make check` green against `v0.6.0`; solution counts unchanged.
- [x] `make bench` passes with the eight moved `candidates` pins re-pinned, and its
      notes say why each moved.
- [x] `merge_order_for`'s comment says what the seventh order does to its choice.
- [x] The vision's Current State re-read; its two pin mentions amended.
- [x] `RECORD-T-0026` told, on the record's side, that it is answered and measured.

## Status Updates **[REQUIRED]**

- **2026-08-27 — Done in one commit**, the day of the tag, as part of the record's
  release walk (`RECORD-T-0028`). One pin, eight re-pins, three notes, two vision
  amendments; no source and no solution moved.