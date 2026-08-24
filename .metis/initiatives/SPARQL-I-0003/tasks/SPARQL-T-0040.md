---
id: bench-against-the-engine-as-it
level: task
title: "bench/ against the engine as it stands: the baseline the port is judged against"
short_code: "SPARQL-T-0040"
created_at: 2026-08-24T21:28:14.026521+00:00
updated_at: 2026-08-24T21:28:14.026521+00:00
parent: SPARQL-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# bench/ against the engine as it stands: the baseline the port is judged against

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Measure this engine **before** it is ported, so the port has something to
be judged against. This task runs first, against odin-rdf-store, and
changes no engine source.

**Why it exists at all, and why here rather than after the port.**
odin-rdf-shacl's single most valuable port finding was that its **read
counts survived to the integer** — 7503 and seven other pins, identical
over memstore, kvstore and record. `SHACL-T-0036`'s Status records that
its own acceptance criterion had predicted the opposite and asked for the
two to be "stated to be incomparable"; the author had written that into
the prose before the first run and took it out after. That check proved
the engine asked the new store exactly the questions it asked LMDB — that
the port moved cost and not behaviour — and it was **only possible
because `SHACL-I-0003` built bench before the port**.

This repository has no bench at all. Without this task the same check is
structurally impossible here: there would be nothing to compare against,
and "the port changed only cost" would be an assertion. Two further
reasons it belongs before SPARQL-T-0031 rather than after: read counting
is easy today, wrapped around the parapoly seam's adapters, and
materially harder once that seam collapses into direct calls; and
SPARQL-T-0037 and -T-0038 deliberately change *what the engine decides*,
which is the one kind of change a green suite cannot detect.

## Acceptance Criteria

- [ ] **A `bench/` package** building and running under the existing
      `make bench` / `make build-bench` targets, which are already
      written and guard on the directory existing. Release flags
      (`-o:speed -no-bounds-check`), as those targets already specify.
- [ ] **A generated fixture corpus**, larger than the W3C suites — they
      measure correctness and are far too small to show cost, which is
      part of why nothing here has ever been measured. Scaled to the
      vision's deployment shape (~200 processes per machine, each
      embedding a store), not to a server.
- [ ] **A query mix covering the operator classes the port touches**:
      two- and three-pattern BGP joins, `GRAPH`, `OPTIONAL`, aggregation
      with `GROUP BY`, `ORDER BY` with and without `LIMIT`, and a
      property path. Each named, each reported as a line.
- [ ] **The `GRAPH` case measured at more than one ratio** of
      default-graph size to named-graph size. This is the baseline half
      of the initiative's §12 regression: odin-rdf-store answers a bound
      graph as a prefix range because every index is graph-first, and
      record cannot (`RECORD-A-0004`). Without a number from *this* side,
      the record-side evidence is arithmetic rather than measurement.
- [ ] **Read counting behind a build-time switch**, wrapped around the
      seam adapters in `sparql/kvstore/eval.odin` — `match_adapter`,
      `next_adapter`, `load_adapter`, `find_adapter`, `triple_adapter`.
      Follow odin-rdf-shacl's `SHACL_COUNT_READS` precedent: `make bench`
      becomes two builds, one timed and one instrumented, because
      counting inside the timed build measures the counter.
- [ ] **The counts are pinned per case**, as assertions rather than as
      log lines. A pin is what makes SPARQL-T-0036's comparison a test
      instead of a reading; shacl's eight pins are the model.
- [ ] **Baselines recorded in this task's Status**, stating the machine,
      the odin-rdf-store version, the `Term_ID` width and the fixture
      size. Run at both widths, since that matrix still exists at this
      point in the initiative.
- [ ] **`bench/` is in `SRC_DIRS`** so `make check` vets it.
- [ ] **No engine source changes.** If instrumenting requires one, that
      is a finding worth recording — the seam is supposed to be exactly
      the place where this is possible without touching the core.

## Implementation Notes

### Technical Approach

**The five adapters are the whole instrumentation surface**, and they are
the reason this is cheap today: every read the engine performs against
the backend goes through one of them. A counter struct on `Session`,
incremented in each adapter under `when` on the build flag, costs nothing
in the timed build and needs no core change.

**Design the workload deliberately, and read the numbers rather than
reporting them.** `SHACL-I-0003`'s Status is worth reading before
starting: its design phase named "the workload is the risk, not the
harness" in advance, and was right twice — at 100 focus nodes its figures
were confidently wrong (a `dense` configuration timing faster than
`clean` on an identical walk), and per-configuration warm-up alone let
the answer depend on the order of the configuration list. Both were
caught because the failure mode had been named first.

**What survives the port and what does not.** The query mix, the fixture
generator's *shape*, the reporting and the pinned counts survive into
SPARQL-T-0036; the store setup (`open_ephemeral` + `load_*`) is rewritten
there against `Mem_FS` + `ingest` + `apply`. That two-step is exactly
what shacl paid, and it judged the cost worth it.

### Dependencies

None — it measures the engine as it stands. Runs first, in parallel with
SPARQL-T-0030 if convenient. **SPARQL-T-0031 is blocked on it**, because
once the seam collapses the easy instrumentation point is gone and the
"before" numbers can no longer be taken.

### Risk Considerations

**A bench that measures the wrong thing is worse than none**, because it
launders a guess into a number. The specific traps: a corpus small enough
to fit in cache makes the `GRAPH` prefix advantage invisible, and one
enormous named graph exaggerates it. Vary the ratio and report the shape.

**Do not tune anything.** This task establishes a baseline; it is not a
performance-optimization task, and a finding here becomes a backlog item
rather than a fix. Changing the engine now would destroy the very
comparison the task exists to enable.

**The timing half will not be comparable across the port** — LMDB
against a resident projection — and should be reported as context, not as
a target. **The read counts are the comparable half**, and shacl's
experience says to expect them to hold exactly. If they do not, that is
the most interesting result this initiative can produce, and it means the
engine's control flow changed when it was supposed only to change store.

## Status Updates

*To be added during implementation*
