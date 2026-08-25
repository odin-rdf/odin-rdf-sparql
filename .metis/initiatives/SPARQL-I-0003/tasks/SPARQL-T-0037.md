---
id: order-a-bgp-by-exact-candidate
level: task
title: "Order a BGP by exact candidate count: join_order consumes range_len"
short_code: "SPARQL-T-0037"
created_at: 2026-08-24T20:42:44.468811+00:00
updated_at: 2026-08-25T14:30:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0036"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: SPARQL-I-0003
---
# Order a BGP by exact candidate count: join_order consumes range_len

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Fill the seam this engine built and left empty. `join_order` in
`sparql/plan.odin:1954` decides the order a basic graph pattern's triple
patterns are probed in and returns the identity permutation — the order
the query wrote them. Its own comment says what it is waiting for:
"cost-based ordering waits for the store to be able to estimate
cardinality".

The wait is over, and the answer is better than the one that was asked
for. This task **supersedes `SPARQL-T-0028`**, which was written against
odin-rdf-store's `estimate`/`estimate_txn`; those procedures leave with
the store. record gives **`range_len(r)`: an exact candidate count in
O(1)** — arithmetic on a window, the binary searches already paid by
`snapshot_match` — and therefore an exact upper bound on visible matches.

## Acceptance Criteria

- [x] **`join_order` orders a BGP's patterns by ascending candidate
      count**, and is **stable**: patterns with equal counts keep their
      written order, so the query's text still decides what the data does
      not.
- [x] **`SPARQL-T-0028`'s `ESTIMATE_UNKNOWN` criterion is retired, not
      implemented.** It required an explicit conservative rule for a
      store that could decline to estimate. **record does not decline**,
      so there is no unknown case, no `estimate_known` test, and no
      conservative fallback. Record the retirement in that backlog item
      rather than silently dropping a criterion.
- [x] **The count is taken through the query's own snapshot**, not a
      fresh one. A query is one snapshot; a plan built against a different
      dataset than the one evaluated is a bug waiting for a concurrent
      writer.
- [x] **`Plan_Builder` reaches the snapshot directly.** `SPARQL-T-0028`
      specified a `Cardinality_Estimator` procedure-pointer-plus-`rawptr`
      beside `find: Term_Finder`, on the grounds that "the core must go on
      naming no backend". **That constraint is retired by owner decision
      1**, so the builder holds the snapshot and calls `snapshot_match` +
      `range_len` directly, and `Term_Finder` itself should collapse the
      same way rather than being left as the last procedure pointer
      standing.
- [x] **No evaluation result changes.** 512 of 512 across 37 directories,
      before and after. A changed answer means the reordering is not
      order-independent, which is a bug in the *evaluator*, not in the
      plan.
- [x] **A test that the ordering happens**, not merely that it is
      permitted: a fixture where the written order is the bad one,
      asserting the built plan's permutation is the good one. Results
      alone cannot distinguish the two — by the criterion above they are
      identical — so without this the task is untestable.
- [x] **A bench line showing the difference**, from SPARQL-T-0036's
      harness. This is the first change in the initiative that is supposed
      to make something *faster*, and it is the one place where a number
      is the deliverable rather than a reassurance.

## Implementation Notes

### Technical Approach

**A candidate count is not a match count**, and the difference should be
understood before it is relied on: `range_len` counts every fact
*generation* in the window, including versions retracted before the
snapshot's epoch. record's own note is that the gap is small for a head
snapshot. For join ordering that is fine — it is an exact upper bound,
and an upper bound is what a planner prices with — but it means a heavily
edited store could order slightly conservatively. Worth a comment, not a
correction.

**Counting costs a `snapshot_match` per pattern at plan time**, which is
two binary searches per bound prefix. That is cheap, but it is not free
and it happens once per query rather than once per row; for a BGP of two
patterns over a tiny dataset the ordering may cost more than it saves.
Do not add a heuristic threshold on a guess — measure it in
SPARQL-T-0036's harness and only then decide whether one is warranted.

**`ground_ref` already resolves each pattern's ground terms**, and a
pattern with a term the store has never seen matches nothing. That is a
zero count, which sorts first, which is correct and free: the cheapest
pattern to probe is the one that cannot match.

### Dependencies

Blocked by SPARQL-T-0036 — a baseline must exist before this task can
claim to have improved on it.

### Risk Considerations

**The stability requirement is not cosmetic.** An unstable sort makes the
plan depend on the sort implementation, which makes a failing test
irreproducible. Use a stable sort or sort on `(count, written_index)`.

**"No result changes" is a real risk, not a formality.** If any operator
in this engine depends on BGP probe order for its *answer* rather than
its speed, this task will surface it as a corpus failure — and the
correct response is to fix the operator, not to weaken the ordering.
`sparql10-bnode-coreference` and the `OPTIONAL` directories are where
that would show.

## Status Updates

*To be added during implementation*

### 2026-08-25 — ordered, and the specification had to be strengthened to be right

`join_order` (`sparql/plan.odin`) prices every pattern of a BGP with
`record.range_len(record.snapshot_match(...))` against the builder's own
snapshot and orders them **connected-first, then cheapest, then as
written**. Four tests in `sparql/join_order_test.odin`, `make bench` green
with a new pinned case, 537/537 unchanged.

### The criterion as written produces worse plans, and the benchmark's own `bgp3` is the example

The task asked for "ascending candidate count, stable". **Implemented
literally that is a hazard, not a planner**, and it is worth stating why
before anything else here.

This executor is a nested loop: `probe_pattern` substitutes the row's
bindings into the pattern at depth *d* and probes once per surviving row
from depth *d-1*. A pattern that shares no variable with anything bound
substitutes **nothing**, so every one of those probes is the *same full
scan* and the join degenerates into a cross product that a later pattern
then filters.

`bgp3` — `?s a b:Entity` (20,000 candidates) `. ?s b:knows ?o` (80,000)
`. ?o b:name ?name` (20,000) — makes the point exactly. Ascending cost is
0, 2, 1: pair every entity with every name, **4x10^8 intermediate rows**,
then let `b:knows` filter them down to 80,000. Written order is 0, 1, 2,
which is optimal. A cost-only planner would have made the benchmark's
headline join four thousand times worse.

So the rule is two-level and the first level is not negotiable:
connectivity, then cost, then written index. `test_join_order_prefers_
connected_over_cheap` is the regression guard, and it fails on a
cost-only implementation.

### Everything in the benchmark was already optimally ordered

The measurement that mattered most was the one that found nothing.
**All sixteen existing rows are unchanged — every `match`, every `next`,
every `candidate`** — because every query in the mix was already written
in the order a planner would choose. That includes `bgp3`, whose own
comment claims it is "written deliberately worst-first ... so that a
planner which reorders has something to gain". It is not: as shown above,
0, 1, 2 is the best available plan and 2, 1, 0 merely ties it. The
comment was wrong when it was written and no one had a planner to notice.

**So "a bench line showing the difference" could not be met by the
existing workload**, and the honest response was to add a case rather
than to weaken the ordering until an existing line moved.
`bgp3-selective-last` is `?s a b:Entity . ?s b:name ?name . ?s b:dept
b:d0` — filter a population by a low-cardinality attribute, having
written the filter last, which is what a person does when they think of
the filter last. Both before and after were measured on the same binary
pair, the before by temporarily restoring the identity ordering:

| `bgp3-selective-last`, large | as written | ordered | |
|---|---|---|---|
| match | 40,001 | **3,221** | 12.4x fewer |
| next | 81,611 | **8,051** | 10.1x fewer |
| candidates | 42,110 | **4,879** | 8.6x fewer |
| best ms | 4.896 | **0.495** | **9.9x faster** |
| solutions | 1,610 | 1,610 | |

`small` moves the same way: 4,001 -> 361 match, 0.397 -> 0.046 ms. This is
the first change in the initiative that is supposed to make something
faster, and it is a real number rather than a reassurance.

### No threshold, and it is measured rather than assumed

The task warned that for a small BGP over a small dataset the pricing
could cost more than it saves, and told this task not to add a heuristic
on a guess. Measured: **unmeasurable.** The plan-time cost does not show
in any timing, including `bgp2` and `group`, the two-pattern cases where
it was most likely to. Single-pattern BGPs return before pricing anything,
so the commonest shape in the corpus pays literally nothing. Ordering is
on unconditionally and there is no threshold to tune.

### Two things the criteria assumed were still to do, and were not

- **`Plan_Builder` already reached the snapshot directly**, and
  `Term_Finder` had already collapsed — both at `SPARQL-T-0031`, when the
  parapoly seam went. Nothing to retire here; `plan.odin`'s header still
  described the resolver as "a procedure pointer ... a deliberate
  exception to the no-dynamic-dispatch rule", which had been false for
  four tasks, and now says so under a dated note.
- **`SPARQL-T-0028` is closed**, not silently dropped, with its three
  retired criteria and the reason for each: `ESTIMATE_UNKNOWN` is void
  because record does not decline; the `Cardinality_Estimator` procedure
  pointer is void by owner decision 1; and the "measure before defaulting
  it on" criterion was taken and answered. Its warning about answer-
  preservation was the right thing to worry about and the corpus held.

### The counter learned about a new caller

`join_order` reads the store, and `counting.odin` promises `store_ops`
counts every round trip **wherever it is made**, so plan-time pricing
ticks it: `bgp2` 8,005 -> 8,007, `bgp3` 38,006 -> 38,009, `group` 12,040
-> 12,042, and the single-pattern cases unmoved. Deliberately **not** a
`match` — that verb means a scan opened at one depth, and inflating it
would break the comparison `SPARQL-T-0036` pinned — and not a
`candidate`, since nothing is scanned and the window priced is the static
one rather than a probe's. `store_ops` is unpinned for exactly this kind
of movement.

### Answer-preservation

`make test`: 284 tests, **537/537 across 38 directories**, unchanged
before and after. `sparql10-bnode-coreference` and the OPTIONAL
directories — named in the task as where an order-dependence would show —
are green. No operator in this engine depends on BGP probe order for its
answer.

### For SPARQL-T-0038

`order-limit` is untouched by this task and still identical to `order`:
20,500 candidates, 20,001 `next`, 7.017 ms against 7.167, sorting all
20,000 solutions to return ten.
