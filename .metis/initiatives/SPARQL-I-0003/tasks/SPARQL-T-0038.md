---
id: name-the-order-min-max-in-one-read
level: task
title: "Name the order: MIN/MAX in one read, ORDER BY that streams, LIMIT that stops"
short_code: "SPARQL-T-0038"
created_at: 2026-08-24T20:42:45.891203+00:00
updated_at: 2026-08-24T20:42:45.891203+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0037"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# Name the order: MIN/MAX in one read, ORDER BY that streams, LIMIT that stops

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Four operators in this engine pay for an order the store already has.
This task **supersedes `SPARQL-T-0029`**, which was written against
odin-rdf-store's `match_order`/`match_orderable`/`match_ordered` — three
procedures that leave with the store.

record's shape is stronger, and the difference changes the design rather
than only the names. `snapshot_match_as(snap, p, order)` lets the planner
**name the permutation outright**, and `Range.order` reports what it got.
Where the store answered "can this pattern lead with that position?" —
yes or no — record's answer is that **any order answers any pattern**;
only the window width differs, because bound components that do not lead
the key become residual checks. So the operator does not fall back. It
chooses, at plan time, from the pattern alone.

## Acceptance Criteria

- [ ] **MIN/MAX over a plain variable is one read.** `MIN(?o)` over a
      group whose pattern can be ordered by that variable's position
      takes the first fact of the ordered range instead of passing over
      the group. `sparql/aggregate.odin`'s `agg_keep_extreme` path
      (`:425`, `:430`).
- [ ] **`Plan_Order` streams when it can.** It is blocking today, and
      unavoidably so in general — the last solution may sort first — but
      over an input already ordered by the sort key it is a pass-through.
      The plan decides this at build time from the pattern and the sort
      key, **never from the data**.
- [ ] **`ORDER BY … LIMIT n` stops after n** when the input is ordered —
      the top-N case, which today sorts everything to return ten rows.
- [ ] **Ordering by term is not ordering by value, and the plan knows
      it.** record's own warning (api.md §12.8): dictionary ids are in
      first-appearance order and §5.3 rejected an order-preserving
      dictionary, so **only inlined numerics sort correctly by id**;
      string ordering by id is meaningless. The streaming path is
      available for exactly the cases where SPARQL's `ORDER BY` semantics
      and record's id order agree, and the plan must establish that
      before taking it. **This is the criterion most likely to be got
      wrong, and getting it wrong returns wrong answers, not slow ones.**
- [ ] **Every one of these is a choice, not a requirement.** Where the
      order does not serve, the operator does exactly what it does today.
      The decision is made once at plan time and never mid-stream.
- [ ] **No result changes.** 512 of 512 across 37 directories.
      `sparql10-sort` (14 entries) and `sparql11-aggregates` (47) are the
      directories that would notice, and both are enabled.
- [ ] **A test that the streaming path is taken**, not merely available —
      results cannot distinguish it, since by the criterion above they are
      identical either way.
- [ ] **Bench lines from SPARQL-T-0036** for the three cases, showing
      what the order bought.

## Implementation Notes

### Technical Approach

**The order is a function of the pattern and is knowable at plan time**,
which is what makes it usable here — the same property the store's
version had and the reason `SPARQL-T-0029` could be written before
either store shipped anything.

**`choose_order(p)` is record's default**, and the six orders are SPOG,
PSOG, OSPG, SOPG, POSG and one more, all with **G appended as the final
tiebreaker** (`RECORD-A-0004`). The consequence for this task: a graph is
never a leading component, so an ordered read inside a `GRAPH` clause is
ordered on the triple positions and the graph is residual. That interacts
with §12 of the initiative — the same design decision that makes `GRAPH`
scan is the one that makes ordering within it straightforward.

**Where the plumbing goes.** `SPARQL-T-0029` specified the same
procedure-pointer seam `SPARQL-T-0028` did, so the core would name no
backend; **owner decision 1 retires that**, and the plan builder holds
the snapshot directly. This task and SPARQL-T-0037 share that plumbing —
which is why they are sequenced together rather than in parallel.

**The MIN/MAX case is small and self-contained; the streaming-ORDER BY
case touches the operator tree.** Land them in that order, so the cheap
half is banked before the expensive half starts.

### Dependencies

Blocked by SPARQL-T-0037 — the two share the plan-builder plumbing, and
doing them in parallel means merging the same change twice.

### Risk Considerations

**The term-order-versus-value-order trap is the real risk of this task.**
SPARQL's `ORDER BY` has a defined ordering over RDF terms — with
numerics compared by value, strings by codepoint, and a total order
across kinds — and record's id order is *first-appearance* order for
everything except inlined numerics. A plan that takes the streaming path
where those disagree returns solutions in the wrong order, and
`sparql10-sort` is the only thing standing between that and a shipped
bug. Be conservative: take the streaming path only where the agreement is
provable from the sort key's type, and write the reasoning in a comment.

**Nothing in the corpus measures the benefit**, which was
`SPARQL-T-0029`'s own stated risk and is part of why it was P1. That is
what SPARQL-T-0036 is for; if the bench cannot show a difference, say so
rather than asserting one.

## Status Updates

*To be added during implementation*

### 2026-08-25 — the premise does not hold: record's id order and SPARQL's order are unrelated, and no plan can tell when they agree

**Finding first, because it decides the task.** Every criterion here rests
on one thing being possible: that the plan can establish, from the pattern
and the sort key, that record's id order and SPARQL's `ORDER BY` order
agree. **It cannot, and not because this engine lacks information — no
SPARQL query contains it.**

The task named this as its own biggest risk ("the term-order-versus-value-
order trap ... getting it wrong returns wrong answers, not slow ones") and
told this task to take the streaming path "only where the agreement is
provable from the sort key's type". The measurement is that **the set of
provable cases is empty.**

### The mechanism, measured rather than reasoned about

`RECORD-A-0001`'s frozen scheme: bit 31 flags an inlined term, bits 30..28
tag it, the low 28 bits are an offset-binary payload. Two consequences —
inlined integers *do* sort numerically among themselves, and **every
dictionary id (< 2^31) sorts before every inlined id (>= 2^31)**.

Five ordinary values, loaded into one store, ids read back with
`snapshot_resolve`:

| term | id | |
|---|---|---|
| `1` | 0xa8000001 | inlined |
| `3` | 0xa8000003 | inlined |
| `200000000` | 6 | **dictionary** — past the 2^27 inline range |
| `"2.5"^^xsd:decimal` | 9 | **dictionary** — decimal is never inlined |
| `"007"^^xsd:integer` | 11 | **dictionary** — a non-canonical lexical form |

- **By record's id order**: 200000000, 2.5, 007, 1, 3.
- **By SPARQL's `ORDER BY`**: 1, 2.5, 3, 007, 200000000.

Not a permutation apart at one position — unrelated. The largest value
sorts first and the smallest fourth. An ordered read taken as `ORDER BY`
returns the first list.

**Three independent mechanisms, none of them exotic.** Out of range at
1.34x10^8; any decimal, float or double, which SPARQL compares by value
across the whole numeric tower; and any non-canonical lexical form, which
is RDF term identity done *correctly*. Each alone is fatal, and each is
ordinary data.

### Why no plan can rule them out

What disqualifies a value is a property of that value. SPARQL has no
static types: a variable's datatype is not knowable from the query text,
`FILTER(?r < 100)` admits `"5.0"^^xsd:decimal`, and a pattern says nothing
about the terms its object position will hold. So the plan cannot
establish the agreement from the pattern and the sort key — the criterion
as written has no satisfiable instance.

This applies identically to all three operators, because SPARQL defines
`MIN`/`MAX` over the `ORDER BY` ordering: `agg_keep_extreme` compares with
`value_order`, and taking the first fact of an id-ordered range would
answer a different question. **The "small and self-contained" half of the
task is not smaller than the other half; it has the same blocker.**

### What is banked

`sparql/order_id_gap_test.odin` — two tests, and they are the durable
deliverable of this finding rather than a demonstration of it. One asserts
the id relationships above against a live store, so the day record's
encoding changes it will say so. The other asserts the engine returns
SPARQL's order for the same fixture. Together they are a guard: if someone
later takes the streaming path on the grounds that "record's ids are
ordered", these fail with the reason attached.

`make test` 289 tests, 537/537 unchanged.

### The decision this needs

Not this task's to make. Three ways forward, and they are materially
different work:

1. **Close it as evidence.** The gap is real, proven, and belongs on
   record's backlog next to the §12 GRAPH note — the same "capability gaps
   become evidence, not workarounds" convention, and the same initiative
   to file it. Costs nothing further here; the three operators keep doing
   what they do today, which is correct.
2. **A narrow data-dependent variant.** For a single-pattern BGP whose
   sort key leads the chosen order, the range is sorted, so its first and
   last ids at that position are its min and max — and if *both* fall in
   one inlined tag band, every id between them does too, since the bands
   are contiguous. That is an exact proof in two array reads at plan time.
   It contradicts this task's "never from the data" (though not its
   intent, which is that nothing be decided mid-stream), it is narrow, and
   **it would not move `bench/`**: `order` sorts by `?name`, a string, and
   would never qualify.
3. **Ask record for an order-preserving id space.** `api.md` §5.3 rejected
   a globally order-preserving dictionary because renumbering is fatal,
   and §12.8 already records the consequence as a known SPARQL cost.
   `architecture.md` §10.3 sketches a per-type order-preserving subspace.
   This is a record-side initiative and a format change, which is a much
   larger thing than this task.

**Recommendation: 1.** The measurement says the optimization has no safe
instance, and 2 buys a case the corpus and the benchmark do not contain.
