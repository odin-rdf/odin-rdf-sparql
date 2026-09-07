---
id: a-per-query-budget-the-engine
level: task
title: "A per-query budget the engine checks: a caller cannot bound a query that produces no solution"
short_code: "SPARQL-T-0053"
created_at: 2026-09-07T21:29:45.286795+00:00
updated_at: 2026-09-07T23:10:50.969193+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: NULL
---

# A per-query budget the engine checks: a caller cannot bound a query that produces no solution

## Objective **[REQUIRED]**

`query_next` runs until the next solution or until the input is exhausted,
and there is no way for the caller to interrupt it. That is fine for a
query that answers steadily, and it is exactly wrong for one that answers
nothing after a great deal of work: a consumer that wants "at most N rows
or at most T seconds" can enforce the first between pulls and cannot
enforce the second at all, because the whole cost may fall inside one
call.

`odin-rdf-app` runs caller-written SPARQL (a language model writes the
query; the consumer bounds what it costs). Its bounds are a row limit and
a wall-clock deadline checked at the pull loop. The row limit works. The
deadline works only for a query that yields rows.

**Measured, on a 26,711-quad store in 22 named graphs holding 436
instances of one class** (`-o:speed`, darwin/arm64, 2026-09-07). All ten
queries were run through the same loop: pull, materialize every projected
column with `query_term`, write it to `sparql/srj`.

| query | rows | wall clock |
|---|---|---|
| `?s ?p ?o` over every graph | 26,711 | 15.7 ms |
| one class joined to its labels | 436 | 0.3 ms |
| a four-way join over two graphs | 1,200 | 1.9 ms |
| `?a x ?b` over one class | 190,096 | 62.6 ms |
| `?a x ?b x ?c` over one class | >11 M | stopped at 5 s |
| **`?a x ?b x ?c` with a FILTER nothing satisfies** | **0** | **24.3 s** |

The last line is the case. It is one `query_next` call: it returns
`false` after 24.3 seconds, having produced nothing, so a loop checking a
deadline per row never gets a turn. Every honest query on that store
finishes inside 63 ms, so no bound a caller can express separates the two
-- the difference is not the answer's size, it is where the time is spent.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [ ] P0 - Critical (blocks users/revenue)
- [x] P1 - High (important for user experience)

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: a consumer that accepts a query it did not write needs a
  ceiling it can actually enforce. Without one, a single well-formed query
  occupies a worker thread for as long as the join takes, and the only
  remedy left to the consumer is to not offer SPARQL.
- **Effort Estimate**: S -- the work is a counter and a check in the
  execution loop, not a new operator.

## Reproduction

Any dataset with a few hundred instances of one class in named graphs.
The shape is what matters, not the vocabulary:

```sparql
PREFIX ex: <http://example.org/>
SELECT ?a ?b ?c WHERE {
  GRAPH ?g1 { ?a a ex:Thing }
  GRAPH ?g2 { ?b a ex:Thing }
  GRAPH ?g3 { ?c a ex:Thing ; rdfs:label ?l }
  FILTER(?l = "no such label")
}
```

`query_init` succeeds; the first `query_next` returns `(nil, false)` after
n^3 candidate solutions have been formed and discarded. With n = 436 that
is 24.3 seconds on the measurement above. Dropping the `FILTER` makes the
same query yield its first row immediately, which is what makes the
difference a *budget* question rather than a planning one.

## Acceptance Criteria

**[REQUIRED]**

- [x] A prepared query can be given a budget the executor itself checks --
      a row count, a wall clock, an operation count, or all three; which
      of them is the engine's to decide.
- [x] Exhausting the budget ends the query in a way the caller can tell
      apart from exhaustion. `query_next` answering `false` for both would
      make a truncated answer indistinguishable from a complete one, which
      is the failure this exists to prevent.
- [ ] The check costs nothing measurable on a query that does not hit it
      -- the counting loops above run at 0.1-1.7 us a row, and a bound
      that showed up in that number would be paid by every consumer.
- [x] A test over the shape above: a query that produces no solution for
      a long time stops at its budget and says so.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The natural place is wherever the executor already counts (there is a
`SPARQL_COUNT_READS` path), checked on the same cadence rather than per
candidate solution -- a clock read per join probe would be the expensive
answer to a cheap problem.

Cancellation from another thread would also solve the consumer's problem
and is a bigger question (the engine is single-threaded by construction);
a budget set at `query_init` needs no synchronisation at all, which is why
it is what this asks for.

### Dependencies
None.

## Status Updates **[REQUIRED]**

### 2026-09-07 -- filed
Filed from `odin-rdf-app` with the measurement above. The consumer's
deadline stays as it is in the meantime: it bounds a query that yields
rows slowly and is documented as not bounding one that yields none.

### 2026-09-08 -- built

`query_init` takes a `Budget`; the executor checks it; `query_stopped`
says whether it cut the answer. `make check` clean, `make test` green at
**306 tests** (sparql 207, srj 6, srx 7, guards 9, W3C harness 73, readme
4 -- 202 and 3 before), `make bench` passes with **every read-count pin
unmoved**, since every existing caller is unbudgeted and the counters are
untouched.

**The public delta is additive and nothing else moved.**

```odin
Budget      :: struct { ops: int, wall: time.Duration }   // zero = unbounded
Budget_Stop :: enum   { None, Operations, Wall_Clock }
BUDGET_CADENCE :: 4096

query_init(..., allocator := context.allocator, budget := Budget{}) -> bool
query_stopped(q: ^Query) -> Budget_Stop
```

`budget` is a defaulted parameter **after** `allocator` -- not where house
style would put it, because `query_init`'s trailing parameters are
positional to anyone who counts them (`SPARQL-T-0044` found four call
sites doing exactly that) and a consumer pinning this engine names the
allocator against that hazard. `query_next`'s arity is unchanged, so a
consumer that sets no budget compiles and behaves exactly as before.

#### The three decisions this had to take

**1. Which bounds -- and there is deliberately no row bound.** The item
left it open; the answer is an operation count and a wall clock, and not
rows. `ops` is deterministic: the same query over the same snapshot is
cut in the same place on any machine under any load, which is what makes
a refusal explicable to a user and a test repeatable in CI. `wall` is
what a consumer actually holds ("this request has 5 seconds left") and
the only bound that survives a machine slower than the one the number was
chosen on. A **row** bound was rejected rather than forgotten: the pull
loop is the caller's, `query_next` hands back one solution at a time, and
a caller counting them enforces a ceiling exactly, immediately and at no
cost inside the engine -- and it would not touch the case this exists
for, which produces no rows at all. Both bounds may be set; the first
reached wins, and `ops` is tested first.

**2. How the caller learns it was cut.** `query_next`'s arity could not
change, so the verdict is an accessor read after the loop:
`query_stopped(&q)`. It is an **enum, not a bool**, because a consumer
that must explain the refusal has two different things to say -- "this
cost more than the engine was allowed to spend" and "this took longer
than you had" -- and only the second is worth retrying. Rejected: a
public field on `Query` (consistent with `unsupported`, but every other
query property in this API is a verb -- `query_var_names`,
`query_snapshot`, `query_slots`), and a third return value on
`query_next` (breaks every caller, and pays per row for a
once-per-query answer).

**3. Where and how often the check happens.** Two sites, one counter,
one cadence:

  - `match_next` -- one tick per fact taken from a scan. This is the
    essential one: `bgp_next` steps its scans inside its own loop and
    returns to the driver only when it has a solution, so on the query
    this exists to stop it would otherwise tick almost never.
  - `table_next`, `stored_next`, `replay_next` -- the three sources that
    answer from memory the executor already holds. Without them a join
    over two materialized sub-plans, a `VALUES` block crossed with
    itself, or a huge `OFFSET` over a sorted sequence spins without ever
    reaching the store.

Between the four there is no loop in the engine that runs long without
ticking. The hot path is **one decrement and one branch**: `countdown` is
pre-charged with the chunk and only a chunk boundary reads the clock or
does arithmetic, and an **unbudgeted query pre-charges `max(int)`**, so
the branch is never taken and the check is never reached -- no flag, no
second compare. The consequence, stated in the doc comment: `ops` is
honoured to within `BUDGET_CADENCE` (exactly, below it), which makes it a
bound on the pathological case rather than accounting.

**`SPARQL_COUNT_READS` was not touched, extended or renamed.** The item's
"wherever the executor already counts" is a pointer to the seam and the
cadence, not to that counter: it is a compile-time branch that does not
exist in a normal build, it is process-wide rather than per-query, it
says in terms that it is not an API, and `SPARQL-T-0036` compares a port
against `SPARQL-T-0040`'s pinned integers. The budget has its own
counter, always present and on the `Exec`.

#### Measured

`-o:speed -no-bounds-check`, darwin/arm64, 2026-09-08. Two builds of one
harness against two source trees (`ce4900b` and this work), run
alternately; minimum of ten process runs of best-of-five. The fixture is
the item's shape at this scale: **27,280 quads in 22 named graphs, 440
instances of one class**.

**The case that filed this, and what a budget does to it:**

| | rows | wall clock | `query_stopped` |
|---|---|---|---|
| `?a x ?b x ?c` + a FILTER nothing satisfies, unbudgeted | 0 | **23.664 s** | `.None` |
| the same, `wall = 100 ms` | 0 | **100.279 ms** | `.Wall_Clock` |
| the same, `ops = 10,000,000` | 0 | **922.718 ms** | `.Operations` |

The 0.279 ms overrun is the cadence, and it is the whole promise: a
consumer's deadline is now enforceable on a query that never yields a
row.

**What the check costs a query that does not hit it** -- and this is the
one criterion **not** met outright, so it is stated rather than claimed:

| query | engine loop only | + `query_term` and `srj` per row |
|---|---|---|
| `?s ?p ?o` over every graph (27,280 rows) | 2.416 → 2.522 ms (+4.4%) | 4.289 → 4.319 ms (+0.7%) |
| one class joined to its labels (440) | 0.109 → 0.114 ms (+4.6%) | 0.125 → 0.132 ms (+5.6%) |
| `?a x ?b` over one class (193,600) | 13.068 → 13.709 ms (+4.9%) | 23.699 → 24.599 ms (+3.8%) |
| `?a x ?b x ?c`, capped at 1 M rows | 87.050 → 92.128 ms (+5.8%) | 171.861 → 177.064 ms (+3.0%) |

**3-5% of the engine's raw pull loop, 1-4% of the consumer's** -- about
3.4-4.0 ns per fact taken from the store. The item asked for "nothing
measurable" and this is measurable, so what was tried and rejected is on
the record:

  - **The driver loop.** The first version ticked at the top of `run`.
    It is the obvious place and it cost **6-9%**, because the driver
    turns several times per solution where a source turns once. Moved
    down; that is where the 6-9% became 3-5%.
  - **`source_next` as one site** instead of the three memory sources.
    Same coverage, and it puts a second tick on the BGP path that
    `match_next` already covers. Rejected on the same measurement.
  - **`#force_inline` on the tick, `intrinsics.expect` on the branch,
    an `armed` flag to skip the read-modify-write, moving `Budget_Run`
    to the head of `Exec`.** All four built and measured. None was
    better than the plain form beyond noise, so the plain form is what
    shipped -- the residue is the load/decrement/store dependency
    itself, not layout or inlining.
  - **Charging `range_len` at `match_open`** and not ticking per fact at
    all. It would be genuinely free on the hot path, and it is wrong: a
    window is an upper bound on a scan's cost, so an `EXISTS` probe that
    reads one fact from a wide window would be charged the whole window
    and an honest query would be refused for work it never did.
  - **Not ticking per fact.** The bound then becomes O(ops x store
    size) *inside one call*, because a single scan drained under a
    rejecting FILTER never returns to a ticking site. Fine at 27,000
    quads and not at 27,000,000.

A control build with the same signatures and the tick replaced by
`return true` measured at parity with `ce4900b` on every case, so the
threading of `^Exec` through `match_next` is free and the cost is the
check alone.

#### Tests

Five in `sparql/budget_test.odin`, over the item's shape scaled to
twenty-four instances in four graphs -- 13,824 candidate solutions, a few
milliseconds, and the package suite went from 105 ms to 116 ms:

  - **the item's case**: the three-way join with the FILTER answers
    nothing and reports `.None` unbudgeted, and answers nothing and
    reports `.Operations` under one cadence's budget. The pairing is the
    assertion -- a budget that stopped a query about to stop anyway
    would prove nothing.
  - **the same under a wall clock**, expressed as one nanosecond rather
    than a millisecond the machine might beat: the first check is one
    cadence in, by which time the deadline is certainly gone on any
    runner.
  - **a truncated answer is not a complete one**: the same join without
    the FILTER answers 13,824 rows and `.None`, and under a small budget
    answers *some* of them and `.Operations`.
  - **a budget nothing reaches is not a budget** (100 M operations, a
    minute): the whole answer, `.None`.
  - **the budget is one query's**, not the process's -- a cut query and
    then a fresh one over the same snapshot, which answers in full. This
    is the property `counting.odin` deliberately does not have.

Plus a fourth compiled README example in `tests/readme`, since the
README's promise is that its examples cannot drift.

#### Found along the way

**`SPARQL-T-0055`, filed: pulling an exhausted query again re-enters its
plan and yields solutions it has already given.** It surfaced because
the budget tests assert the opposite property -- a *cut* query stays cut,
since `exec_next` refuses before the walk -- and the unbudgeted control
run failed the same assertion. `bgp_next` resumes from `node.started` by
re-opening its deepest scan, and a run that has walked back to depth -1
has nothing recording that it is over. Reproduced identically at
`ce4900b`, so it predates this and this did not cause it; no consumer
meets it because every loop in the repository breaks on the first
`false`. Not fixed here -- the narrow fix is a `done` flag beside the
budget's `stop`, but whether `node_reset` may legally restart a finished
sub-plan is a correlated-re-run question that deserves its own item.

#### Not done

Not tagged: `v0.3.0` stays the release and whether an additive
`query_init` parameter warrants a bump is the owner's call. The
`BUDGET_CADENCE` of 4096 is a chosen constant, not a measured optimum --
it does not affect the per-tick cost, only how late a deadline is
noticed (well under 10 ms of work) and how far `ops` may overrun.