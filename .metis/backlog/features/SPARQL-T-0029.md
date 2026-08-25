---
id: consume-ordered-iteration-for-min
level: task
title: "Consume ordered reads for joins: a merge join over two named permutations"
short_code: "SPARQL-T-0029"
created_at: 2026-08-09T13:15:00.000000+00:00
updated_at: 2026-08-25T16:10:00.000000+00:00
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

# Consume ordered reads for joins: a merge join over two named permutations

## Objective **[REQUIRED]**

**Rewritten 2026-08-25.** This item was filed against odin-rdf-store's
`match_order`/`match_orderable`/`match_ordered` and asked for four things.
Three of them are dead: `MIN`/`MAX` in one read, a streaming `ORDER BY`,
and an `ORDER BY … LIMIT n` that stops all need odin-rdf-record's id order
to agree with SPARQL's, and `SPARQL-T-0038` proved it does not and that no
plan can tell when it might. That half is closed and stays closed — see
the 2026-08-25 Status entries below, both of them.

**The fourth thing is alive, and closing this item on the third was a
mistake.** The original parked merge joins under "Deliberately out of
scope", and they are *not blocked by the id-order finding*: a merge join
needs both inputs sorted on the join variable **by the same order**, and
any consistent total order will do. The ids never have to mean anything.
That is the whole difference between this task and `SPARQL-T-0038`, and it
is worth stating once at the top because the two were conflated for most
of a day.

**It is buildable today and needs nothing from record.**
`snapshot_match_as(snap, p, order)` returns `Range.main = ids[lo:hi]` — a
slice of a stored permutation — so the facts in a window are sorted by
that order's full key. Read `?s :p ?x` as `.PSOG` and `?x :q ?y` as
`.PSOG`, and both windows ascend in the variable they share.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium

**Demoted from P1**, deliberately. The P1 came from four operators
independently wanting the surface; three of those four are gone. What
remains is one optimization with a plausible but *unmeasured* payoff, in
an engine that is correct and fast enough that no consumer has complained.
It should be picked up when there is a reason, not on principle.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A two-pattern join stops opening one index scan per row.
- **Business Value**: The deployment shape is ~200 processes per machine and CPU frugality is a first-order requirement, so collapsing a per-row store call to a single sequential merge is the right *kind* of saving. Whether it is a large one here is unknown — see below.
- **Effort Estimate**: M–L, and larger than the original's "M". The blocker is not the read: it is that this executor has no operator shape to put a merge join in.

## Acceptance Criteria **[REQUIRED]**

- [ ] **Two patterns of one BGP that share a variable, both readable with
      that variable leading, are joined by a merge** rather than by
      probing the second once per row of the first.
- [ ] **The choice is made at plan time and priced**, not taken whenever
      it is possible. `SPARQL-T-0037` put `range_len` in the plan builder
      for exactly this kind of decision, and a merge reads *both* windows
      in full where a nested loop reads a narrow probe per row — so a very
      selective left side should still probe. **This is the same trade the
      original item got right about odin-rdf-store and for a different
      reason**: there, asking for an order could widen the scan; here, the
      scan width is the same either way and what changes is whether the
      right side is read once or per row.
- [ ] **Fallback is the current nested loop**, unchanged, wherever the
      shape does not allow a merge — which is most shapes. See below.
- [ ] **No result changes.** 537/537 across 38 directories, before and
      after. A BGP's solutions are a set; join *strategy* may change what
      is efficient and must not change what is found.
- [ ] **A test that the merge path is taken**, not merely available.
      Results cannot distinguish the two by the criterion above, so this
      is the only way the task is testable — the same argument that gave
      `SPARQL-T-0037` its `plan_order` tests, and they are the pattern to
      copy.
- [ ] **Bench numbers, from the pinned cases that already exist.** This is
      a change whose entire purpose is cost, so a number is the
      deliverable. `bgp2` and `bgp3` are pinned and are the two cases that
      would move.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### What it would actually buy, arithmetically

Predictions to be measured, **not claims** — and deliberately worked out
here because the first estimate this session produced was wrong by four
orders of magnitude.

**`bgp2` is the case that would move**: `?s a b:Entity . ?s b:name ?name`,
both patterns leadable by S, joined on ?s. Today it opens **20,001 scans**
for 20,000 solutions — one per row of the left side. A merge opens **two**.
`next` should roughly halve (60,001 today; a merge reads each window once,
so ~40,000), and **`candidates` should barely move at all**, because both
windows are read in full either way. That the three verbs move by wildly
different factors is the point of having three.

**`bgp3` would move much less than it first appears.** `?s a b:Entity .
?s b:knows ?o . ?o b:name ?name` — the first two share ?s and can merge,
but the third joins on ?o, and **a merge join's output is sorted by its
join variable**, so the ?o join cannot merge without a re-sort. Expect
~80,002 scans against 100,001 today: **a fifth off, not the collapse a
casual reading suggests.** Left-deep merge chains only stay merges while
consecutive joins share the same variable.

That asymmetry is the honest summary of this task: it is a large win on
the simplest join shape and a modest one on the next-simplest.

### Where it does not apply, which is most places

- Either pattern not leadable by the shared variable in any of the six
  orders. `choose_order` is free to be overridden by `snapshot_match_as`,
  so this is rarer than it was on odin-rdf-store — **any order answers any
  pattern**, only the window width differs — but a wider window may cost
  more than the merge saves, which is what the pricing criterion is for.
- More than one shared variable, or a shared variable that is not a single
  position.
- Anything past the first join in a chain that changes join variable.
- `GRAPH ?g { … }`, where the graph is an unbound slot — though note this
  is *not* the blanket exclusion the original item described, because G is
  never a leading component here anyway (`RECORD-A-0004`); it is residual,
  and the triple positions order normally. The one place record's
  G-residual design makes something *easier*.

### The real cost: there is nowhere to put it

`sparql/exec.odin` evaluates a BGP as a depth-indexed nested loop —
`probe_pattern` substitutes the row's bindings at depth *d* and opens a
scan per surviving row from *d-1*, with `Plan_BGP.order` deciding only the
sequence. A merge join is a different operator shape: two cursors advanced
in step, neither driven by the other. It does not fit inside the depth
loop and would be a plan node beside it, which is why the estimate is M–L
rather than the original's M.

### Same family, still parked, and now with an argument

The original parked **streaming DISTINCT** beside merge joins. It survives
the same way and for the same reason — deduplication over a stream
clustered by the row's key is a comparison with the previous row instead
of a retained key per distinct row, and *clustering needs a total order,
not SPARQL's order*. **Streaming GROUP BY** belongs with it and was never
listed: aggregation over an input clustered by the group key needs no
group table.

Both stay parked, and the reason is now evidence rather than instinct:
**nothing measures them.** The corpus has no high-cardinality `GROUP BY`,
and `bench/`'s `group` case has twelve groups — its 40,012 `load` is
`bindable_id` resolving aggregate results, not the group table, so
streaming the aggregation would save approximately nothing there. Worth
their own item when a workload asks; not worth carrying inside this one.

### Dependencies

**None.** `snapshot_match_as` is in odin-rdf-record `v0.4.0`, which is
already the pin. This item's old dependency list — odin-rdf-store v0.6.0,
and `SPARQL-T-0028` for the estimator — is void: the store is gone, and
`SPARQL-T-0028` was superseded by `SPARQL-T-0037`, which already put the
costing input (`range_len`) in the plan builder.

Note that record's `Range.Vars(depth)` / `VarIter` — the sorted-distinct-
values-with-`Seek` view `api.md` §12.3 sketches for leapfrog triejoin — is
**designed but not built**. Nothing here needs it; a leapfrog join would,
and that is a further item again.

### Risk Considerations

**"No result changes" is the real one.** A BGP's solutions are a set and
join strategy must not change them. `SPARQL-T-0037` ran the same risk when
it reordered patterns and the corpus held, which is some evidence the
evaluator has no order-dependence — but reordering probes and replacing
the join algorithm are different exposures, and `sparql10-bnode-coreference`
and the OPTIONAL directories are still where a failure would show.

**Do not build it because it is buildable.** The engine is green and no
consumer has asked. `bgp2`'s 20,001-scans-for-two is a good number to point
at, but it is a synthetic case in a benchmark this repository wrote for
itself. A real consumer's query shape is better evidence than this
paragraph.

## Status Updates **[REQUIRED]**

- **2026-08-09 — Filed from odin-rdf-store while STORE-T-0015 was being
  built**, alongside SPARQL-T-0028 for the estimator half. Blocked on the
  store's v0.6.0, which SPARQL-T-0026 also waits for.

- **2026-08-25 — Superseded by `SPARQL-T-0038`, and then closed with it as
  evidence** (SPARQL-I-0003, owner decision). This item was written against
  odin-rdf-store's `match_order`/`match_orderable`/`match_ordered`, which left
  with the store. `SPARQL-T-0038` re-specified it against odin-rdf-record's
  stronger shape — `snapshot_match_as` lets the planner name the permutation
  outright, and any order answers any pattern — and then found that **the
  shape of the read was never the blocker**.

  **The blocker is the id space, and it is absolute.** record's ids are
  ordered but not in SPARQL's order: every dictionary id sorts before every
  inlined one, and only canonical in-range integers, booleans and dates inline
  at all. An integer past 2^27, any decimal or float or double, and any
  non-canonical lexical form are each dictionary terms — so by id the five
  values 1, 3, 200000000, 2.5 and "007" come back as 200000000, 2.5, 007, 1,
  3 where `ORDER BY` requires 1, 2.5, 3, 007, 200000000. Each mechanism is
  fatal alone and each is ordinary data.

  What disqualifies a value is a property of that value, and SPARQL has no
  static types, so no plan can rule them out from a pattern and a sort key.
  This item's own premise — that the order is "a function of the pattern and
  is knowable at plan time" — is true of the *permutation* and false of the
  *ordering semantics*, and it is the second that this optimization needed.

  Applies to `MIN`/`MAX` identically, since SPARQL defines them over the
  `ORDER BY` ordering. Proven and guarded in
  `sparql/order_id_gap_test.odin`; filed as evidence on record's backlog by
  `SPARQL-T-0039`, beside the §12 GRAPH note.

- **2026-08-25 (later the same day) — reopened and rewritten. The closure
  above was too broad, and this is the correction.**

  The supersession entry is accurate about what it covers and stops one
  consumer short. `SPARQL-T-0038` proved that record's id order is not
  SPARQL's `ORDER BY` order and that no plan can establish when they
  agree — which kills `MIN`/`MAX` in one read, a streaming `ORDER BY`,
  and an `ORDER BY … LIMIT n` that stops, all three of which need the ids
  to *mean* something. It says nothing about the consumers that need only
  a **consistent total order**, and this item's own "Deliberately out of
  scope" section named one: **merge joins**. Streaming DISTINCT, parked
  beside it, is in the same position, and so is streaming `GROUP BY`.

  Closing the whole item on a proof about ordering *semantics* conflated
  "an ordered read" with "a read ordered the way SPARQL sorts". They are
  not the same thing, and the distinction is the entire remaining content
  of this item. Reopened at P2, rescoped to the merge join, with the dead
  three-quarters recorded above rather than deleted.

  Four documents overclaimed in the same way and were corrected alongside
  this rewrite: `.metis/vision.md`, the family `CLAUDE.md`,
  `SPARQL-I-0003`'s closing Status, and `RECORD-T-0027` on
  odin-rdf-record's backlog. All four now say the ordered read is unusable
  *for ordering semantics* rather than unusable.
