---
id: result-forms-ask-construct
level: task
title: "Result forms: ASK, CONSTRUCT instantiation, minimal DESCRIBE"
short_code: "SPARQL-T-0017"
created_at: 2026-08-05T15:15:42.340585+00:00
updated_at: 2026-08-05T21:44:45.820102+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Result forms: ASK, CONSTRUCT instantiation, minimal DESCRIBE

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The non-SELECT result forms as evaluated structures (serialization stays out of scope per the initiative): ASK returning a boolean; CONSTRUCT instantiating its template per solution into an in-memory graph — fresh blank nodes per solution scope, ground-term templates, dropping of invalid triples (unbound variables, literal subjects), set semantics on the output graph; and minimal spec-conformant DESCRIBE (implementation-defined projection — document the chosen form, e.g. outgoing triples of the described resources).

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] ASK evaluates to a boolean; harness compares against SRX/SRJ boolean expected results. — already true: SPARQL-T-0012 pulled ASK forward because the operator suites state their expectations as ASK queries, and `sparql10-ask` has been green since. An ASK answer is read off the solution stream — it is a SELECT nobody looks at.
- [x] CONSTRUCT: template instantiation per §16.2 — per-solution blank-node relabeling, solutions with unbound template variables produce no triple for that pattern (not an error), duplicate triples deduplicated; output is a set of `rdf.Triple`/quads over materialized terms. — `sparql/construct.odin`; each rule has a named case in `sparql/memstore/forms_test.odin` rather than being left to the suites to imply.
- [x] CONSTRUCT expected-result comparison via graph isomorphism against the vendored `.ttl` expected graphs. — the harness already had `graphs_isomorphic` and a `.ttl` reader that falls back to a plain graph; both were unused until now.
- [x] DESCRIBE: documented minimal semantics; returns a graph; no suite dependency (W3C evaluation suites do not pin DESCRIBE output — verify at vendoring and record in the harness README). — every triple of the default graph whose subject is a described resource, and nothing else. The no-suite-dependency claim is **measured**: the vendored corpus has no `qt:QueryDescribe` entry and no DESCRIBE query at all.
- [x] ask and construct evaluation directories enabled and fully green; dual-width matrix green. — `sparql10-construct` (5) and `sparql11-construct` (5), both backends, 64 and 32 bits.
- [x] Result-graph ownership contract documented (caller-owned via stated allocator, family convention). — stated in `construct.odin`'s header and in each backend's `query_construct`, asserted by `test_construct_graph_outlives_its_store`, and leak-checked by `test_result_graph_no_leaks`.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
CONSTRUCT materializes solution bindings through the dictionary once per solution, instantiates template triples, and inserts into a small in-repo triple set (hash on terms). This is also the future path for the CONSTRUCT round-trip criterion (emit via odin-rdf-parser, re-parse, isomorphic) — that criterion completes in the later serialization initiative; here the graph comparison in tests stands in for it.

### Dependencies
SPARQL-T-0011 (evaluation core); most construct suite entries exercise only basic patterns, some need T-0012/T-0013 — enablement follows.

### Risk Considerations
Blank-node scoping in CONSTRUCT templates (per-solution freshness, template labels vs. query bnodes) is the main correctness trap; the isomorphism comparison hides label choices but not scoping errors.

## Status Updates **[REQUIRED]**

### Done

`sparql10-construct` (5) and `sparql11-construct` (5) are enabled and green
against both backends at both `Term_ID` widths. `make check` clean; `make test`
clean at 64 and 32 bits.

**Survey diff, directory by directory.** Three lines moved, none backwards:
`sparql10-construct` 0 → 5, `sparql11-construct` 0 → 5, and — unplanned —
`sparql11-subquery` 2 pass / 2 unsupported → **4 pass / 0 unsupported**, because
two of its entries are CONSTRUCT queries. That directory now waits on one thing
only: `sq11`'s data document is RDF/XML, which the family's parser does not
implement. Recorded in the harness README as the third near miss.

**How much was already there.** The harness had the graph half built and unused:
`Result_Kind.Graph`, `result_set_add_triple`, `graphs_isomorphic`, and a `.ttl`
reader that already falls back to "a plain graph" when the file carries no
`rs:ResultSet`. So the work was the engine side plus routing, not a new
comparison. ASK likewise needed nothing — SPARQL-T-0012 pulled it forward
because the operator suites state their expectations as ASK queries.

**The engine side** is `sparql/construct.odin`, deliberately not generic over
the backend:

- `Template` compiles the parsed template against a *prepared* query's slot
  table. That order matters: a template variable is looked *up*, never assigned,
  because the solution row's width is already fixed by then. A variable the
  pattern never binds makes its triple unproducible in every solution, so the
  triple is dropped once at compile time rather than reconsidered per solution.
- Template blank nodes are indices, not names — a label in a template names a
  different node in every solution, so the compiled form keeps which label, not
  what it was called.
- `Term_Resolver` is a procedure value. Resolving an ID to a term is precisely
  where the two backends differ, and instantiating a template is not a hot path.

**Ownership**, the criterion easiest to satisfy wrongly: a `Result_Graph`
deep-copies every term into the allocator it was made with. Both backends'
natural answers are unusable directly — memstore's terms borrow the dictionary,
kvstore's are owned by the query — so a graph that borrowed either would dangle
in one backend and double-free in the other. Copying once at the boundary makes
the answer independent of the store, which is what a caller wants anyway.
`test_construct_graph_outlives_its_store` destroys the query, the parser, the
dataset and the dictionary, *then* reads the graph.

**One real bug, caught by exactly one test.** `construct_solution` wrote its
fresh blank-node labels into a single scratch buffer shared by a triple's three
positions, so `_:a rdf:rest _:b` came out as `_:b rdf:rest _:b` — the subject
was a slice of a buffer the object had since overwritten. Nine of the ten
CONSTRUCT entries passed anyway; `constructlist`, whose template is the
collection `(?s ?o)` and therefore the only one with two blank nodes in one
triple, did not. One buffer per position now, with the reason written down.

**DESCRIBE**: §16.4 leaves the content to the implementation, and this engine
answers with every triple of the query's default graph whose subject is a
described resource — nothing else, no blank-node closure, no incoming triples.
The "no suite dependency" claim is measured, not assumed: the vendored corpus
has no `qt:QueryDescribe` entry and no DESCRIBE query at all, so
`sparql/memstore/forms_test.odin` is the only place the behaviour is stated, and
the harness README now says so.

**Tests.** Eleven cases in `sparql/memstore/forms_test.odin`: set semantics, the
unbound-position drop, a template variable the pattern never binds, blank-node
freshness *across* solutions and sharing *within* one (the second is what makes
a collection template a list rather than loose cells), triples RDF does not
admit, the ownership contract, and four DESCRIBE cases. A new guard,
`test_result_graph_no_leaks`, runs eight CONSTRUCT/DESCRIBE cycles under a
tracking allocator and requires the count back to zero — three owned structures
the solution path does not have, each with its own lifetime.

**Carried from SPARQL-T-0016**: that task enabled `sparql11-property-path` but
left the harness README's enabled table a task behind. Added here along with the
two construct rows; the total is now **435 evaluation tests across thirty-one
directories**.