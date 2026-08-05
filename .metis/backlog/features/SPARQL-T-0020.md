---
id: graph-scoping-for-optional-and
level: task
title: "GRAPH scoping for OPTIONAL and MINUS: the last two engine-semantics entries"
short_code: "SPARQL-T-0020"
created_at: 2026-08-05T22:47:26.063058+00:00
updated_at: 2026-08-05T22:47:26.063058+00:00
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

# GRAPH scoping for OPTIONAL and MINUS: the last two engine-semantics entries

## Objective **[REQUIRED]**

Two vendored W3C evaluation entries fail, both for the same reason and
neither yet understood well enough to fix: what a `GRAPH` clause does to
an operator *inside* it that is evaluated over more than one solution at
a time.

They are the only two failures in the whole corpus that are the
evaluation engine's own semantics. Everything else is green
(SPARQL-I-0002 exit verification, 2026-08-05: 483 of 488 vendored
evaluation entries, both backends, both Term_ID widths).

**`sparql10-graph/graph-optional`** — "the variable bound by the GRAPH
operator is not used when evaluating a nested OPTIONAL". The engine
answers four solutions; the DAWG expects one:

```
got:  g=…/data-optional.ttl s=:s     want: g=…/data-optional.ttl s=:s2
      g=…/data-optional.ttl s=:s2
      g=…/data-g1.ttl       s=:x
      g=…/data-g1.ttl       s=:a
```

**`sparql11-negation/graph-minus`** — "outer GRAPH operator does not
affect MINUS disjointness". The engine answers nothing; the suite
expects `a=:a`. A MINUS inside a GRAPH clause is currently evaluated
against the merge of the named graphs rather than against each graph in
turn, because MINUS's right side is materialized once — it has to be,
since its variables are out of the left side's scope, which is a
*different* reason from the one that made the blocking operators need
re-collection per graph (SPARQL-T-0015 fixed that case, and the fix does
not transfer).

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Two entries in 488. Both directories stay *disabled* under the
"enabled means fully green" discipline, so the two failures cost four
other directories' worth of coverage —
`sparql10-graph` (16/17) and `sparql11-negation` (11/12) — which is the
real reason to do this rather than the two entries themselves.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `GRAPH ?g { … OPTIONAL … }` and `GRAPH ?g { … MINUS … }` answer what the specification says they answer.
- **Business Value**: Enables two more suite directories (27 more pinned entries) and closes the last engine-semantics gap in the 1.1 evaluation corpus.
- **Effort Estimate**: M, and mostly *reading*. SPARQL-T-0013 recorded that the reading of §18 that produces the DAWG's `graph-optional` answer could not be established from the spec text with confidence, and declined to fit the code to the expected result. That judgement stands: the work here is to settle the semantics first — against the spec and against a reference implementation's behaviour — and only then to change the operator.

## Acceptance Criteria **[REQUIRED]**

- [ ] The §18 reading that produces both expected answers is written down, with the specification text it comes from, before any code changes. If the two entries turn out to need different rules, say so.
- [ ] `graph-optional` and `graph-minus` pass, against both backends, at both Term_ID widths.
- [ ] `sparql10-graph` (17) and `sparql11-negation` (12) enabled in `tests/w3c/harness/eval_test.odin` with pinned counts, and `tests/w3c/README.md`'s near-miss section updated — the two entries leave it.
- [ ] Whatever the fix is, it is stated in the operator's comment the way the rest of the engine states its semantics: the rule, and the entry that pins it.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The suspicion, unverified, is that both come from the same place: a
`GRAPH ?g { P }` where P contains an operator that is not a pure pattern
means "for each named graph g, evaluate P against *that* graph", and the
engine's mechanism — push the graph into every triple pattern of P and
let matching bind ?g — is only equivalent to that when P is a pure
pattern. SPARQL-T-0015 found exactly this for the blocking operators and
fixed it with `Plan_Materialized.correlated` (re-collect per enclosing
solution). MINUS cannot reuse that fix as it stands, and OPTIONAL is a
third shape again.

Start from `scoped` in `sparql/plan.odin`, which is where the engine
already decides what may be correlated and what must be materialized —
its comment is the best statement of the problem in the tree.

### Dependencies

None. Both entries are vendored and measured; `zz_survey_test.odin` with
`DETAIL` set to the two directories prints the got/want in full.

### Risk Considerations

The known trap, recorded in SPARQL-T-0013: it is easy to make either
entry pass by fitting the code to its expected result and to break the
15 GRAPH entries that pass today. The suite is the guard, but the
semantics have to come first.

## Status Updates **[REQUIRED]**

- **2026-08-05 — Created at SPARQL-I-0002's exit verification (SPARQL-T-0019)**, which found these two as the only remaining engine-semantics failures in the vendored corpus.
