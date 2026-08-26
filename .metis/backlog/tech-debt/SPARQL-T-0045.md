---
id: adopt-odin-rdf-record-v0-5-0
level: task
title: "Adopt odin-rdf-record v0.5.0: Filter.scope stated at three sites, and what the release means for SPARQL-T-0044"
short_code: "SPARQL-T-0045"
created_at: 2026-08-26T22:19:37.589160+00:00
updated_at: 2026-08-26T22:24:10.581636+00:00
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

# Adopt odin-rdf-record v0.5.0: Filter.scope stated at three sites, and what the release means for SPARQL-T-0044

## Objective **[REQUIRED]**

**odin-rdf-record `v0.5.0` was tagged on 2026-08-27** (`6bc27c4`, `RECORD-T-0029`):
`record.Filter` gained `scope: Graph_Scope { All = 1, Set = 2 }` beside `origin`,
under the same rule — no valid zero, refused by `range_iter` at the first read; under
`.Set` the length of `graphs` alone decides, and an empty set admits nothing. The
reason was found by the application's workspace design: `Filter.graphs` had decided
scoped-versus-unscoped by whether the slice was nil, and Odin makes that a fact about
allocation history, so the same empty set read every graph or nothing.

This task is the family's walk-the-consumers step for that release. **It is small
and precisely bounded**: this engine never constructs a graph set (that is
`SPARQL-T-0044`), so the only change is that every `Filter` it builds states `.All`.

- **Three sites**, found by `grep -rn -E 'origin *= *\.(Any|Asserted|Derived)'
  --include='*.odin' | grep -v scope` — the `Filter{` spelling misses Odin's untyped
  literals, which is how the release notes first said two: `sparql/exec.odin:307`
  and `:332` (`match_open`, `match_open_as` — every read the executor makes), and
  `tests/w3c/harness/dataset.odin:128`.
- **Nothing else moves.** `make test` green against the `v0.5.0` checkout: the W3C
  survey unchanged (546 of 556 evaluable entries, `sparql11-subquery`'s ten RDF/XML
  data documents the only failures, as before), 73 harness tests, the package and
  guard suites; `make check` clean through the import-alias grep. Read counts cannot
  move — the graph check runs inside record's `scan_next`, on the far side of the
  counter — and no solution count did.
- **Not a format change.** Nothing in `Mem_FS` or the suites notices beyond the
  three lines.

A hazard worth carrying, from the record's own adoption: an unstated `Filter` reached
from a spawned thread **hangs** a test runner rather than failing it (the assert kills
the thread the runner is waiting on). This repository's suites are not threaded, and
the grep above is the check; it is recorded here so the next bump of this kind greps
before it runs.

## What it means for SPARQL-T-0044

The design question that task left open — how `query_init` distinguishes "unscoped"
from "scoped to nothing" (a `Maybe`, or a flag) — **is answered by the record**: take
`scope: record.Graph_Scope` and `graphs: []record.Term_ID` and pass them through, so
`query_init(..., scope = .Set, graphs = set)` is the ceiling and `.All` is today's
behaviour spelled out. An empty `.Set` yields no solutions at the record; the engine's
own short-circuit becomes belt and braces rather than the guard. `SPARQL-T-0044`'s
Status carries the note.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Tech Debt - Code improvement or refactoring

### Priority
- [x] P1 - High. CI pinned `v0.4.0` and was green, but the Makefile reaches
      `../odin-rdf-record`, which is `v0.5.0` on any current family checkout: without
      this, every read in this repository asserts at its first call — the same
      argument `SHACL-T-0038` made for its bump.

## Acceptance Criteria

**[REQUIRED]**

- [x] Every `Filter` literal states scope; the grep above finds nothing.
- [x] `.github/workflows/ci.yml` pins `odin-rdf-record@v0.5.0`, with the comment
      explaining the bump beside the `v0.4.0` paragraph, which stands.
- [x] `make test` and `make check` green against `v0.5.0`; solution counts unchanged.
- [x] The vision's Current State re-read; its two pin mentions amended with a dated
      note.
- [x] `SPARQL-T-0044` told what the release settles.

## Status Updates **[REQUIRED]**

- **2026-08-27 — Done in one commit**, the day of the tag, as part of the record's
  release walk (`RECORD-T-0029`). Three sites, one pin, two vision notes; no
  behaviour moved.