---
id: ask-the-store-for-the-named-graphs
level: task
title: "Ask the store for the named graphs instead of matching everything and dropping the default one"
short_code: "SPARQL-T-0026"
created_at: 2026-08-09T11:03:05.008975+00:00
updated_at: 2026-08-09T11:03:05.008975+00:00
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

# Ask the store for the named graphs instead of matching everything and dropping the default one

## Objective **[REQUIRED]**

Build `store.NAMED_GRAPHS` into the patterns this engine hands the store,
and delete the post-filter it exists to replace.

**The capability is upstream and unconsumed.** odin-rdf-store landed
`STORE-T-0017` on 2026-08-09: a fourth Sentinel, valid in the graph
position of a `Match_Pattern` and nowhere else, meaning "every graph that
has a name". kvstore answers it by ending its scan at the default graph
rather than reading it and discarding it — the graph leads all three
indexes and `DEFAULT_GRAPH` sorts above every ID a graph label can have,
so the named graphs are a prefix of the scan.

**It was filed from here** (SPARQL-T-0019, the evaluation initiative's
evidence consolidation), and until this task lands the store half changes
nothing observable: the engine still matches `WILDCARD` and drops what
comes back.

Two sites, and they are the same mistake at two altitudes:

- **`probe_pattern` / `unify_quad`** (`sparql/exec.odin:2189`, `:2227`).
  A variable in the graph position comes only from `GRAPH ?g`, which
  ranges over the *named* graphs — the default graph has no name for ?g
  to bind to. `probe_pattern` turns the unbound variable into `WILDCARD`
  and `unify_quad` then throws away every quad whose graph came back
  `DEFAULT_GRAPH`, unwinding the bindings it had already made. The
  comment at `:2227` says so and names the store item it is waiting for.

- **`Plan_Graph_Scan`'s enumerator** (`sparql/exec.odin:875`). `GRAPH ?g
  {}` matches `MATCH_ALL` and skips `DEFAULT_GRAPH` and the graphs it has
  already seen. `NAMED_GRAPHS` removes the first of the two skips and the
  fetching behind it; the second stays, because this is still enumerating
  distinct names by reading quads. That half is `STORE-T-0016`'s
  (`graphs(ds)`), not this one's — **this makes it cheaper, not right.**

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P2 - Medium (nice to have)

Correct today, and the over-fetch only bites when the default graph is
large relative to the named ones — the same priority the store item
carried, for the same reason. What changes it from a nicety is the
deployment shape: ~200 processes per machine, each embedding a store, and
a `GRAPH ?g { … }` that reads the whole default graph per query is a CPU
cost paid 200 times.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `GRAPH ?g { … }` reads the named graphs and not the default one, which is what the query asked for.
- **Business Value**: Closes the last place where this engine post-filters what it matched, so "the pattern the engine builds" and "the pattern the query means" finally coincide.
- **Effort Estimate**: S. One line in `probe_pattern`, one deletion in `unify_quad`, one pattern in the graph enumerator — plus the CI pin, which is the part that has to be sequenced.

## Acceptance Criteria **[REQUIRED]**

- [ ] `probe_pattern` emits `store.NAMED_GRAPHS` rather than `store.WILDCARD` for an **unbound variable in the graph position**, and `store.WILDCARD` everywhere else. A bound graph variable still substitutes its value; a ground graph ref is untouched.
- [ ] `unify_quad`'s `DEFAULT_GRAPH` branch goes — **as an assert rather than a silent deletion**, since it is now a case the store promises cannot arrive, and an assert says which layer broke if it ever does.
- [ ] `Plan_Graph_Scan`'s enumerator matches `{WILDCARD, WILDCARD, WILDCARD, NAMED_GRAPHS}` instead of `MATCH_ALL`, and drops its `graph == DEFAULT_GRAPH` skip. The `graph_seen` dedup stays.
- [ ] The vendored GRAPH suites stay green at both `Term_ID` widths — `sparql10-graph` and `sparql11-graph` in particular, and the whole evaluation corpus in general. **No result may change**: this is a cost fix, and a changed answer means one of the two sites was doing something else as well.
- [ ] `.github/workflows/ci.yml`'s `ref:` for odin-rdf-store is bumped to the release carrying `STORE-T-0017`, **in the same commit** — the pattern does not compile against `v0.5.0`.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

`probe_pattern` reads a `Plan_Triple` whose fourth position is `b.graph`
from plan building (`sparql/plan.odin:1067`, `:1637`): a ground
`DEFAULT_GRAPH` ref for a default-graph BGP, a ground IRI ref inside
`GRAPH <iri>`, a variable ref inside `GRAPH ?g`. So the rule is exactly
"variable, in `store.QUAD_G`, currently `UNBOUND`" and needs no new
information threaded down from the plan.

`unify_quad` binds and unwinds; deleting its graph branch also deletes an
unwind path, which is the only part of this that is not a one-liner.

### Dependencies

**Blocked on an odin-rdf-store release containing `STORE-T-0017`.** It is
unreleased on `main` as of 2026-08-09 and CI pins `v0.5.0`, which does not
have `store.NAMED_GRAPHS`. Local verification runs against the sibling
working tree through `-collection:store=../odin-rdf-store`, so this can be
green before the release exists — the same sequencing `SPARQL-T-0025`
recorded for `txn_begin_as_of`, and the same rule: the change and the pin
bump land together or CI is red.

Related, and deliberately not merged into this: `SPARQL-T-0020` (GRAPH
scoping for OPTIONAL and MINUS) is the same clause and a different
problem — what a GRAPH does to an operator *inside* it. Nothing here
moves it.

### Risk Considerations

**The invariant becomes load-bearing.** Today "a variable in the graph
position comes only from `GRAPH ?g`" is a comment justifying a filter;
afterwards it decides what the store is asked for. If it were ever false —
some future clause putting a variable in the graph position of a
default-graph pattern — a default-graph quad would silently stop matching,
and no test would obviously fail. That is why the assert replaces the
branch rather than the branch simply going.

Second, `NAMED_GRAPHS` must never reach the store in the other three
positions; `probe_pattern` already asserts against `UNBOUND` leaking into
a pattern and is the natural place to keep that shape.

## Status Updates **[REQUIRED]**

- **2026-08-09 — Created from odin-rdf-store `STORE-T-0017`**, which landed the store half and left this one unfiled. The store's own close-out records that nothing observable changes until this task exists; it now does.

- **2026-08-25 — Closed, not done** (SPARQL-I-0003, §12). This item asked the
  engine to build `store.NAMED_GRAPHS` in the graph position of a match
  pattern, so that `GRAPH ?g { … }` would stop over-fetching the default
  graph and filtering it out in `unify_quad`. **The sentinel left with
  odin-rdf-store**, which this engine no longer depends on, so the item cannot
  be done as written and is closed rather than re-pointed.

  **The problem it names is real and survives; its shape on odin-rdf-record is
  different and harder.** record has `Filter.graphs`, a *set* of graph ids —
  which serves `FROM NAMED` well, and is a better fit for that than the store
  ever had — but **"every graph that has a name" is not expressible at all**.
  It is not a set the engine can enumerate cheaply and, more fundamentally,
  `RECORD-A-0004` keeps G out of every prefix, so there is no equivalent of the
  trick that made the store's answer free: `DEFAULT_GRAPH` carried the highest
  kind tag, so in a graph-first index the named graphs were a prefix and the
  default graph was the tail, and kvstore answered by *ending the scan*
  instead of filtering it. record has no graph-first index to end.

  So the over-fetch this item wanted removed is still there, and
  `unify_quad`'s post-filter (`sparql/exec.odin`) still carries the comment
  saying so, now naming record's constraint instead of the store's. It is the
  same family of cost as SPARQL-I-0003 §12's `GRAPH <g> { … }` scan and it is
  filed with that evidence by `SPARQL-T-0039` — one note about G never being a
  prefix, with two consumer-side consequences, rather than two notes.

  All five of its acceptance criteria were open and none was ever implemented;
  `store.NAMED_GRAPHS` never appeared in this repository outside a comment,
  which is why the port did not have to unpick anything.
