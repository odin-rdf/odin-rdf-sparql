---
id: consume-ordered-reads-for-joins-a
level: task
title: "Consume ordered reads for joins: a merge join over two named permutations"
short_code: "SPARQL-T-0029"
created_at: 2026-08-09T13:15:00+00:00
updated_at: 2026-08-25T17:11:49.294372+00:00
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

# Consume ordered reads for joins: a merge join over two named permutations

## Objective **[REQUIRED]**

**Rewritten 2026-08-25.** This item was filed against odin-rdf-store's
`match_order`/`match_orderable`/`match_ordered` and asked for four things.
Three of them are dead **as this item specified them**: `MIN`/`MAX` in one
read, a streaming `ORDER BY`, and an `ORDER BY … LIMIT n` that stops all
need odin-rdf-record's id order to agree with SPARQL's, and
`SPARQL-T-0038` proved it does not and that no plan can tell when it
might. That half is closed and stays closed — see the Status entries
below.

**One correction, added 2026-08-25 after the rewrite:** of those three,
`ORDER BY … LIMIT n` is dead only in the form written here. This item
asked for it to stop *because the input is ordered*; **top-N does not need
an ordered input**. A bounded heap over `value_order` — keep the n best,
discard the rest — asks nothing of any store and is now `SPARQL-T-0041`,
at P2. A streaming *sort* is still blocked permanently. Nothing in that
moves this item, whose live half is and remains the merge join.

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

## Acceptance Criteria

**[REQUIRED]**

- [x] **Two patterns of one BGP that share a variable, both readable with
      that variable leading, are joined by a merge** rather than by
      probing the second once per row of the first. `Plan_Merge`
      (`sparql/plan.odin`), executed by `merge_begin`/`merge_position`/
      `merge_next` in `sparql/exec.odin`.
- [x] **The choice is made at plan time and priced**, not taken whenever
      it is possible. `SPARQL-T-0037` put `range_len` in the plan builder
      for exactly this kind of decision, and a merge reads *both* windows
      in full where a nested loop reads a narrow probe per row — so a very
      selective left side should still probe. **This is the same trade the
      original item got right about odin-rdf-store and for a different
      reason**: there, asking for an order could widen the scan; here, the
      scan width is the same either way and what changes is whether the
      right side is read once or per row. `MERGE_SCAN_PRICE`, and the
      window-width half of that sentence is now *proven* rather than
      assumed — see the criterion below and `merge_order_for`.
- [x] **Fallback is the current nested loop**, unchanged, wherever the
      shape does not allow a merge — which is most shapes. See below.
- [x] **No result changes.** ~~537/537 across 38 directories~~ **546 of
      556 evaluable entries across 40 directories, 0 mismatches, the same
      10 RDF/XML entries dark — identical before and after**, and every
      one of the bench's `solutions` counts unmoved.
- [x] **A test that the merge path is taken**, not merely available.
      `sparql/merge_join_test.odin`, six cases built on
      `join_order_test.odin`'s `plan_order` pattern: `plan_merge_of`
      asserts `Plan_BGP.merge` directly — that it is taken, that the
      pricing declines a 20:1 ratio, that two shared variables decline,
      and **which permutations** were named, since reading the right side
      as SPOG instead of PSOG would still be a window but would not
      ascend together. Verified to have teeth rather than passing
      vacuously: raising `MERGE_SCAN_PRICE` fails the declining case, and
      the correlated case was instrumented to confirm it re-opens the
      merge three times.
- [x] **Bench numbers, from the pinned cases that already exist.** This is
      a change whose entire purpose is cost, so a number is the
      deliverable. `bgp2` and `bgp3` are pinned and are the two cases that
      would move. Both moved; so did `group`, which was not expected, and
      `bgp3-selective-last`. One case was **added** — `bgp2-narrow-left`,
      the declining case, because nothing in the mix measured the half of
      the pricing rule that says no.

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

- **2026-08-25 (evening) — picked up, active.** Owner asked for it on the
  reading that a merge "can only improve performance, not regress it".
  **That reading is wrong, and this repository already owns the
  counter-example**: `bgp3-selective-last`, the case `SPARQL-T-0037`
  added. Its plan puts `?s b:dept b:d0` first — ~1,667 candidates in
  `large` — and joins it against `?s a b:Entity`, whose static window is
  20,000. A nested loop opens 1,610 narrow probes and visits 4,879
  candidates; an unpriced merge would read the full 20,000-fact window
  instead, **a 4.4x rise in `candidates` to save 1,610 scan opens**. So
  the pricing criterion is not polish on top of the merge, it is the half
  that makes the owner's sentence true, and it lands with it.

  **Baseline, this machine, before any change** (`make test` 288 green;
  `make bench`, `large`): bgp2 3.199 ms / match 20001 / next 60001 /
  candidates 40500; bgp3 21.901 ms / 100001 / 280001 / 180500;
  bgp3-selective-last 0.508 ms / 3221 / 8051 / 4879.

  **Design, and it is smaller than this item predicted.** Two findings
  against the Implementation Notes above:

  1. **"Either pattern not leadable by the shared variable" is an empty
     exclusion.** The six orders are the six permutations of S/P/O with G
     appended, so for any join position there is always an order putting
     every ground component first and the join variable next — and since
     `choose_order` maximises the same prefix, **the merge's window is
     exactly as narrow as the probe's would have been on the left side.**
     Naming an order costs nothing here. The live exclusions are only:
     more than one shared variable, a variable repeated inside one
     pattern, and a variable shared only in G (G is at key depth 3 in
     every order and can never lead).
  2. **"There is nowhere to put it" overestimates the surgery.** A merge
     does fit the depth loop, because what makes it a merge is that the
     right cursor is *monotone*: both sides ascend in the join variable,
     so the right side is opened once per BGP run and only ever moves
     forward. `record.Scan` is a slice cursor held by value, so replaying
     a group for a duplicate left row is a struct copy, not a re-open and
     not a buffer. `iter_open[1]` false means "position for this left
     row" instead of "open a probe", and everything above depth 1 is
     untouched.

     The monotonicity is also what bounds the scope: a cursor may only
     move forward if the left side never restarts under it, which is true
     **only at depth 1**. So the merge fuses the first two patterns in
     join order and nothing deeper — which is exactly the arithmetic this
     item already predicted for `bgp3` (~80,002 scans: 2 for the merge,
     80,000 for the unmergeable `?o` join).

  **Pricing.** Loop cost is `L_rows` scan opens plus the matching facts;
  merge cost is one open plus the right side's whole static window `R`.
  Taking `L` (the left window) as the pessimistic `L_rows` and 0 as the
  pessimistic match count, the merge wins while `R < k * L`, where `k` is
  the price of a scan open in candidate-visits. `k` is a named constant,
  chosen from measurement rather than asserted — see the next update.

- **2026-08-25 (evening) — built, measured, green. Ready for review.**

  **Results, `make bench`, this machine, baseline -> merge.** Every
  `solutions` count is unmoved in both configurations; only cost moved.

  | case (`large`) | match | next | candidates | ms |
  | --- | --- | --- | --- | --- |
  | bgp2 | 20001 -> **2** | 60001 -> 40002 | 40500 -> 41000 | 3.199 -> **0.518** |
  | bgp3 | 100001 -> 80002 | 280001 -> 260002 | 180500 -> 182500 | 21.901 -> 18.516 |
  | group | 20001 -> **2** | 60001 -> 40002 | 40500 -> 41000 | 5.531 -> **2.527** |
  | bgp3-selective-last | 3221 -> 1612 | 8051 -> 24815 | 4879 -> 23769 | 0.508 -> 0.396 |
  | bgp2-narrow-left *(new)* | 5 | 13 | 8 | 0.004 |

  `graph`, `optional`, `order`, `order-limit` and `path` did not move a
  single count. `make test` is 294 (six new); the W3C corpus is **546
  passing across 40 directories, 0 mismatches**, identical to baseline.

  **`group` was not predicted and should have been.** Its
  `?s b:dept ?d . ?s b:rank ?r` is a two-pattern join wearing an
  aggregate, and it halved. The lesson for the next optimization is that
  this item's arithmetic enumerated the cases *named* after joins rather
  than the cases that *are* joins.

  **The pricing constant was measured, and instruction-counting had it
  wrong by 3x.** The design update above reasoned a scan open at ~34
  compares against a candidate visit at ~5, so k in single digits, and
  set 8. Forcing the merge on and solving `bgp2` and `bgp3-selective-last`
  as two equations in the two unit costs gives **~134 ns per open against
  ~6.7 ns per visit — a ratio near 20.** The reason is memory, not
  arithmetic: a probe's two binary searches are ~34 *random* accesses into
  a 165k-element permutation where a merge's walk is sequential and
  prefetched. `MERGE_SCAN_PRICE` is **16**: the measured crossover with a
  margin under it, because declining a marginal win costs a fraction and
  taking a bad merge costs a whole window.

  At 8, `bgp3-selective-last` was declined and left 22% on the table. It
  is now taken, and it is the row worth reading twice: **4.9x the
  candidates and faster anyway.**

  **The declining case had to be built, and the first attempt at it
  failed in an instructive way.** Nothing in `bench/` exercised a merge
  being refused, so `bgp2-narrow-left` was added —
  `b:e0 b:knows ?o . ?o b:name ?name`, a 4-fact left against a
  20,500-fact right. It was intended to show a timing regression when
  forced, and it does not: forced, it is *faster*. **A merge walks its
  right side only as far as the largest join value the left side asks
  for**, and record assigns dictionary ids in first-mention order, so
  `b:e0`'s four targets — first mentioned while `b:e0` itself is emitted
  — hold among the lowest entity ids in the store and sit at the front of
  the window. Six facts of 20,500 are touched.

  That is a property of the data and nothing in a pattern predicts it, so
  the planner still prices the full walk and still declines. The case was
  kept, re-aimed at the **decision** (`match` = 5, not 2) and its comment
  rewritten to say so. It is the only thing in the repository that fails
  if `MERGE_SCAN_PRICE` is raised without an argument.

  **Two of this item's Implementation Notes were wrong and are corrected
  in the code rather than here** (both are argued at their definitions):
  "not leadable in any of the six orders" is an empty exclusion, and
  "there is nowhere to put it" overestimated the surgery — the merge sits
  inside the existing depth loop, because monotonicity is what makes it a
  merge and `record.Scan` being a value is what makes group replay a
  struct copy. Effort was M, not M–L.

  **Not done, and deliberately.** Streaming `DISTINCT` and streaming
  `GROUP BY` stay parked exactly as this item left them — still nothing
  measures them. A *seeking* merge (galloping into the sorted window
  instead of walking it) would remove the pessimism the pricing rule has
  to assume, and it is the concrete case for record's designed-but-unbuilt
  `Range.Vars`/`VarIter` with `Seek`; it is a further item, not this one.

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