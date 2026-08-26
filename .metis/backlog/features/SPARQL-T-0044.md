---
id: a-graph-set-on-query-init-the
level: task
title: "A graph set on query_init: the application's ceiling on what a query may read"
short_code: "SPARQL-T-0044"
created_at: 2026-08-26T21:10:58.020797+00:00
updated_at: 2026-08-26T23:11:59.800897+00:00
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

# A graph set on query_init: the application's ceiling on what a query may read

## Objective **[REQUIRED]**

Let the application bound **every read a query makes** to a set of
graphs it supplies, outside the query text, so that the set is an
**authorization ceiling** no query can widen.

**The consumer.** The application above this engine is introducing a
**workspace**, decided on 2026-08-26 as **a named graph per workspace**:
a statement's graph is the workspace it was made in; a user in `W` reads
`{W} ∪ ancestors(W)`; a report in `A` reads `{A} ∪ descendants(A)`;
siblings never see each other. The tree is application data and the
application computes the set per request. On odin-rdf-record the set is
`Filter.graphs`, enforced per fact inside `scan_next` (`record/read.odin:184-193`)
— below this engine, and intersected with any `GRAPH <x>` a pattern binds,
so a `GRAPH <sibling> { … }` written into the query yields nothing.

**What this engine does today.** It reads the whole store, always:

- Both executor read sites — `match_open` and `match_open_as`
  (`sparql/exec.odin:301-307`, `:326-332`) — build
  `record.Filter{origin = .Any}` and never set `graphs`.
- `query_init` (`sparql/query.odin:104`) takes a snapshot, an algebra
  and a base; there is nowhere to put a set.
- `FROM` / `FROM NAMED` are parsed into `Dataset_Clause`
  (`sparql/ast.odin:189`, `parser.odin:474`) and **never consumed** by
  translation or execution. The record-era engine has never honoured
  them; the W3C dataset suites pass because the harness loads each
  entry's data per manifest.

So nothing the application knows about who may see what reaches a
query. Everything needed on the store side exists; this is the engine
threading it through.

## Design

- **`query_init` gains a graph set**, stored on `Query` and `Exec`
  (`exec_init`, `exec.odin:443`, gains the parameter) and passed at both
  read sites: `Filter{origin = .Any, graphs = e.graphs}`. That is the
  whole correctness change — two lines at the seam, one field, one
  parameter.
- **Resident ids, not labels.** The caller resolves each graph label
  with `record.snapshot_resolve` against **the same snapshot** the query
  is prepared on, and **drops misses**: a workspace graph with no facts
  yet is a miss, and `0` must never enter the set — in a
  `Filter.graphs` set `0` means *the default graph* (`read.odin:53`).
  `MATCH_DEFAULT_GRAPH` names the default graph deliberately. Say all of
  this in `query_init`'s doc comment; it is the contract.
- **Unscoped must be explicit, and empty must mean empty.** record treats
  `nil` and an empty slice identically — in Odin `make([]T, 0) == nil` is
  true (verified 2026-08-26) — so a set that *happens* to be empty (a
  leaf workspace's descendants, a user permitted nothing) would read the
  whole store. This engine should not inherit that ambiguity: take the
  set in a form that distinguishes "unscoped" from "scoped to nothing"
  (a `Maybe`, or an explicit flag), and make an empty scoped set yield
  **no solutions** by short-circuiting the reads itself, whatever record
  does with an empty slice. record's own fix is **`RECORD-T-0029`** (a
  stated `Graph_Scope` beside `Origin`, an API change with a tag), which
  is sequenced first; if it has landed, write this against the new
  `Filter` — `scope = .Set` on the set path, `.All` on the unscoped one
  — and the short-circuit is belt and braces. This engine is safe either
  way.
- **Ownership**: copy the ids into the query (a handful of `u32`s) rather
  than borrow the caller's slice for the query's lifetime — one fewer
  lifetime rule in the public contract.
- **What needs no change**, and should be pinned by tests rather than
  assumed:
  - `GRAPH ?g` enumeration (`graph_scan_next`, `exec.odin:988`) opens
    `match_open(MATCH_ALL)` and so ranges over **the set's** named graphs
    with no change.
  - `GRAPH <x> { … }` inside a scoped query: record intersects
    `Pattern.g` with the set, so a graph outside the ceiling yields
    nothing — not an error.
  - Constant resolution stays unscoped: terms are global on record, and
    an IRI's id is not a fact.
- **`FROM` / `FROM NAMED` are `SPARQL-T-0043`'s, not this task's.** That
  bug (P1, filed earlier) is about *honouring* dataset clauses per §13.2
  — `FROM <g>` makes `g` the query's default graph, `FROM NAMED <g>`
  restricts what `GRAPH ?g` ranges over. The two are different things
  and must stay different: a dataset clause is the **query's view** of
  the store, the set here is **what the query may read at all**. When
  `T-0043` is built, a clause is intersected with the ceiling and never
  widens it — `FROM <g>` for a `g` outside the set contributes nothing
  to the default graph, `FROM NAMED <h>` for an `h` outside it admits
  nothing, and neither is an error. Whichever lands first, the other
  must be written against it; this task settles only that the ceiling
  never comes from query text.
- **Planner**: `plan.odin:2115` prices patterns by `range_len` on the
  unfiltered window, so under a set every pattern is overestimated
  equally — harmless for correctness, mildly pessimistic for ordering.
  When `RECORD-T-0028` (a `GPOS` order) lands, a scoped `(P, O)` pattern
  can be priced per graph exactly; a follow-up, not this task.
- **Read counts**: the filter runs inside `scan_next`, so `candidates`
  (summed `range_len`) does not move and `next` drops where facts are
  excluded. Every existing pin passes `nil` and is unchanged.

## Acceptance Criteria

**[REQUIRED]**

- [x] `query_init` accepts a graph set of resident ids, with an explicit
      unscoped form; both read sites pass it; the doc comment states the
      contract above (same snapshot; drop misses; never `0`;
      `MATCH_DEFAULT_GRAPH` for the default graph; the set is a ceiling
      the query text cannot widen; dataset clauses are not affected).
- [x] A test with the default graph and two named graphs, set = one of
      them: a BGP sees that graph only; `GRAPH <other> { … }` inside the
      query yields nothing; `GRAPH ?g` binds only the set's graphs;
      `MATCH_DEFAULT_GRAPH` in the set admits the default graph.
- [x] An empty scoped set yields no solutions — pinned. *(Independent of
      the conflation because `RECORD-T-0029` removed it and this engine
      pins `v0.6.0`; no engine-side short-circuit was built — see the
      completion note.)*
- [x] 546/546 W3C entries and all `make test` tests unchanged with the
      unscoped form; read-count pins unchanged.
- [x] `make check`'s import-alias grep still clean; `record` only, no new
      collection.

## Implementation Notes

### Dependencies

- None hard. `Filter.graphs` has been on record's read API since
  `RECORD-I-0002`; the pinned `v0.4.0` suffices. `RECORD-T-0029` is
  sequenced ahead of this and changes `Filter`'s shape; if it lands
  first, this task bumps the pin and states scope at both read sites.
- Related, not required: `SPARQL-T-0043` (dataset clauses honoured —
  must intersect this ceiling, see Design); `RECORD-T-0028` (`GPOS`) for
  the scoped `(G, P, O)` shape to be a prefix rather than a residual
  scan; `SHACL-T-0039`, the same set on the validation side.

### Effort

S — the change is at one seam. The tests and the doc comment are most of
it.

## Status Updates **[REQUIRED]**

- **2026-08-26 — Filed** from the workspace design discussion with the
  owner, with agreement to file cross-repository. The finding: the
  engine has no way to receive a graph set, so the record's per-fact
  ceiling is unreachable from SPARQL today (the dataset clauses it also
  ignores were already `SPARQL-T-0043`). Not started.
- **2026-08-27 — `RECORD-T-0029` landed and `v0.5.0` is the pin
  (`SPARQL-T-0045`).** `record.Filter` now carries `scope: Graph_Scope`;
  the two read sites state `.All`. What this settles for the Design
  above: `query_init` takes `scope: record.Graph_Scope` and
  `graphs: []record.Term_ID` and passes them through — the record's own
  type is the unscoped/scoped distinction, so no `Maybe` or flag of this
  engine's is needed, and an empty `.Set` yields no solutions at the
  record; the engine-side short-circuit is belt and braces. Still not
  started.
- **2026-08-27, later — `v0.6.0` is the pin (`SPARQL-T-0046`)**: record's
  `GPOS` order makes a G-bound `(P, O)` pattern a prefix window, so the
  Design's "planner prices the unfiltered window" caveat is now exact
  per graph for such patterns, and a scoped read over `k` graphs can be
  `k` seeks. Still not started.
- **2026-08-27 — Active. Plan**, before code. `query_init` gains
  `scope: record.Graph_Scope = .All` and `graphs: []record.Term_ID = nil`
  — the record's own type is the unscoped/scoped distinction
  (`RECORD-T-0029`), `.All` as the default keeps every call site and
  today's behaviour, and the ids are **copied** into the query
  (`q.graphs`, freed by `query_destroy`) so the caller's slice has no
  lifetime rule. `Exec` carries one `record.Filter` built at
  `exec_init` and both read sites pass it; nothing else in the engine
  reads the store through anything but those two (`plan.odin:2115`
  prices with `range_len` on the unfiltered window, deliberately, and
  `snapshot_resolve` is unscoped because terms are global). No
  engine-side short-circuit for an empty set: at the pinned record an
  empty `.Set` admits nothing, and a second mechanism for one rule is
  a divergence waiting to happen — the test pins the record's
  guarantee through this API instead. The test kit's `test_solve` gains
  the same two optional parameters so a new `scope_test.odin` can drive
  the cases: a BGP under a one-graph set sees that graph only; `GRAPH
  <other>` inside yields nothing; `GRAPH ?g` binds only the set's
  graphs; `MATCH_DEFAULT_GRAPH` in the set admits the default graph; an
  empty `.Set` yields no solutions; `.All` is today's answer. README's
  contract bullets and the vision get the new parameter; `SPARQL-T-0043`
  is told the ceiling it must intersect now has a name.
- **2026-08-27 — Done.** `query_init(q, algebra, snapshot, base, scope,
  graphs, allocator)`: `scope := record.Graph_Scope.All`, `graphs:
  []record.Term_ID = nil`; under `.Set` the ids are copied into
  `q.graphs` once preparation cannot fail, freed by `query_destroy`.
  `Exec.filter` is one `record.Filter{origin = .Any, scope, graphs}`
  built at `exec_init` and passed at both read sites — `match_open`
  and `match_open_as` — so every read the executor makes carries the
  ceiling, and `graph_scan_next` (`GRAPH ?g`) inherits it through
  `match_open(MATCH_ALL)` as predicted. `plan.odin:2115` still prices
  on the unfiltered window, deliberately.

  **Decided against the engine-side short-circuit for an empty set.**
  The task was written when record conflated `nil` with empty; at the
  pinned `v0.6.0` an empty `.Set` admits nothing per fact, and a second
  mechanism for the same rule in this engine would be one more place
  for the two to disagree. `test_scope_empty_set_is_empty` pins the
  record's guarantee *through this API* — with `nil` under `.Set`, and
  with a set built from a label the store has never seen, which
  resolves to nothing and leaves a non-nil empty buffer behind it.

  Six tests in `sparql/scope_test.odin`, driven through the test kit's
  `test_solve` (which gained the two parameters, after `loc` so no
  positional caller moved): `.All` is today's answer; `GRAPH ?g` ranges
  over the set's named graphs and the default graph in the set adds
  nothing to it; `GRAPH <gb>` under `{ga}` yields nothing and under
  `{ga, gb}` answers; a plain pattern under `{ga}` yields nothing and
  under `{default, ga}` answers; the empty set is empty; and the set is
  copied (the caller's slice is overwritten after `query_init` and the
  answer does not move). One finding: four `tests/guards` sites passed
  `allocator` positionally as the fifth argument, which the new
  parameters shift — named now, and a reminder that `query_init`'s
  trailing defaults are positional to anyone who counts.

  `make check` clean; `make test` green — 202 tests in the package (196
  + 6), guards 9, harness 73, readme 3, the W3C survey unchanged;
  `make bench` passes with every read-count pin unmoved, since every
  existing caller is `.All`. README's contract bullets carry the
  parameter; the vision's Current State is amended; `SPARQL-T-0043`
  knows the ceiling it intersects. Not tagged: `v0.2.0` stays the
  release and whether this warrants one is the owner's call — no
  consumer pins this engine.