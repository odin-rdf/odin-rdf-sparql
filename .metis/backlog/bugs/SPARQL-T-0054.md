---
id: describe-reads-the-default-graph
level: task
title: "DESCRIBE reads the default graph only, so it answers nothing in a named-graph dataset"
short_code: "SPARQL-T-0054"
created_at: 2026-09-07T21:29:49.374369+00:00
updated_at: 2026-09-07T23:35:51.423249+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/completed"


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

## Acceptance Criteria

**[REQUIRED]**

- [x] `DESCRIBE` answers a resource's triples from the graphs in the
      query's scope, the default graph included, rather than from the
      default graph alone.
- [x] Under `scope = .Set` the answer holds nothing from a graph outside
      the set -- the ceiling `SPARQL-T-0044` established is not widened by
      this form.
- [x] A test over a named-graph-only dataset: `DESCRIBE <s>` answers the
      triples of `<s>`, and a second graph outside the scope contributes
      none of them.
- [ ] ~~The vendored `sparql10-describe` entries stay green~~ -- **there
      are none.** Measured rather than assumed: no `sparql10-describe`
      directory is vendored, no manifest entry is a `qt:QueryDescribe`,
      and not one of the 850 vendored `.rq` files contains the keyword.
      `tests/w3c/README.md` had already recorded this in its *What
      DESCRIBE returns* section and the item was filed against a suite
      that does not exist here. The criterion's *substance* is met by the
      four default-graph cases in `sparql/forms_test.odin`, which are
      unchanged and green -- see the status update.

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

### 2026-09-08 -- fixed

**One constant became a wildcard.** `exec_describe` built its pattern as
`{subject, WILDCARD, WILDCARD, DEFAULT_GRAPH}`; it now builds
`{subject, WILDCARD, WILDCARD, WILDCARD}` and nothing else about the
procedure changed. That is the whole of the behaviour fix, and it is the
implementation note's approach taken as written: the read already goes
through `match_open`, which attaches the query's `record.Filter`, so a
wildcard in the graph position inherits `query_init`'s `scope` and
`graphs` instead of restating a graph of its own. The asymmetry the item
named is gone -- `DESCRIBE` now reads through exactly the seam a join,
a `COUNT` and a `NOT EXISTS` read through.

`make check` clean, `make test` green at **310 tests** (sparql 211, srj
6, srx 7, guards 9, W3C harness 73, readme 4 -- sparql was 207), `make
bench` all assertions passed with **every read-count pin unmoved**. The
pins could not move: with S bound, `choose_order` was never going to
pick the G-leading permutation, so the old pattern and the new one open
the same S-prefixed window and `range_len` counts the same candidates.
What changed is one residual component check per candidate, which is
cheaper, not dearer.

#### How the ceiling was held, and how that is tested

Under `.Set`, record's `scan_next` requires a candidate's stored G to be
in the set (`read.odin`, the `sc.scoped` branch), and the default graph
is in it only when the caller put `MATCH_DEFAULT_GRAPH` there. So the
wildcard widens the *pattern* and not the *ceiling*: `.All` describes
from every graph, `.Set` from the set and no graph outside it, and an
empty `.Set` describes nothing. Nothing in `exec_describe` decides any
of that, which is the point -- the parameter decides, in one place,
below every operator.

That is asserted rather than argued. `sparql/forms_test.odin` gains four
cases over a fixture of two named graphs and a default graph, each
holding a triple of `:x`, with one triple asserted in both named graphs:

  - `test_describe_reads_every_graph_when_unscoped` -- the filed case, a
    named-graph-only dataset under `.All`: three triples, and the
    doubly-asserted one answered once. `result_graph_add`'s dedup was
    confirmed rather than rebuilt, as the item said it would be.
  - `test_describe_is_confined_to_the_graph_set` -- `.Set{ga}` over all
    three graphs: `gb` and the default graph each hold a triple of `:x`
    and neither contributes one.
  - `test_describe_reads_the_default_graph_when_the_set_names_it` --
    `.Set{default, gb}`: the default graph is read because the set says
    so, and `ga` is not.
  - `test_describe_under_an_empty_set_describes_nothing` -- the ceiling
    at its tightest, and the case that fails loudest if the wildcard
    ever escapes the filter.

**Both directions were checked by mutation, not by inspection.** Reverting
the one line to `DEFAULT_GRAPH` fails the first three with 0, 0 and 1
triple against 3, 2 and 3 -- the filed reproduction, exactly. Replacing
`match_open` with an unfiltered `range_iter` fails the last three with 4
triples each. The four pre-existing default-graph cases pass under both
mutations, which is the concrete content of the vendored-suite criterion:
for a dataset in the default graph the two answers coincide.

#### The one decision this had to take

**What "the graphs in the query's scope" means under `.All`, since the
item's two clauses could be read as pulling apart.** The reproduction
says the answer is empty "with `scope = .Set` over that graph or with the
default `.All`", so both are the bug; but a narrow fix that widened only
`.Set` and left `.All` on the default graph was available, and would have
kept today's answer for every existing caller. **Rejected.** It fixes the
lesser half of the filed case -- a consumer that has not adopted the
graph set at all still describes nothing -- and it makes the form's
answer depend on the scope in a way no other read does: `.All` means
*unscoped*, not *the default graph*, everywhere else in the engine. One
rule, stated once, in the parameter: what a DESCRIBE reads is what the
query may read.

The cost is honest and is recorded here rather than left to be
discovered: **for a dataset with facts in both the default graph and
named graphs, an unscoped DESCRIBE now answers more triples than it did.**
That is a behaviour change to a query form, not a bug fix that leaves
every existing answer alone. It is defensible because §16.4 leaves
DESCRIBE's content to the implementation and because the old answer was
not a defensible reading of "describe this resource" in a dataset the
engine could see the rest of -- but a consumer that relied on
default-graph-only descriptions gets a different graph back, and its
lever is `scope = .Set` with `MATCH_DEFAULT_GRAPH` alone, which restores
the old answer exactly. Documented in three places rather than one:
`Describe_Targets`'s contract comment (which is where the form's answer
has always been stated), `README.md`, and a dated amendment to
`tests/w3c/README.md`'s *What DESCRIBE returns*.

#### Found along the way

  - **The item's fourth criterion names a suite this repository does not
    vendor.** See the criterion itself. Nothing was adjusted to make it
    pass and nothing needed to be; it is struck rather than checked, so
    the record does not claim a suite ran.
  - **`SPARQL-T-0055` was not touched.** `exec_describe` sits in the same
    file as the plan re-entry the item describes and shares `match_next`
    with it, but nothing here reads or writes `node.started`, and
    `query_describe`'s own loop is the `for { ... if !more { break } }`
    shape T-0055 says is the one that works. Whether `node_reset` may
    restart a finished sub-plan is still open and still its own decision.
  - **`run_form` in `sparql/forms_test.odin` grew a graph-and-scope
    shape** (`Form_Doc`, plus `scope` and `labels` parameters), which
    every pre-existing caller passes as one unnamed document under
    `.All` -- `query_init`'s own default. Not one existing assertion
    changed.