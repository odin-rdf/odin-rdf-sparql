---
id: a-per-query-budget-the-engine
level: task
title: "A per-query budget the engine checks: a caller cannot bound a query that produces no solution"
short_code: "SPARQL-T-0053"
created_at: 2026-09-07T21:29:45.286795+00:00
updated_at: 2026-09-07T21:29:45.286795+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


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

## Acceptance Criteria **[REQUIRED]**

- [ ] A prepared query can be given a budget the executor itself checks --
      a row count, a wall clock, an operation count, or all three; which
      of them is the engine's to decide.
- [ ] Exhausting the budget ends the query in a way the caller can tell
      apart from exhaustion. `query_next` answering `false` for both would
      make a truncated answer indistinguishable from a complete one, which
      is the failure this exists to prevent.
- [ ] The check costs nothing measurable on a query that does not hit it
      -- the counting loops above run at 0.1-1.7 us a row, and a bound
      that showed up in that number would be paid by every consumer.
- [ ] A test over the shape above: a query that produces no solution for
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
