---
id: order-a-bgps-patterns-by
level: task
title: "Order a BGP's patterns by estimated cardinality instead of by where they were written"
short_code: "SPARQL-T-0028"
created_at: 2026-08-09T12:30:00.000000+00:00
updated_at: 2026-08-09T12:30:00.000000+00:00
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

# Order a BGP's patterns by estimated cardinality instead of by where they were written

## Objective **[REQUIRED]**

Fill the seam this engine built and left empty. `join_order` in
`sparql/plan.odin` decides the order a basic graph pattern's triple
patterns are probed in, and it returns the identity permutation: the
patterns in the order the query wrote them. That is documented as a
placeholder, and nothing above it assumes the identity — the procedure
takes a BGP and returns a permutation, so a cost-based ordering drops in
without touching an operator.

What it needed was a number, and odin-rdf-store now has one:
`estimate(ds, pattern)` / `estimate_txn` (STORE-T-0018), landed
2026-08-09.

**This task was filed from the store side while building it**, which is
the round trip this family runs on: the capability was requested from
here (SPARQL-T-0019), built there, and the consuming task filed before
the store's release so the shape gets validated rather than assumed.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Correctness does not depend on it: every suite is green with the naive
order, and must stay green with any other. It is the difference between a
query engine and a fast one on datasets larger than the suites.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: A join order chosen from the data rather than from the query text.
- **Business Value**: Activates the one planning seam this engine has, using a number the store computes rather than a heuristic every consumer would have to duplicate and get wrong.
- **Effort Estimate**: S–M. One procedure's body, one new field on `Plan_Builder`, and the plumbing to pass the store's estimator through the two instantiation packages.

## Acceptance Criteria **[REQUIRED]**

- [ ] `Plan_Builder` carries an estimator alongside `find`, on exactly the pattern `Term_Finder` already establishes: a procedure pointer plus its `rawptr`, supplied by `sparql/kvstore` and named nowhere in the `sparql` package. **The core must go on naming no backend**; `make check`'s purity discipline in odin-rdf-shacl exists for the equivalent reason.
- [ ] `join_order` orders a BGP's patterns by ascending estimate, and is **stable**: patterns with equal estimates keep their written order, so a query's text still decides what the data does not.
- [ ] **A declined estimate is handled explicitly.** `store.ESTIMATE_UNKNOWN` is not a small number, and `store.estimate_known` is the test. See Technical Approach for the rule and why it is the conservative one.
- [ ] The estimate is taken through the query's own read transaction (`estimate_txn`), not through a fresh one. A query is one snapshot since SPARQL-T-0024, and a plan built against a different dataset than the one evaluated is a bug waiting for a concurrent writer.
- [ ] **No evaluation result changes.** The whole vendored corpus stays green at both `Term_ID` widths — 512 entries across 37 directories as of SPARQL-T-0020. A changed answer means the reordering is not order-independent, which would be a bug in the *evaluator*, not in the plan.
- [ ] A test that the ordering actually happens, and is not merely permitted to: a fixture where the written order is the bad one, asserting the built plan's permutation is the good one. Without it this task is untestable through results, since by the criterion above the results are identical either way.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

**Where the estimator enters.** `Plan_Builder` already carries
`find: Term_Finder` and `data: rawptr` — the store's non-interning term
lookup, supplied by the instantiation package so the core names no
backend. The estimator is the same shape and belongs beside it:

```odin
Cardinality_Estimator :: #type proc(data: rawptr, pattern: store.Match_Pattern) -> int
```

`sparql/kvstore` binds it to `estimate_txn` through the `Query`'s
transaction. A builder with a nil estimator plans exactly as today, which
is what keeps the core independently testable.

**The rule for a declined estimate, and why it is conservative.** The
store's indexes are all graph-first, so a pattern whose graph position is
unbound has no usable key prefix and `estimate` declines rather than
scanning to answer. That is not an edge case — **it is every pattern
inside a `GRAPH ?g { … }`**, because plan building puts an unbound slot in
the graph position there (`Plan_Graph_Bind`, SPARQL-T-0020).

The tempting rule — sort declined patterns last — is wrong: a declined
estimate says nothing about size, and a tiny pattern would be planned
last precisely when the planner could help most. The proposed rule is
instead:

> **Reorder only when every pattern in the BGP has a known estimate.
> Otherwise keep the written order.**

It is obviously correct, it never makes a plan worse than today's, and it
draws a line a user can understand: a default-graph BGP is planned, and a
BGP inside `GRAPH ?g` is not. It also fails in the safe direction if the
store's basis changes — a store that starts answering more patterns
simply plans more of them.

**Where the ordering is worth the most**, and worth measuring: the shape
`{ ?s :type :Person . ?s :name "Alice" }`, where one pattern matches
thousands and the other one, and the written order is the bad one.

### Dependencies

- **odin-rdf-store v0.6.0** — `estimate` does not exist in `v0.5.0`, which
  CI pins. The pin bump lands in the same commit, the sequencing
  SPARQL-T-0025 and SPARQL-T-0026 both recorded.
- **SPARQL-T-0026** wants the same release, and the two should probably
  land together rather than bumping the pin twice.

### Risk Considerations

**The one that would not show up in the suite.** If reordering changes an
*answer*, the bug is in the evaluator and not here: a BGP's patterns are
conjunctive and its solutions are a set, so the probe order may change
what is efficient and must not change what is found. The corpus is the
guard, and a failure in it under this change should be read as "we have
found an order-dependence in evaluation", which is worth more than the
planning.

**The one that would.** Estimating costs cursor operations per pattern at
query setup. It is bounded by the store (`ESTIMATE_WORK`), but bounded is
not free, and a query over a tiny dataset could plausibly spend more time
planning than evaluating. Worth a measurement before it is on by default,
which this repository has no benchmarks to take — see SPARQL-T-0027's
neighbours and the note that this engine has no bench target at all.

## Status Updates **[REQUIRED]**

- **2026-08-09 — Filed from odin-rdf-store while STORE-T-0018 was being
  built**, so the capability's shape is validated by a consumer rather
  than assumed by its author. Blocked on the store's v0.6.0, which is also
  what SPARQL-T-0026 waits for.
