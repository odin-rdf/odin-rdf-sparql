---
id: bench-the-first-measurement-this
level: task
title: "bench/: the first measurement this repository has ever had, and the GRAPH case"
short_code: "SPARQL-T-0036"
created_at: 2026-08-24T20:42:43.053786+00:00
updated_at: 2026-08-24T20:42:43.053786+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# bench/: the first measurement this repository has ever had, and the GRAPH case

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Build the measurement this repository has never had. The `Makefile`'s
`bench` and `build-bench` targets are already written and guard on a
`bench/` directory that does not exist — so every performance claim this
engine has ever made has been an argument rather than a number.

Two things make it due now (owner decision 4). The port has **one known
regression** — `RECORD-A-0004`'s G-residual permutations turn
`GRAPH <g> { … }` from a prefix range into a scan — and there is no way
to size it or to file honest evidence with record without a bench. And
SPARQL-T-0037 and -T-0038 are about to change *what the engine decides*,
which is the one kind of change a green suite cannot detect.

## Acceptance Criteria

- [ ] **A `bench/` package** that builds and runs under the existing
      `make bench` / `make build-bench` targets with `-o:speed
      -no-bounds-check`, with no changes to those targets beyond what the
      collections require.
- [ ] **A fixture corpus larger than the W3C suites**, generated rather
      than vendored, big enough that a scan and a prefix range are
      distinguishable — the suites are far too small to show anything and
      that is precisely why nothing has been measured. Scale it to the
      deployment shape the vision states (~200 processes per machine,
      each embedding a store), not to a server.
- [ ] **A query mix covering the operator classes the port touches**: BGP
      joins of two and three patterns, `GRAPH`, `OPTIONAL`, aggregation
      with `GROUP BY`, `ORDER BY` with and without `LIMIT`, and a
      property path. Each named, each timed, each reported as a line.
- [ ] **The `GRAPH` case measured explicitly and separately**, at more
      than one ratio of default-graph size to named-graph size — the cost
      only bites when the default graph is large relative to the named
      ones, which is exactly the claim that needs numbers rather than
      arithmetic.
- [ ] **Read counting, behind a build-time switch.** Follow
      odin-rdf-shacl's `SHACL_COUNT_READS` precedent: `make bench` becomes
      two builds, one timing and one instrumented, because counting in the
      timed build measures the counter. The counts are what separate "the
      backend moved" from "the engine changed its mind" — odin-rdf-shacl's
      port found read counts survived to the integer while timings moved
      fourfold, and that is the single most useful thing its bench told
      it.
- [ ] **Baselines recorded in this task's Status**, with the machine, the
      record version and the fixture size stated. They are the first
      numbers this repository has; they are *not* comparable to anything
      from odin-rdf-store, and the task must say so rather than inviting
      the comparison.
- [ ] **`bench/` is in `SRC_DIRS`/`make check`** so it cannot rot into
      something that no longer compiles.

## Implementation Notes

### Technical Approach

**Setup goes through the same door as everything else**: `Mem_FS` +
`ingest` + `apply`. A generated corpus as one epoch is the bulk-load
shape record measures at 222–267 ms for 4×10⁵ facts, so fixture
construction will not dominate the run.

**Where to hook the read counter.** With the parapoly seam collapsed
(SPARQL-T-0031) there is no seam struct to wrap, so the counter goes
around record's read calls in the engine — one place if the engine's
calls to `snapshot_match`/`range_iter`/`scan_next` are funnelled, which
is worth arranging in SPARQL-T-0031 if it is cheap. odin-rdf-shacl notes
this exact consequence of one-package layout; steal the answer rather
than rediscovering it.

**Report shape**: one line per case, name + time + reads, stable enough
to diff between runs. Not a framework.

### Dependencies

Blocked by SPARQL-T-0033 — the engine must be correct before it is worth
timing. Deliberately *before* SPARQL-T-0037 and -T-0038, so those two have
a baseline to move rather than a claim to assert.

### Risk Considerations

**A bench that measures the wrong thing is worse than no bench**, because
it launders a guess into a number. The specific trap here: a corpus small
enough to fit in cache makes the `GRAPH` scan look free, and a corpus
built with one enormous named graph makes it look catastrophic. Vary the
ratio and report the shape, not a single figure.

**Scope discipline.** This task exists to make three specific claims
checkable — the GRAPH regression, the "no result changes" of T-0037/38,
and the port's overall cost. It is not a performance-optimization task
and nothing it measures obliges a fix inside this initiative; a finding
becomes a backlog item.

## Status Updates

*To be added during implementation*
