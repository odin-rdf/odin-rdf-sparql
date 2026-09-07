---
id: describe-reads-the-default-graph
level: task
title: "DESCRIBE reads the default graph only, so it answers nothing in a named-graph dataset"
short_code: "SPARQL-T-0054"
created_at: 2026-09-07T21:29:49.374369+00:00
updated_at: 2026-09-07T21:29:49.374369+00:00
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

# DESCRIBE reads the default graph only, so it answers nothing in a named-graph dataset

## Objective **[REQUIRED]**

`exec_describe` matches `{subject, WILDCARD, WILDCARD, DEFAULT_GRAPH}`, so
a `DESCRIBE` answers triples of the default graph and of no other. In a
dataset where every quad is in a named graph and the default graph is
empty -- which is what a store provisioned one document per graph looks
like -- every `DESCRIBE` parses, plans, runs and answers an empty graph.

The form is not refused and reports nothing, so the consumer sees an empty
result and cannot tell it apart from "this resource has no description".
That is the one wrong conclusion available from the answer.

`odin-rdf-app` puts every fact in a named graph -- the graph is the unit of
provenance and of read scope there, and nothing is ever written to the
default one -- so `DESCRIBE` is unusable for it as it stands. It works
around this with `CONSTRUCT` and an explicit `GRAPH` pattern, which is a
correct answer to a different question.

Note the asymmetry with the rest of the engine: `query_init` already takes
`scope` and `graphs` (`SPARQL-T-0044`), every read the executor makes
carries them as `record.Filter`, and `GRAPH ?g` ranges over exactly that
set. `DESCRIBE` is the one place that reaches past the parameter to a
constant.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Bug - Production issue that needs fixing

### Priority
- [ ] P0 - Critical
- [x] P1 - High (important for user experience)

### Impact Assessment **[CONDITIONAL: Bug]**
- **Affected Users**: every consumer whose dataset lives in named graphs.
  `sparql10-describe`'s vendored entries use the default graph, so the
  suite does not see it.
- **Reproduction Steps**:
  1. Provision a store with one document in one named graph -- say
     `<http://example.org/g>` holding `<http://example.org/s> rdfs:label "x"`
     -- and nothing in the default graph.
  2. Prepare and run `DESCRIBE <http://example.org/s>`, with
     `scope = .Set` over that graph or with the default `.All`; the answer
     is the same either way.
  3. `result_graph_triples` is empty.
- **Expected vs Actual**: expected the resource's triples from the graphs
  the query may read; got an empty graph, with nothing said about why.

## Acceptance Criteria **[REQUIRED]**

- [ ] `DESCRIBE` answers a resource's triples from the graphs in the
      query's scope, the default graph included, rather than from the
      default graph alone.
- [ ] Under `scope = .Set` the answer holds nothing from a graph outside
      the set -- the ceiling `SPARQL-T-0044` established is not widened by
      this form.
- [ ] A test over a named-graph-only dataset: `DESCRIBE <s>` answers the
      triples of `<s>`, and a second graph outside the scope contributes
      none of them.
- [ ] The vendored `sparql10-describe` entries stay green, since a dataset
      whose triples are in the default graph is the same answer either
      way.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
`exec_describe` builds its pattern with `DEFAULT_GRAPH` as the graph-side
constant. The rest of the executor reaches the store through `match_open`
with the query's filter already attached; describing through the same path
with a wildcard graph would inherit the scope rather than restate it.

Whether a resource described from several graphs should answer duplicate
triples once is the `Result_Graph`'s question, and `result_graph_add`
already dedups.

### Dependencies
None. `SPARQL-T-0044` is the parameter this would honour.

## Status Updates **[REQUIRED]**

### 2026-09-07 -- filed
Filed from `odin-rdf-app`, found while putting the four query forms behind
one caller-facing API. The consumer ships `DESCRIBE` accepted rather than
refused, with a note on the empty answer saying why it is empty and what
to use instead -- so the day this lands, its answer improves with no
change on the consumer's side.
