---
id: order-a-bgp-by-exact-candidate
level: task
title: "Order a BGP by exact candidate count: join_order consumes range_len"
short_code: "SPARQL-T-0037"
created_at: 2026-08-24T20:42:44.468811+00:00
updated_at: 2026-08-24T20:42:44.468811+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0036"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
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

- [ ] **`join_order` orders a BGP's patterns by ascending candidate
      count**, and is **stable**: patterns with equal counts keep their
      written order, so the query's text still decides what the data does
      not.
- [ ] **`SPARQL-T-0028`'s `ESTIMATE_UNKNOWN` criterion is retired, not
      implemented.** It required an explicit conservative rule for a
      store that could decline to estimate. **record does not decline**,
      so there is no unknown case, no `estimate_known` test, and no
      conservative fallback. Record the retirement in that backlog item
      rather than silently dropping a criterion.
- [ ] **The count is taken through the query's own snapshot**, not a
      fresh one. A query is one snapshot; a plan built against a different
      dataset than the one evaluated is a bug waiting for a concurrent
      writer.
- [ ] **`Plan_Builder` reaches the snapshot directly.** `SPARQL-T-0028`
      specified a `Cardinality_Estimator` procedure-pointer-plus-`rawptr`
      beside `find: Term_Finder`, on the grounds that "the core must go on
      naming no backend". **That constraint is retired by owner decision
      1**, so the builder holds the snapshot and calls `snapshot_match` +
      `range_len` directly, and `Term_Finder` itself should collapse the
      same way rather than being left as the last procedure pointer
      standing.
- [ ] **No evaluation result changes.** 512 of 512 across 37 directories,
      before and after. A changed answer means the reordering is not
      order-independent, which is a bug in the *evaluator*, not in the
      plan.
- [ ] **A test that the ordering happens**, not merely that it is
      permitted: a fixture where the written order is the bad one,
      asserting the built plan's permutation is the good one. Results
      alone cannot distinguish the two — by the criterion above they are
      identical — so without this the task is untestable.
- [ ] **A bench line showing the difference**, from SPARQL-T-0036's
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
