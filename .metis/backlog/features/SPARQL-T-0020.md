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

- [x] The §18 reading that produces both expected answers is written down, with the specification text it comes from, before any code changes. If the two entries turn out to need different rules, say so. — **one rule, not two.** See Status Updates.
- [x] `graph-optional` and `graph-minus` pass, against both backends, at both Term_ID widths. — against kvstore, which is now the only backend (STORE-A-0006 / SPARQL-T-0023 retired memstore after this task was written), at both widths.
- [x] `sparql10-graph` (17) and `sparql11-negation` (12) enabled in `tests/w3c/harness/eval_test.odin` with pinned counts, and `tests/w3c/README.md`'s near-miss section updated — the two entries leave it.
- [x] Whatever the fix is, it is stated in the operator's comment the way the rest of the engine states its semantics: the rule, and the entry that pins it. — `Plan_Graph_Bind` in `sparql/plan.odin`, and `minus_excluded` in `sparql/exec.odin` for the half that lives there.

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

- **2026-08-09 — Done. One rule, not two, and it was in this corpus the whole time.**

  **The reading.** §18.5:

  ```
  eval(D(G), Graph(IRI, P)) = eval(D(D[IRI]), P)
  eval(D(G), Graph(var, P)) =
      Let R be the empty multiset
      foreach IRI i in D
          R := Union(R, Join( eval(D(D[i]), P), Ω(?var→i) ))
      the result is R
  ```

  P is evaluated against `D[i]`, a *plain graph*. Triple patterns inside a
  GRAPH clause therefore have no graph position at all, and `?var` is bound
  by nothing inside P — it arrives through the `Join` with `Ω(?var→i)`,
  which happens **after** P has been evaluated in full. In one sentence:
  **the variable a GRAPH clause binds is not in scope inside the clause.**

  The suspicion in Technical Approach was right, and the doubt SPARQL-T-0013
  recorded turned out to be answerable from inside the vendored corpus
  rather than from the spec text alone. Three entries state the rule in
  their own `rdfs:comment`, and one of them is a test this engine was
  already passing:

  - `sparql10-graph/graph-variable-scope` — "The variable bound by the GRAPH
    operator **is not in-scope inside it**". `SELECT * { GRAPH ?g { FILTER
    (BOUND(?g)) } }`, expecting no solutions.
  - `sparql10-graph/graph-optional` — "…is not used when evaluating a nested
    OPTIONAL".
  - `sparql11-negation/graph-minus` — "outer GRAPH operator does not affect
    MINUS disjointness".

  **Why the engine answered what it did.** It bound `?g` by putting its slot
  in the graph position of every triple pattern below. That is the same
  computation as the specification's *only while P is a pure pattern* —
  where restricting the search and filtering the answer come to the same
  thing. It is the same reason `scoped`/`probe_safe` already exists a few
  hundred lines away, arrived at from the other direction.

  - `graph-optional`: `GRAPH ?g { ?s ?p ?o OPTIONAL { ?s ?p ?g } }`. Pushed
    down, the OPTIONAL demands that a triple's object equal its own graph.
    That practically never holds, so it never matches, and all four left
    solutions survive with `?g` bound — the four the task recorded.
    Correctly, the OPTIONAL binds `?g` from the **object**, and the join
    then drops every solution whose object is not the graph's IRI. One
    survives: `:s2`, whose object is `<>` — the document IRI, which is the
    graph's name. That relative reference is the whole trick of the entry
    and is why it reads as a coincidence rather than as a rule.
  - `graph-minus`: `GRAPH ?g { ?a :p :o MINUS { ?b :p :o } }`. Pushed down,
    `?g` is in **both** sides' domains, they stop being disjoint, and MINUS
    removes what §18.5 says it must leave alone. The engine answered
    nothing.

  So the fix does not have to transfer from SPARQL-T-0015 after all: both
  entries are the pushdown being applied where it is not an equivalence,
  and one operator covers them.

  **The fix.** `Plan_Graph_Bind` (`sparql/plan.odin`), the join the
  specification puts *after* the clause:

  - `GRAPH ?g { P }` now compiles to `Graph_Bind(?g, g', P[graph := g'])`,
    where `g'` is a `fresh_internal_slot` — the same mechanism the path
    compiler already used for the endpoints it invents. P's triple patterns
    match in `g'`, so `?g` is a free variable inside P exactly as §18.5 has
    it, and `Graph_Bind` binds `?g` from `g'` on the way out or drops the
    solution when P bound `?g` to something else.
  - The three special cases (a body with no triple patterns; a blocking
    operator; a path operator) are unchanged in *what* they do — enumerate
    the graphs with `Plan_Graph_Scan` — and now enumerate into `g'`.
  - `minus_excluded` (`sparql/exec.odin`) counts only **query** variables as
    shared. Compatibility still spans every slot, which is what confines
    MINUS's right side to the graph its left side ran in; sharing does not,
    because an internal slot is not in a solution's domain. This is a no-op
    for the engine's other invented slots — path endpoints, triple-term
    shapes, pattern blank nodes are never shared between two sides — and it
    is what `graph-minus` needs.
  - `Graph_Bind` pre-binds `g'` when the enclosing solution already bound
    `?g` (`?d :graph ?g . GRAPH ?g { … }`). Same answer, since the join
    would discard every other graph anyway; the difference is an index
    probe instead of a full scan and a filter. Without it this task would
    have been a performance regression on the commonest shape there is.

  **A third thing fixed by falling out.** `plan_matches_triples` now answers
  `false` for a `Graph_Bind` subtree: its patterns match in *its* graph, so
  they can carry no enclosing GRAPH variable. Nested `GRAPH ?g { GRAPH ?h
  { … } }` used to leave `?g` unbound — the inner clause took the graph
  position over and nothing was left to bind the outer one. It now
  enumerates, and both variables bind. No vendored entry covers it; a case
  in `graph_scope_test.odin` does.

  **Results.** `sparql10-graph` 17/17 and `sparql11-negation` 12/12, both
  enabled in `eval_test.odin` with pinned counts. Nothing else moved: the
  survey is identical elsewhere, at both `Term_ID` widths. Asserted
  coverage 483 → **512 across 37 directories**; the corpus stands at 544 of
  556 (97.8%), with every remaining failure now either term identity
  (SPARQL-T-0021) or RDF/XML data. `tests/w3c/README.md` updated, including
  two stale claims found next to the ones this task had to change ("both
  backends", `sparql/memstore/forms_test.odin`), and `.metis/vision.md`
  amended.

  Seven cases added in `sparql/kvstore/graph_scope_test.odin`. The suite
  entries are the verdict but a poor place to *learn* the rule — both are
  built out of document IRIs and relative references, where the coincidence
  that makes the answer come out is invisible — so the two rules are
  restated there over explicit graph names, alongside the paths no vendored
  entry reaches: the pre-bound variable, nested clauses, and the release of
  the GRAPH variable between solutions.

  **Found on the way, and unrelated: the whole evaluation suite was
  aborting** before any of this could be measured, on `assert(… "match:
  NAMED_GRAPHS outside the graph position")` from kvstore. `SYNTHETIC_FIRST`
  in `sparql/expr_eval.odin` was the literal `3` — "the first Sentinel
  counter the store has not taken", read off the three that existed when it
  was written. odin-rdf-store's `STORE-T-0017` then took counter 3 for
  `NAMED_GRAPHS`, so the first computed term of every query *was* the
  named-graph wildcard. It is now `store.SENTINEL_CONSUMER_FIRST`, which the
  store reserved against precisely this in `STORE-T-0021` and which has been
  in v0.5.0 all along — this engine had never adopted it. No store change
  and no new release needed; the constant needed naming instead of
  guessing. Filed as SPARQL-T-0027 for the record, fixed here because
  nothing in this task was measurable until it was.

  **Not pushed.** `main` already carries SPARQL-T-0026, which consumes
  `store.NAMED_GRAPHS` — unreleased in odin-rdf-store — so this repository
  cannot be released or its CI pin bumped until v0.6.0 exists there.
