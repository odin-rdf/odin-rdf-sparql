---
id: store-evidence-proposals-and
level: task
title: "Store-evidence proposals and public API documentation"
short_code: "SPARQL-T-0019"
created_at: 2026-08-05T15:15:44.553410+00:00
updated_at: 2026-08-05T22:56:40.650778+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Store-evidence proposals and public API documentation

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Close the initiative: consolidate the store-evidence log accumulated across every evaluation task into concrete, evidence-backed upstream proposals for odin-rdf-store's planner-support revision (snapshot API, ordered iteration, cardinality estimates — the STORE-I-0002/STORE-A-0002 review triggers), and document the public evaluation API to the family's contract standard.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Store-evidence log consolidated: each entry names the operator/query shape that wants the capability and what it would buy (e.g. ordered match → merge joins and streaming DISTINCT/MIN/MAX; cardinality estimates → join-order planning at the T-0011 seam; snapshot API → one-query-one-snapshot read model; term enumeration → both-free path reachability). Filed as one or more backlog items/ADR drafts in odin-rdf-store's Metis, in the STORE-T-0014 pattern. — seven items, STORE-T-0015 … STORE-T-0021, plus a Review Log in STORE-A-0002 discharging its first review trigger.
- [x] Public API documented to the family standard: package doc with the memory/lifetime contract (query text, algebra, solution rows, materialized terms — who owns what until when), every exported symbol documented, allocator discipline stated.
- [x] README updated with a compiled query-evaluation example (parse → evaluate against memstore → iterate solutions) covered by a README-as-contract test, matching the SPARQL-T-0009 convention.
- [x] Initiative exit criteria verified and recorded: all in-scope 1.1 evaluation directories green with pinned counts, both backends, both widths; 1.2 state per T-0018; the verification run documented in the initiative's status log. — verified and recorded; the run found five open entries in five otherwise-green directories, which needs a scope decision at initiative level (see the log below and SPARQL-I-0002's).

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
The evidence log should have been appended throughout (each task's notes call out their entries); this task edits it into upstream-consumable proposals rather than reconstructing from memory. API docs follow the documented-contract style audited in SPARQL-I-0001's design phase.

### Dependencies
All prior tasks (SPARQL-T-0010 … T-0018).

### Risk Considerations
None technical; the risk is evidence loss if earlier tasks skip their log entries — each prior task's implementation notes flag what to record, and this task's first step is auditing the log against the enabled-suite history.

## Status Updates **[REQUIRED]**

### 2026-08-05 — Complete. `make test` green at both widths, `make check` clean.

**1. The store-evidence log, consolidated.** Audited against the source
rather than reconstructed from memory: seven in-code markers
(`grep -rn "SPARQL-T-0019" sparql/`) plus the entries T-0011, T-0013,
T-0015, T-0016, and T-0018 recorded in their logs. Each became a backlog
item in odin-rdf-store's Metis, in the STORE-T-0014 pattern — evidence
first, then the ask, then acceptance criteria a store session can work
from:

| Item | Capability | Asked for by | P |
|---|---|---|---|
| STORE-T-0015 | Ordered match iteration, and range reads over it | MIN/MAX (a full pass for two ends of an order the store has), ORDER BY (blocking today), top-N, merge joins, streaming DISTINCT | P1 |
| STORE-T-0016 | The named-graph list, and the terms a graph holds | `Plan_Graph_Scan` and `path_collect_nodes`, each scanning the whole dataset to rebuild a set the indexes already have | P1 |
| STORE-T-0017 | A named-graph wildcard in the graph position | every `GRAPH ?g { … }`: the interface's wildcard spans the default graph, so the engine over-fetches and filters in `unify_quad` | P2 |
| STORE-T-0018 | Cardinality estimates for a pattern | `join_order` — the planner seam, built and deliberately empty | P2 |
| STORE-T-0019 | Snapshot reads: one query, one dataset | all five of a query's read paths, none of which can see the same dataset today | P2 |
| STORE-T-0020 | `triple_parts`: a triple term's component IDs | SPARQL 1.2 triple-term patterns; memstore answers from an array, kvstore materializes and re-finds | P3 |
| STORE-T-0021 | Reserving the Sentinel counters above UNBOUND | the engine's query-local term names, which currently squat on an unassigned range | P2 |

Also appended a **Review Log** to STORE-A-0002 discharging its first
review trigger ("odin-rdf-sparql's basic graph pattern evaluation lands
and demonstrates needs the convention cannot absorb"): the convention
absorbed a whole query engine without an adapter and without a revision,
and every one of the seven items *extends* the procedure set rather than
changing the convention — which is what that ADR's Consequences already
predicted. odin-rdf-store's working tree now carries eight new/edited
Metis files, uncommitted, for a store session to pick up.

**2. The public API, documented.** `sparql`'s package doc gained two
sections that did not exist: **the memory contract** — query text is the
caller's, the algebra is the parser's (so the parser outlives the query),
a solution row is valid until the next pull, a materialized term until
`query_destroy` on both backends, and a Result_Graph is the caller's —
and **allocator discipline**, including the per-solution
zero-allocation promise and its three stated exceptions (DISTINCT, the
blocking operators, the §17 string functions). It also gained a worked
"using it" sketch for both halves.

Every exported symbol in `sparql`, `sparql/memstore`, and
`sparql/kvstore` now carries a doc comment. The audit was mechanical —
the code index lists exported symbols with and without descriptions —
and the gaps were the ones you would expect: the `*_destroy` procedures,
where the *contract* lives (what is freed, what is not, and what becomes
invalid), and the value model's constructors and constants.

**3. The README** now documents an engine rather than a parser: the
headline numbers are measured (352 syntax tests, 483 evaluation tests
across 35 directories, both backends, both widths — the old "342" was
stale), `sparql/memstore` and `sparql/kvstore` are in the packages table,
the memory model has an evaluator half, and there is a second worked
example — load Turtle into memstore, parse, translate, prepare, iterate
solutions, materialize terms. Both examples are compiled and asserted by
`tests/readme` (2 tests), so neither can drift.

**4. Initiative exit criteria: verified, recorded, and one needs a
decision.** Written up in full in SPARQL-I-0002's status log. Criteria 2
(1.2 suites), 3 (store proposals), and 4 (API docs) are met. Criterion 1
is met for 35 of the 40 vendored evaluation directories — 483 of 488
entries, 99.0% — and the five open entries fall into three causes, only
one of which is this engine's:

- `graph-optional` and `graph-minus`: GRAPH scoping for an operator that
  sees more than one solution at a time. Filed as **SPARQL-T-0020**.
- `dawg-lang-3` and `normalization-2`: term identity — language-tag case
  and IRI normalization — which is the family's question and has to hold
  for the RDF parser, both store dictionaries, and the SPARQL parser at
  once. Filed as **SPARQL-T-0021**.
- `sq11`: an RDF/XML data document, which odin-rdf-parser does not
  implement.

`tests/w3c/README.md`'s near-miss section was rewritten to cover all five
(it had three) with the cause and the item each waits on.

The recommendation to review is to re-scope criterion 1 around the five
recorded entries and close the initiative: two of the three causes
belong to other repos, and the third is a characterized backlog item
rather than an unfinished part of the build. That call is the human's,
which is why the initiative log states it as a decision rather than
making it.

**Not done, deliberately.** No visibility changes: a number of `sparql`
symbols are exported only because the instantiation packages are
separate packages, and narrowing them to `@(private)` is a refactor with
its own risk, not documentation. They are documented as what they are.

### 2026-08-25 — the evidence log, answered by a different store (SPARQL-T-0035)

This task's central artefact was the store-evidence log above: seven
capabilities this engine had demonstrated a need for, filed into
odin-rdf-store's backlog as STORE-T-0015..0021. **The engine has since
been ported off odin-rdf-store onto odin-rdf-record (SPARQL-I-0003), and
odin-rdf-store is to be retired**, so the log is worth closing out here
rather than left pointing at a repository nobody will act in.

Two of the seven were answered, and the difference between how is the
interesting part:

- **STORE-T-0020 — `triple_parts`.** Asked for because a non-ground
  triple-term pattern had to take a stored term apart, and kvstore could
  only do that by materializing the whole term and re-resolving each of
  its three components: two round trips through the database for
  something the dictionary knew outright. odin-rdf-record answered it as
  **`snapshot_triple_parts`** (RECORD-I-0004): the component ids are *in*
  the encoding, so taking a triple term apart is a tag check and three
  reads out of the arena — no allocation, no decode, no recursion. The
  engine consumes it at one site, `exec_triple_parts` in
  `sparql/exec.odin`, and the four-round-trip adapter it replaced is
  deleted. **It cost this repository nothing**: the capability arrived in
  the encoding rather than as an API this engine had to adapt to.
- **STORE-T-0021 — reserving an id range for the engine's query-local
  term names.** Asked for after the engine's synthetic ids, which had
  squatted on an unassigned sentinel range, collided with `NAMED_GRAPHS`
  when the store took the next counter. odin-rdf-store reserved a range
  in `v0.5.0`; **odin-rdf-record reserved one from the start and by
  name** — `CONSUMER_ID_FIRST ..= CONSUMER_ID_LAST`, stated in its
  `api.md` par. 3 *for a query engine's computed values*, with the store's
  own procedures neither accepting nor checking for one. See
  `SYNTHETIC_FIRST` in `sparql/expr_eval.odin`, where the constant is now
  the record's rather than this engine's guess at where the record's ids
  stop.

The other five were never built in odin-rdf-store and are not asks
against odin-rdf-record today. Two of them changed character with the
port and are recorded where they now live: **STORE-T-0017** (a
named-graph wildcard) has no record equivalent either — an unbound `G`
spans the default graph and `Filter.graphs` takes a set of names rather
than a class — so `unify_quad` still over-fetches and filters, with the
comment there re-aimed; and **STORE-T-0015/0018** (ordered iteration and
cardinality estimates, the planner surface) are what SPARQL-T-0037 and
SPARQL-T-0038 consume from record's `snapshot_match_as` and `range_len`,
which exist. *(Corrected 2026-08-25 by those two tasks' outcomes, which
were not yet known when this was written: **only one of the pair was
consumable.** `range_len` was — an exact O(1) count, better than the
estimate STORE-T-0018 asked for, and `join_order` orders a BGP with it.
`snapshot_match_as` exists and **cannot be used**: record's id order is
not SPARQL's `ORDER BY` order, and no plan can establish when the two
agree, so STORE-T-0015's capability is available here and inert. That
is SPARQL-T-0038, closed as evidence.)* **STORE-T-0016** (the graph list and a graph's terms) and
**STORE-T-0019** (snapshot reads) were both built in odin-rdf-store
(`graphs`/`nodes`, and the transactions this engine adopted in
SPARQL-T-0024); on record, a snapshot *is* the dataset, and there is no
graph list — `Plan_Graph_Scan` still scans.

*(This amendment is SPARQL-T-0035's last criterion. The task it belongs
to is complete; the log it closes is this one.)*
