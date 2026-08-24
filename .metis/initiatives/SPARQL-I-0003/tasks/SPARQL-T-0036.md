---
id: bench-the-first-measurement-this
level: task
title: "bench/ rebuilt against record: the same workload, and whether the read counts held"
short_code: "SPARQL-T-0036"
created_at: 2026-08-24T20:42:43.053786+00:00
updated_at: 2026-08-24T20:42:43.053786+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033", "SPARQL-T-0040"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# bench/ rebuilt against record: the same workload, and whether the read counts held

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Rebuild SPARQL-T-0040's bench against record — same workload, same query
mix, same pinned counts — and answer the question the two-step exists
for: **did the read counts hold?**

odin-rdf-shacl's port found that its did, to the integer, across three
backends; its own acceptance criterion had predicted they would not and
the measurement reversed it. If sparql's hold too, the port moved cost
and not behaviour, which is the strongest statement this initiative can
make about its own correctness. If they do not, the engine's control
flow changed when it was supposed only to change store — the most
interesting result available here, and one that sends work back to
SPARQL-T-0031 rather than forward.

It also produces the record-side half of the initiative's §12 evidence:
`RECORD-A-0004`'s G-residual permutations turn `GRAPH <g> { … }` from a
prefix range into a scan, and T-0040 measured what that cost on the
store.

## Acceptance Criteria

- [ ] **The same workload, ported.** SPARQL-T-0040's query mix, fixture
      generator shape, reporting and pinned counts carry over unchanged;
      only the store setup is rewritten — `open_ephemeral` + `load_*`
      becomes `Mem_FS` + `store_open` + `ingest` + `apply`. A workload
      that drifts in the rebuild answers a different question and makes
      the comparison meaningless.
- [ ] **The read counts are compared against T-0040's pins, and the
      result is reported either way.** This is the task's headline.
      Equal counts mean the engine asks record exactly the questions it
      asked LMDB — the port moved cost, not behaviour. Unequal counts
      mean the control flow changed when only the store was supposed to,
      and the finding goes back to SPARQL-T-0031 rather than forward.
      **Do not write the verdict before the run**: shacl's equivalent
      criterion predicted the counts would be incomparable, and its
      Status records the author taking that prose back out after the
      first run.
- [ ] **Read counting rehomed.** With the parapoly seam collapsed there
      is no adapter struct to wrap, so the counter goes around the
      engine's calls to `snapshot_match` / `range_iter` / `scan_next` /
      `snapshot_resolve` / `snapshot_term`. `make bench` stays two
      builds — timed and instrumented — because counting inside the
      timed build measures the counter.
- [ ] **The `GRAPH` case re-measured at the same ratios**, giving the
      record-side half of the initiative's §12 evidence. T-0040 measured
      what a graph-first index cost; this measures what
      `RECORD-A-0004`'s G-residual permutations cost, and the pair is
      what SPARQL-T-0039 files with record. **Neither number alone is
      evidence.**
- [ ] **Timings reported as context, not as a target.** LMDB against a
      resident projection is not a like-for-like comparison and the task
      says so. shacl's moved roughly fourfold on validate; expect
      movement here and do not read it as a result.
- [ ] **New baselines recorded in this task's Status**, stating machine,
      record version and fixture size — and noting that the width matrix
      is gone, so unlike T-0040's these are single-configuration.
- [ ] **`bench/` stays in `SRC_DIRS`** and `make check` vets both builds.

## Implementation Notes

### Technical Approach

**Setup goes through the same door as everything else**: `Mem_FS` +
`ingest` + `apply`. A generated corpus as one epoch is the bulk-load
shape record measures at 222–267 ms for 4×10⁵ facts, so fixture
construction will not dominate the run.

**Where to hook the read counter.** With the parapoly seam collapsed
(SPARQL-T-0031) there is no seam struct to wrap, so the counter goes
around record's read calls in the engine. **Funnelling those calls
through one place is worth arranging during SPARQL-T-0031**, while that
file is open anyway — it is much cheaper than retrofitting a counter into
scattered direct calls afterwards. odin-rdf-shacl hit this exact
consequence of the one-package layout; steal the answer rather than
rediscovering it.

**Read SPARQL-T-0040's Status before starting.** It carries the pins this
task is measured against, the fixture parameters, and whatever its own
run taught about the workload.

**Report shape**: one line per case, name + time + reads, stable enough
to diff between runs. Not a framework.

### Dependencies

Blocked by SPARQL-T-0033 — the engine must be correct before it is worth
timing — and by SPARQL-T-0040, whose pins are the thing being compared
against. Deliberately *before* SPARQL-T-0037 and -T-0038, so those two
have a measured baseline to move rather than a claim to assert.

### Risk Considerations

**The workload drifting during the rebuild is this task's specific
risk.** Every criterion above rests on the two runs asking the same
question; a fixture generated slightly differently, or a query quietly
adjusted to suit record, turns the comparison into two unrelated numbers
that happen to sit in one table. If something genuinely cannot be
reproduced, say so per case rather than adjusting the whole workload.

**Scope discipline.** This task exists to make three specific claims
checkable — the GRAPH regression, the "no result changes" of T-0037/38,
and the port's overall cost. It is not a performance-optimization task
and nothing it measures obliges a fix inside this initiative; a finding
becomes a backlog item.

## Status Updates

*To be added during implementation*
