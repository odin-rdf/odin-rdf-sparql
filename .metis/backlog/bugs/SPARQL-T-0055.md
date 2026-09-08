---
id: pulling-an-exhausted-query-again
level: task
title: "Pulling an exhausted query again re-enters its plan and yields solutions it has already given"
short_code: "SPARQL-T-0055"
created_at: 2026-09-07T23:09:18.213160+00:00
updated_at: 2026-09-07T23:51:36.424743+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/completed"


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

## Acceptance Criteria

**[REQUIRED]**

- [x] A query that has answered `false` once answers `false` for ever,
      whatever its plan.
- [x] The rule is stated in the README beside the pull loop, since
      "exhausted" is currently a property of the caller's discipline
      rather than of the query.
- [x] A test that drains a query of each source kind -- BGP, path,
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

## Status Updates **[REQUIRED]**

### 2026-09-08 -- filed
Filed from `SPARQL-T-0053`, whose tests assert the opposite property of a
budget and whose unbudgeted control failed. The question was left open
deliberately: the narrow fix was obvious and the seam was not.

### 2026-09-08 -- the design question, answered

**The exhausted state goes on the node, beside `started`, and
`node_reset` clears it.** Not a `done` flag on the `Exec`, which is what
the implementation note above offered.

The question the item filed was whether `node_reset` may restart a
sub-plan that has finished. **It may, and that is exactly what makes it
the right seam.** What separates the driver's legitimate re-entry from
the caller's illegitimate one is already in the code and needs no second
spelling: every correlated re-run in this engine resets its child before
re-running it, and a caller cannot call `node_reset` at all. Making
"finished" a state that `node_reset` clears therefore places the
distinction where it already exists, and a node-level flag is invisible
to every internal operator while refusing the one re-entry that is
wrong.

**The `Exec`-level flag was rejected because it fixes the symptom at the
driver's boundary only.** The first acceptance criterion says "answers
`false` for ever, *whatever its plan*", and the third asks for five
source kinds; a node-level answer makes both true by construction, while
an `Exec` flag makes them true for the top-level pull and leaves the same
two-state machine underneath every operator. It also happens to fix more
than the filed case -- see *What else it fixed* below -- which the narrow
version would not have.

The audit the design rests on was run rather than assumed. Every site
that re-runs a child resets it first: `join_step` and `left_join_step`
both call `node_reset(e, node.right)` before pulling the right side
(`exec.odin:1622`, `:1662` at the time of filing), `Union`'s `consume`
resets both branches before starting the right, `exec_exists` resets its
sub-plan before and after, and `exec_path_expand` resets the step before
and after. The other continuation targets in `consume` -- `Distinct`,
`Slice`'s OFFSET skip, `Filter`, `Minus`, `Graph_Bind`, `Materialized`,
`Group` and `Order` re-pulling `node.input`, and a `Left_Join` re-pulling
its left after the right ran out -- all re-pull a child that has just
produced a row and has never answered a terminal `false`. `run` is
called from four places and no other (`exec.odin`, and it is
`@(private = "file")`): the root, `collect_all` (once per node), and the
two reset-guarded ones above. **No operator was found that re-pulls a
child after a terminal `false` without resetting it**, so nothing in the
engine was relying on the resume behaviour.

### 2026-09-08 -- fixed

**Three states where there were two, and the third is `Exec_Node.exhausted`.**
`!started` is fresh, `started` is running, `exhausted` is finished. The
state is set by the driver in `run` and cleared by `node_reset` in the
same loop over the subtree that clears `started`, so no operator's own
procedure mentions it.

*The reproduction, before and after.* `sparql/exhausted_test.odin` builds
the item's fixture -- four instances of one class over two graphs -- and
drains `GRAPH ?g1 { ?a a ex:Thing } GRAPH ?g2 { ?b a ex:Thing }`. Before:
sixteen solutions, then `true` on each of the next five pulls, which is
the measurement in the report to the row. A query with no answer at all
(`?a a ex:Thing ; ex:next ex:a`) was worse -- it drained zero solutions
and then produced one on four of the next five pulls. After: sixteen and
zero solutions respectively, `false` on all five extra pulls in both, and
`query_stopped` `.None` throughout.

#### Continuation `false` and terminal `false`

**In this engine `false` does not mean exhausted**, and getting that
wrong would have looked like missing rows rather than like this bug.
`consume` returns `(row, ok, want)`, and `want >= 0` is a *continuation*
-- "I have nothing yet, pull that child next" -- which is precisely how a
correlated join hands control to its right side on its first left
solution. Marking every `false` would have retired such a join the
instant it started running.

So the state is set in exactly two places in `run`, both of them the end
of a walk:

  - after `source_next` returns `!ok`. A source has one kind of `false`
    and it is terminal: it produces or it is spent.
  - after `consume` returns `!ok` **and** `want < 0`. That is an operator
    saying it is done, as distinct from the `want >= 0` branch above it,
    which continues.

It is read in one place, at the head of `run`'s pulling branch and ahead
of `start_child`, so a finished node is neither descended into nor asked
to produce. At the root that read is what makes an exhausted *query* stay
exhausted, which is the caller-visible half.

#### What else it fixed

The read sits below every operator, so it also refuses a re-entry the
filed reproduction never reached: a `Slice` at its `LIMIT` re-entering
its input, and a correlated `Left_Join` re-pulling a left side that had
already answered `false`. Both went through the same resume before.

#### The budget's `stop` and this state are not the same check

They are the same *kind* of thing and they were kept apart, deliberately.
`exec_next` still refuses on `e.budget.stop != .None` before the walk and
again after it, and neither could be replaced by the node state: a run
cut *after* it produced a row leaves the root unfinished, so a second
call would reach `collect_all` and the store, which is the one thing "a
cut query stays cut" promises it will not do. The two are consistent
rather than merged -- a budget cut makes every source answer `false`, so
the nodes it stopped are marked exhausted as well -- and the relationship
is stated in `exec_next`'s doc comment rather than encoded twice.

What did merge is the *assertion*. `budget_test.odin`'s `budget_run`
pulled past the end only for a cut query, with a comment explaining that
an exhausted one could not be asserted the same way; it now pulls past
the end on **every** run, cut or not, and `query_stopped` goes on being
the whole difference between them.

#### The tests

`sparql/exhausted_test.odin`, six cases over the item's fixture. Each
names the `Exec_Kind` it is about and **fails if the plan does not hold
one**, so a planner change cannot quietly turn a case into a duplicate of
the first; each then drains, asserts the solution count, and pulls five
times past the end asserting `false` and `.None` each time.

  - `..._basic_graph_pattern_...` -- `.BGP`, 16 solutions. The filed
    reproduction.
  - `..._path_...` -- `.Path`, 6. `path_next` walks a frontier rather
    than a chain of iterators, so its end is a different procedure's.
  - `..._inline_table_...` -- `.Table`, 3. Answers from memory and never
    reaches `match_next`.
  - `..._materialized_subquery_...` -- `.Materialized`, 16. Collected
    once and replayed per left solution, which is the re-run that must go
    on working -- the case that fails if the state is not cleared by
    `node_reset`.
  - `..._blocking_operator_...` -- `.Order`, 4. Input-driven until its
    input runs out and a source afterwards, so it has two ends and only
    the second is the query's.
  - `..._a_query_with_no_answer_...` -- `.BGP`, 0. Where "it answered
    `false` once" and "it never answered" coincide, and the case that was
    producing phantom solutions out of an empty answer.

Five pulls rather than one because a resuming BGP produces a fresh
solution on every extra pull -- one would catch that -- while five also
catches an operator that resumes once and then settles.

#### The rule, written down

`README.md` gains a paragraph beside the pull loop, immediately after
*There is no error to check after a run*: an exhausted query stays
exhausted whatever the plan, it is a property of the query rather than of
the caller's discipline, and `query_stopped` still separates exhaustion
from truncation. `bgp_next`, `exec_next`, `Exec_Node.exhausted` and
`merge_begin` carry the same rule at contract level.

#### Measurements

`make check` clean. `make test` green at **316 tests** (sparql 217 from
211, srj 6, srx 7, guards 9, W3C harness 73, readme 4). `make bench` all
assertions passed with **every read-count pin unmoved** -- the cost is
one bool load and one predictable branch per node visit on the descend,
and it moves no store read.