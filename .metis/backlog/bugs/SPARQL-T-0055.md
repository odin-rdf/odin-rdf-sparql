---
id: pulling-an-exhausted-query-again
level: task
title: "Pulling an exhausted query again re-enters its plan and yields solutions it has already given"
short_code: "SPARQL-T-0055"
created_at: 2026-09-07T23:09:18.213160+00:00
updated_at: 2026-09-07T23:09:18.213160+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#bug"


exit_criteria_met: false
initiative_id: NULL
---

# Pulling an exhausted query again re-enters its plan and yields solutions it has already given

## Objective **[REQUIRED]**

`query_next` answering `false` does not end a query. Pulling again after
it re-enters the plan and produces solutions the caller has already been
given, indefinitely -- so `for { row, more := query_next(&q); if !more
{ break } }` is the only loop shape that works, and any consumer that
pulls one more time to confirm the end gets a phantom row instead.

`bgp_next` is the mechanism. A run that has walked back to `depth == -1`
returns `false` with `node.started` still true and every iterator closed;
the next call takes the `else` branch, sets `node.depth = last`, finds
the deepest iterator closed and **re-opens it** against whatever the
working row still holds. Nothing in the operator records that the run is
over, because until now nothing needed it to: the driver's contract was
"pull until false", and no test pulled past that.

Found by `SPARQL-T-0053` while asserting the opposite property of a
budget -- a query the budget cut *does* stay cut, because `exec_next`
refuses before the walk. The two states should behave the same way and
today only one of them does.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Bug - Production issue that needs fixing

### Priority
- [ ] P0 - Critical (blocks users/revenue)
- [ ] P1 - High (important for user experience)
- [x] P2 - Medium (nice to have)

### Impact Assessment **[CONDITIONAL: Bug]**
- **Affected Users**: any consumer that pulls past the end. In practice
  none do -- every loop in this repository, in `bench/`, in the W3C
  harness and in the README breaks on the first `false` -- which is why
  it has gone unnoticed since the engine was written.
- **Reproduction Steps**:
  1. Prepare any query with a BGP over a store that answers it.
  2. Drain it until `query_next` returns `false`.
  3. Call `query_next` again. It returns `true`, with a solution.
- **Expected vs Actual**: an exhausted query should stay exhausted, the
  way a cut one does (`SPARQL-T-0053`). It instead resumes.

Measured 2026-09-08 on a four-instance two-graph fixture: a two-pattern
join drains 16 rows, then answers `true` on each of the next five pulls.
Reproduced identically at `ce4900b` and after `SPARQL-T-0053`, so it
predates the budget and the budget did not cause it.

## Acceptance Criteria **[REQUIRED]**

- [ ] A query that has answered `false` once answers `false` for ever,
      whatever its plan.
- [ ] The rule is stated in the README beside the pull loop, since
      "exhausted" is currently a property of the caller's discipline
      rather than of the query.
- [ ] A test that drains a query of each source kind -- BGP, path,
      `VALUES`, a materialized subquery, a blocking operator -- and pulls
      past the end.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The narrow fix is a `done` flag on the `Exec` set where `run` returns
`false` to `exec_next`, and read at the top of it -- the same shape the
budget's `stop` already has, and a place where the two could share one
check. The wider question, and the reason this is filed rather than
fixed: whether `node_reset` should be able to restart a sub-plan that
has finished, since that is what makes the resume legal for a
*correlated* re-run and illegal for a top-level one. The distinction is
between the driver's own re-entry and the caller's, and only the second
is wrong.

### Dependencies
None. `SPARQL-T-0053` is where it was found, not something it needs.
