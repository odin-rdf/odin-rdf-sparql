---
id: consume-ordered-iteration-for-min
level: task
title: "Consume ordered iteration: MIN/MAX in one read, and an ORDER BY that streams"
short_code: "SPARQL-T-0029"
created_at: 2026-08-09T13:15:00.000000+00:00
updated_at: 2026-08-09T13:15:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"
  - "#feature"


exit_criteria_met: true
initiative_id: NULL
---

# Consume ordered iteration: MIN/MAX in one read, and an ORDER BY that streams

## Objective **[REQUIRED]**

Four operators in this engine pay for an order the store already has.
odin-rdf-store now guarantees it and lets it be asked for
(STORE-T-0015, 2026-08-09):

```odin
match_order(pattern) -> [4]int          // the order match yields this pattern in
match_orderable(pattern, lead) -> bool  // can it lead with that position?
match_ordered(ds, pattern, lead)        // stream ordered by one position
```

The order is ascending in the four positions taken in the reported
permutation, Term_IDs compared as integers. It is **per pattern** and **a
function of the pattern alone** — knowable at plan time, before anything
is read, which is what makes it usable here.

**This task was filed from the store side while building it**, so the
capability's shape is validated by a consumer rather than assumed by its
author. It is the second half of the planner surface; SPARQL-T-0028 is the
first (cardinality estimates), and the two interact — see below.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P1 - High (important for user experience)

The store item was P1 because four operators independently asked for it.
The same reasoning lands here, where the operators are.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: Aggregates and sorts over large datasets stop costing memory proportional to the answer.
- **Business Value**: Closes the largest gap between "correct" and "usable at scale" in this engine. Nothing in the corpus measures it, which is part of the problem — see Risk Considerations.
- **Effort Estimate**: M, and separable: the MIN/MAX half is small and self-contained, the streaming-ORDER BY half touches the operator tree.

## Acceptance Criteria **[REQUIRED]**

- [ ] **MIN/MAX over a plain variable is one read.** `MIN(?o)` over a group whose pattern can be ordered by that variable's position takes the first quad of `match_ordered` instead of passing over the group. `sparql/aggregate.odin`.
- [ ] **ORDER BY on a stored term streams when it can.** `Plan_Order` is blocking today because the last solution may sort first; over an input already ordered by the sort key it is a pass-through. The plan must decide this from `match_order`/`match_orderable` at build time, never from the data.
- [ ] **`ORDER BY … LIMIT n` stops after n** when the input is ordered — the top-N case, which today sorts everything to return ten rows.
- [ ] **Every one of these is a fallback, not a requirement.** When the order is refused the operator does exactly what it does today. `match_orderable` answers from the pattern, so the choice is made once at plan time and never mid-stream.
- [ ] **No result changes.** The whole vendored corpus green at both `Term_ID` widths — 512 entries across 37 directories. `sparql10-sort` and `sparql11-aggregates` are the directories that would notice, and both are enabled.
- [ ] A test that the streaming path is *taken*, not merely available: results alone cannot distinguish it, since by the criterion above they are identical either way.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

**The plumbing is the same seam SPARQL-T-0028 opens.** `Plan_Builder`
carries `find: Term_Finder` and its `rawptr`; the estimator joins it there,
and so do these. The `sparql` package must go on naming no backend.

**Where the order is refusable, and it is not a corner.** Every store
index is graph-first, so with the graph bound any of subject/predicate/
object can lead, and **with the graph unbound only the graph can**. That
is every pattern inside a `GRAPH ?g { … }`, since plan building puts an
unbound slot in the graph position there (`Plan_Graph_Bind`,
SPARQL-T-0020). So the streaming paths apply to default-graph patterns and
not inside a GRAPH clause, and the fallback is not a rare branch — it is
half the queries. Write it first.

**The trade this task must not get wrong, and the reason it needs
SPARQL-T-0028.** Asking for an order can *widen* the scan. The store's
worked case is `{g, :s, ?p, ?o}` ordered by object: only gosp can lead
with the object, and its bound prefix is the graph alone, where the
ordinary match uses gspo and narrows to one subject. So `MIN(?o)` over a
subject-bound pattern is one read of a wider scan, and whether that beats
reading the narrow scan and taking the minimum depends on how many quads
the narrow one has — which is exactly what `estimate` answers. **Doing
this task without the estimator risks making MIN slower on the shape it
was meant to speed up.** Sequence it after SPARQL-T-0028, or gate the
MIN/MAX rewrite on an estimate.

**Deliberately out of scope, and why.** The store item's evidence log
named two more consumers:

- **Merge joins.** Two ordered streams on a shared variable, instead of
  nested index probes. It needs a planner with alternatives to choose
  between, which needs both halves of this surface adopted first. A task
  of its own, once there is something to measure.
- **Streaming DISTINCT.** Deduplication retains a key per distinct row —
  the one place the streaming path allocates (`exec.odin`). Over an
  ordered stream it is a comparison with the previous row. Small, but it
  requires the *solution* sequence to be ordered, not just one pattern's
  quads, which is only true in narrow cases. Worth its own look rather
  than a line in this one.

### Dependencies

- **odin-rdf-store v0.6.0** — none of these procedures exist in `v0.5.0`,
  which CI pins. The pin bump lands in the same commit, the sequencing
  SPARQL-T-0025 and SPARQL-T-0026 recorded.
- **SPARQL-T-0028** for the estimator, per the trade above.
- SPARQL-T-0026 wants the same release; the three should land together
  rather than bumping the pin three times.

### Risk Considerations

**This engine has no benchmarks** — recorded here because it is the
binding constraint on the whole task. Every claim above is about *cost*,
the corpus measures only correctness, and there is no bench target in this
repository to catch a change that is correct and slower. Standing up
something minimal is arguably a prerequisite rather than a nice-to-have,
and the store has `make bench` to copy the shape from.

**The failure mode to watch is a plan that streams when it must not.**
`Plan_Order` is blocking for a reason, and the whole of this task is
deciding when it need not be. The decision must come from the plan — the
pattern's declared order and the sort key — and never from an observation
about the rows seen so far. A test that pins *which path was taken* is the
guard, which is why it is an acceptance criterion.

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
