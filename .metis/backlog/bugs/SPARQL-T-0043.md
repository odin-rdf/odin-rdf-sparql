---
id: a-dataset-clause-is-parsed-and
level: task
title: "A dataset clause is parsed and then ignored"
short_code: "SPARQL-T-0043"
created_at: 2026-08-25T18:18:40.071960+00:00
updated_at: 2026-08-25T18:18:40.071960+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#bug"


exit_criteria_met: false
initiative_id: NULL
---

# A dataset clause is parsed and then ignored

## Objective

`FROM` and `FROM NAMED` parse, land in `Parsed_Query.datasets`, and are
read by nothing. §13.2 says the dataset clauses *construct the dataset the
query is evaluated against* — `FROM <g>` merges g into the default graph,
`FROM NAMED <g>` admits g to the named graphs — so a query carrying them
today is answered against a dataset it did not ask for, silently and with
no diagnostic. Honour them, or refuse them.

## Backlog Item Details

### Type
- [x] Bug - Production issue that needs fixing

### Priority
- [x] P1 - High (important for user experience)

### Impact Assessment

- **Affected Users**: every consumer whose store keeps its data in named
  graphs and nothing in the default one — which is what
  `record:record/ingest` produces for a document loaded under a graph
  label, and what odin-rdf-app's seeder does ("the seeder puts every
  document in a named graph and nothing at all in the default one",
  `src/main.odin`). For those, a `FROM` query answers **zero rows** and
  looks like a data problem.

- **Reproduction Steps**: self-contained — one document in one named
  graph, then four queries against one snapshot of it. Run as written on
  `record.Mem_FS` / `record.mem_file_ops`, so it needs no directory and
  belongs in `tests/` as it stands.

  ```odin
  DATA :: `<http://example/a> <http://example/p> "x" , "y" .`
  ops, _ := ingest.turtle(transmute([]byte)string(DATA),
      rdf.IRI("http://example/g"), context.allocator, blank_prefix = "r_")
  record.apply(&db, {ops = ops})
  ```

  | # | query | rows | expected |
  |---|---|---|---|
  | 1 | `SELECT ?o WHERE { <http://example/a> <http://example/p> ?o }` | 0 | 0 — the default graph is empty |
  | 2 | `SELECT ?o FROM <http://example/g> WHERE { <http://example/a> <http://example/p> ?o }` | **0** | **2** |
  | 3 | `SELECT ?o WHERE { GRAPH ?g { <http://example/a> <http://example/p> ?o } }` | 2 | 2 |
  | 4 | `SELECT ?o WHERE { GRAPH <http://example/g> { <http://example/a> <http://example/p> ?o } }` | 2 | 2 |

  Those four counts are observed, not predicted. (2) and (4) name the
  same graph and must answer alike; they do not, and (2) is the one
  §13.2 pins. It reproduces the same way at scale: against a real
  multi-document store, every listing that says `FROM` answers nothing
  and the same listing rewritten with `GRAPH` answers.

- **Expected vs Actual**: (2) should answer the same two literals as (4)
  — `FROM <g>` makes g *the* default graph for that query. It answers
  nothing, because `q.datasets` is written by `parse_dataset_clauses` and
  read by no other file: `grep -n datasets sparql/*.odin` reaches
  `ast.odin` (the field and its `delete`) and `parser.odin` (the append)
  and stops. Translation, planning and execution never see it.

## Acceptance Criteria

- [ ] `FROM <g>` evaluates the query's default-graph patterns against the
  RDF merge of the named graphs, per §13.2: repro query (2) answers two.
- [ ] Several `FROM` clauses merge — the merge is of all of them, and a
  triple in two of them answers once.
- [ ] `FROM NAMED <g>` restricts what `GRAPH ?g` ranges over to the
  clauses named; `GRAPH <h>` for an h not admitted answers nothing.
- [ ] A query carrying both is the §13.2 combination, and a query
  carrying neither keeps today's behaviour exactly (the stored default
  graph, every named graph) — no suite in `tests/w3c` moves.
- [ ] A `FROM` naming a graph the store has never seen is an empty
  contribution and not an error (§13.2 gives no fault for it).
- [ ] Whatever is *not* implemented is refused rather than ignored:
  `query_init` returns false with `q.unsupported` naming the clause, the
  way an unimplemented operator already does.
- [ ] The W3C suites that carry dataset clauses are enabled, or the
  reason they are not is written in `tests/w3c/README.md`.

## Implementation Notes

### Technical Approach

The read seam already takes a graph: `Plan_Pattern` carries the pattern's
G — a graph IRI inside a `GRAPH` clause, `record.MATCH_DEFAULT_GRAPH`
outside one (`plan.odin`, "and a pattern outside it still means the
default graph"). So the shape of the fix is to compile the dataset
clauses into what that field means:

- **FROM**: the default-graph patterns become a union over the named
  graphs of the merge, with duplicate solutions eliminated — the merge is
  a *set* of triples, so the same triple in two graphs must answer once,
  which a plain union does not give on its own.
- **FROM NAMED**: `graph_scan_next`'s enumeration is filtered to the
  admitted set, and a ground `GRAPH <h>` outside it is compiled as
  "matches nothing" the way an unresolvable ground term already is.

`record.Filter` carries a `graphs` list, which is the cheaper way to say
both if it can be reached from the plan — worth pricing against the union
before building the union.

### Risk Considerations

The bug is a silent wrong answer rather than a crash, so the risk of the
*fix* is the mirror image: a consumer that has written `FROM` into a query
and worked around the zero rows (by wrapping everything in `GRAPH ?g`)
will see its answers change. That argues for landing it with the refusal
path first if the full semantics cannot be built in one go — a
`q.unsupported` is a diagnostic, and today's silence is not.

## Status Updates

### 2026-08-25 — filed from a consumer's port

Found by odin-rdf-app while moving its read side off hand-written
`record` walks and onto this engine: it keeps its vocabulary and its data
in named graphs, so every query it writes has to say `GRAPH ?g { … }` and
a multi-graph scope has to become `FILTER(?g IN (…))` — the two-line
`FROM` prologue the spec offers is inert. Reduced to the four queries
above, which need no data but their own.

Not a blocker there: `GRAPH ?g` answers the same question. It is filed
because the silent disagreement between (2) and (4) is the kind that
costs an afternoon, and because the workaround is what a consumer has to
keep writing until this lands.
