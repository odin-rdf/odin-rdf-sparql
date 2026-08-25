---
id: top-n-without-the-store-a-bounded
level: task
title: "Top-N without the store: ORDER BY ... LIMIT n on a bounded heap"
short_code: "SPARQL-T-0041"
created_at: 2026-08-25T17:15:00.000000+00:00
updated_at: 2026-08-25T17:15:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#feature"
  - "#phase/backlog"


exit_criteria_met: false
initiative_id: NULL
---

# Top-N without the store: ORDER BY ... LIMIT n on a bounded heap

## Objective **[REQUIRED]**

`ORDER BY ?x LIMIT 10` materializes every solution, sorts all of them, and
throws away all but ten. **It should keep ten.**

`Plan_Order` (`sparql/plan.odin:429`) collects every row into
`node.rows` with a `Sort_Key` beside each, then `order_finish`
(`sparql/exec.odin:1415`) sorts the lot. `Plan_Slice` is a separate
operator above it, exactly as §18.2.5 layers them, and it never tells the
sort that only ten rows will survive.

**This is not blocked, and the belief that it was is why it has no item
until now.** Three places in this repository say a top-N query waits for
an ordered store iterator:

- `sparql/plan.odin:436` — "the evidence log records that an ordered store
  iterator would let a top-N query stream (SPARQL-T-0019)"
- `SPARQL-T-0038`'s third criterion — "`ORDER BY … LIMIT n` stops after n
  **when the input is ordered**"
- `SPARQL-T-0029`, which carried the same criterion before it

All three are true of one implementation and false of the requirement. An
ordered store read would let the query stop *reading* after n, which is
strictly better and is genuinely blocked (`SPARQL-T-0038`: record's id
order is not SPARQL's and no plan can tell when they agree). **A bounded
heap needs none of that**: keep the n best solutions seen so far by
SPARQL's own comparator and discard the rest as they arrive. It asks the
store for nothing, and it uses `value_order` — which already exists, is
already correct, and is already what the full sort calls.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium

Higher than everything `SPARQL-T-0038` closed and higher than
`SPARQL-T-0029`, because it is unblocked, self-contained, and the only one
of the three with a memory argument rather than only a time one.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `ORDER BY … LIMIT 10` stops costing what `ORDER BY` costs.
- **Business Value**: The deployment shape is ~200 processes per machine, each embedding a store, so **peak memory per query is a first-order concern** and this is the one operator whose peak is proportional to the answer set rather than to the answer.
- **Effort Estimate**: S–M. One operator, no plan-shape change beyond letting `Plan_Order` see the slice above it, and no store involvement at all.

## Acceptance Criteria **[REQUIRED]**

- [ ] **`ORDER BY` under a `LIMIT` (with or without `OFFSET`) retains at
      most `offset + limit` solutions**, not all of them. Everything else
      is discarded as it arrives.
- [ ] **The comparator is unchanged.** `value_order` decides, exactly as
      the full sort does today — this is a change to *how many rows are
      kept*, not to how two rows compare. Anything else would be a
      correctness change wearing a performance change's clothes.
- [ ] **The bound comes from the plan, not from a guess.** `Plan_Slice`
      sits above `Plan_Order` in the algebra (§18.2.5) and the two must
      stay separate operators; what is needed is for the builder to hand
      `Plan_Order` the bound when a slice is directly above it. **An
      `OFFSET` with no `LIMIT` is unbounded and must keep the full sort.**
- [ ] **No result changes**, and this is the whole risk. 537/537 across 38
      directories. `sparql10-sort` (14 entries) is the directory that would
      notice, and `sparql11-*` entries combining `ORDER BY` with `LIMIT`
      and `OFFSET` are the shapes to look at by hand.
- [ ] **Ties are preserved as they are today.** SPARQL's `ORDER BY` is a
      partial order over solutions — rows equal on every condition may come
      back in any order, and both the current sort and a heap are free
      there — but the *set* of rows returned must be one a full sort could
      have produced. A heap that evicts on `<=` rather than `<` can return
      a different tied row than the sort does; that is legal and should be
      a stated decision rather than an accident.
- [ ] **Bench numbers.** `order-limit` is pinned and is this task's
      before-and-after in one line. Its `about` string —
      "sorts everything today" — comes true or the task did not land.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### What it is worth, from the pinned bench

`large`, 20,000 solutions, returning ten:

| case | best ms | |
|---|---|---|
| `bgp2` | 3.167 | the same pattern, unsorted |
| `order` | 7.167 | full sort |
| `order-limit` | **7.017** | **full sort, then discard 19,990** |

So roughly **4 ms of the 7 is materialize-and-sort to return ten rows**,
and a heap of ten should recover most of it. `order-limit` and `order`
being within noise of each other is the current state stated as a
measurement (`SPARQL-T-0040`, unchanged through the port).

**The memory argument is the stronger one and the bench does not show it.**
`Plan_Order` holds a row *and* a `Sort_Key` per solution, and a `Sort_Key`
carries a **copied term** — deliberately, because a backend may hand back a
term that lives only until the next materialization. So a top-ten query
over a million solutions materializes a million copied terms today. Under a
heap it materializes ten. Nothing in `bench/` measures peak memory; if this
task wants to prove that half, it needs an allocation guard in
`tests/guards`, which is where this repository's memory claims live.

### Where it goes

`order_collect` / `order_finish` in `sparql/exec.odin`, plus a bound on
`Plan_Order` filled by the builder. The natural shape is a bounded max-heap
keyed by the same comparator: push while under the bound, then compare
against the root and evict. At the end, sort what is left — at most
`offset + limit` rows, so the final sort is trivial.

**Do not fold `Plan_Slice` into `Plan_Order`.** They are separate in
§18.2.5 and the SSE printer prints them separately; the plan builder
passing a bound down is a hint, not a merge.

### Deliberately out of scope

**Streaming the sort itself.** That is the genuinely blocked case — an
input already in the sort key's order would make `Plan_Order` a
pass-through, and it needs record's id order to agree with SPARQL's, which
`SPARQL-T-0038` proved it does not and no plan can establish. Nothing here
touches that, and this task must not be read as reopening it.

**`DISTINCT` under a `LIMIT`.** Same family, different operator, and the
dedup set is bounded by distinct rows rather than by the limit. Its own
item if anyone wants it.

### Risk Considerations

**The tie question is the only place this can be wrong**, and it is subtle
enough to state twice: a full sort and a bounded heap can return different
*members* of a tie group, and both are legal. The corpus is the guard, and
`sparql10-sort` is where a mistake would show — but a passing corpus does
not prove tie-handling is stable, only that it matched today. Write the
eviction rule down.

**It is an optimization in an engine nobody has complained about.** The
argument for doing it is the memory profile against ~200 processes per
machine, not the 4 ms.

## Status Updates **[REQUIRED]**

- **2026-08-25 — Filed after the owner asked what performance
  `SPARQL-T-0029` leaves on the table**, which surfaced that the largest
  item was not in `SPARQL-T-0029` at all and was not filed anywhere.

  Answering that question properly meant separating "features that cannot
  be offered" from "optimizations that are blocked". **No SPARQL feature is
  unavailable** — `ORDER BY`, `MIN`/`MAX` and `LIMIT` are all correct at
  537/537. Of the optimizations, `SPARQL-T-0038` blocks a streaming
  `ORDER BY` (narrow — a full sort was never avoidable in general) and a
  one-read `MIN`/`MAX` (modest — `agg_keep_extreme` is already one pass
  with O(1) memory). Top-N looked like the third blocked thing and is not
  blocked at all.

  The misreading is instructive and is the reason three documents carried
  it: an ordered store read *would* serve top-N, so "top-N wants an ordered
  read" is true; it does not follow that top-N *needs* one. `SPARQL-T-0019`
  filed it in the store-evidence log under ordered iteration in 2026-08-05
  and it stayed there through the store's retirement, `SPARQL-T-0029`,
  `SPARQL-T-0038`, and this initiative's close.
