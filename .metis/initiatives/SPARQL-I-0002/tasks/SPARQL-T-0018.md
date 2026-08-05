---
id: sparql-1-2-evaluation-suites-and
level: task
title: "SPARQL 1.2 evaluation suites and triple-term evaluation"
short_code: "SPARQL-T-0018"
created_at: 2026-08-05T15:15:43.995264+00:00
updated_at: 2026-08-05T22:27:34.163482+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# SPARQL 1.2 evaluation suites and triple-term evaluation

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Complete the SPARQL-T-0008 handover: vendor the sparql12 *evaluation* suite directories (deliberately left unvendored by the parser initiative) from the pinned rdf-tests commit, and make triple-term evaluation fully conformant — triple terms as subjects/objects in BGP matching (the store encodes them as first-class Term_IDs), in expressions (the T-0014 accessors), in CONSTRUCT templates, and in results (SRX/SRJ 1.2 triple-term encoding in the readers and comparison).

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] sparql12 evaluation directories vendored from the pinned commit with provenance README updated (or, if upstream has not published them at that commit in runnable form, the gap documented with the upstream state and this criterion re-scoped with human sign-off). — all four (`eval-triple-terms/`, `expression/`, `grouping/`, `rdf11/`) exist at the pin; no re-scope needed.
- [x] Triple-term BGP matching green: patterns with quoted-triple terms probe via the dictionary's triple-term IDs (component find via `find_term`; absent components short-circuit to empty).
- [x] Expression-level triple-term semantics green: TRIPLE/SUBJECT/PREDICATE/OBJECT/isTRIPLE over stored and computed triple terms; equality/sameTerm on triple terms.
- [x] SRX/SRJ readers and result comparison handle 1.2 triple-term result encoding. — plus the SRJ literal base direction the 1.2 expectations carry.
- [x] All enabled sparql12 evaluation directories fully green at both widths against enabled backends.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Mostly integration: the machinery exists after T-0010…T-0017; this task closes the 1.2-specific gaps found by the suites. Check upstream `w3c/rdf-tests` sparql12 state at the pinned commit first — if the eval suites landed after the pin, propose either a second pinned commit for the sparql12 tree (documented in the provenance README, as the family convention allows per-directory pinning) or defer with evidence.

### Dependencies
SPARQL-T-0010 (readers), T-0011 (BGP), T-0012/T-0014 (expressions/accessors), T-0017 (CONSTRUCT) — effectively last-but-one.

### Risk Considerations
Spec/suite instability is the known risk (the initiative scopes this "to the extent published and stable"); the acceptance criteria carry an explicit documented-gap escape hatch requiring human sign-off, mirroring how T-0008 handled the syntax side.

## Status Updates **[REQUIRED]**

### 2026-08-05 — Vendoring done, engine gaps measured

**Upstream state.** The sparql12 evaluation directories *do* exist at the
pinned commit `767554e135eb6665949d870e6fa7bbc813837293`: the top
`sparql/sparql12/manifest.ttl` includes `eval-triple-terms/`,
`expression/`, `grouping/` and also `rdf11/`, which the T-0010 README did
not name. No re-pin and no documented gap is needed — the escape hatch in
the acceptance criteria does not apply.

**Vendored** (118 files, verbatim from the pinned commit):

| Directory | Upstream path | Entries |
|---|---|---|
| `sparql12-eval-triple-terms/` | `sparql/sparql12/eval-triple-terms/` | 41 (38 query eval + 3 Update) |
| `sparql12-expression/` | `sparql/sparql12/expression/` | 5 |
| `sparql12-grouping/` | `sparql/sparql12/grouping/` | 2 |
| `sparql12-rdf11/` | `sparql/sparql12/rdf11/` | 3 |

**Harness changes so far.** `.trig` and `.nq` data documents now load on
both backends (a quad document names its own graphs, so the target graph
is the document's); the three `mf:UpdateEvaluationTest` entries in
eval-triple-terms are counted and acknowledged as out of engine scope
(pinned as `UPDATE_ENTRIES`), mirroring the syntax harness.

**Baseline measurement** (`zz_survey`, memstore):

- `sparql12-grouping` 2/2 green, `sparql12-rdf11` 3/3 green — no engine work.
- `sparql12-expression` 3 pass, 1 mismatch, 1 unsupported.
- `sparql12-eval-triple-terms` 7 pass, 3 mismatch, 28 unsupported.

**Engine gaps the suites name** (the work of this task):

1. `triple term pattern` — a non-ground triple term in a BGP position (20 entries).
2. `VALUES cell` — a triple term in a VALUES data block (3 entries).
3. `triple-term expression` — `<<( … )>>` as an expression (2 entries).
4. `CONSTRUCT template` — a triple term in a template (3 entries).
5. `op-2` — `=` value equality over triple terms (component-wise).
6. `order-1`/`order-2` — ORDER BY over triple terms (§15.1's kind order, triple terms last).
7. `triple-on-str-literals` — the SRJ reader drops a literal's base direction.

**Plan for the pattern gap.** A ground triple term resolves through
`find_term`, which both dictionaries already answer component-wise. A
*non-ground* one needs the reverse — an ID's component IDs — and the
match interface has no such call. The engine will carry a `Triple_Reader`
adapter alongside `Term_Loader`/`Term_Finder` (memstore answers from its
`triples` array with no allocation; kvstore has to materialize and
re-find). That asymmetry is store evidence for SPARQL-T-0019.

### 2026-08-05 — Complete: all four directories green on both backends

`make test` is green at both Term_ID widths; `make check` is clean.
`sparql12-eval-triple-terms` 38/38, `sparql12-expression` 5/5,
`sparql12-grouping` 2/2, `sparql12-rdf11` 3/3 — against memstore *and*
kvstore. The corpus is now **483 evaluation tests across thirty-five
directories**, and 556 expectations read across the four formats.

**A triple term in a pattern is decided at plan time, not per solution.**

- *Ground* (every component an IRI or a literal, all the way down): it
  is a term like any other. `plan.odin` materializes it, `find_term`
  resolves it to one ID, and matching is an ordinary index probe. A term
  the store does not hold collapses the whole pattern to `Plan_Nothing`.
- *Non-ground*: the position becomes a fresh internal slot plus a
  `Plan_Term_Shape` — the components to check once the slot holds an ID.
  `Plan_BGP` carries the shapes in one pre-order list with a per-pattern
  range, so `unify_quad` runs them in one forward pass and a nested term
  reads a slot an earlier shape filled. No recursion at match time, and
  none in the executor (which the Odin generic-instantiation constraint
  would not survive anyway).

**The store gap.** Taking a matched term apart needs the direction
`find_term` does not go. The engine carries a `Triple_Reader` adapter:
memstore reads the component IDs its dictionary already holds (a
`tests/guards` case pins that a triple-term BGP streams 500 solutions
with **zero** allocations); kvstore materializes the term and re-finds
each component — two round trips for something the dictionary knows
outright. Written up in `Triple_Reader`'s comment as evidence for
SPARQL-T-0019.

**The rest of the 1.2 surface**: triple terms in VALUES cells (the
builder owns the materialized node, since an absent cell keeps its
term); `<<( … )>>` as an expression, which is TRIPLE(s, p, o) and shares
its construction and its refusals; triple terms in CONSTRUCT templates,
compiled into a parallel list and instantiated backwards so children are
built first; component-wise *value* equality for `=` (`op-2`: two triple
terms differing only in a component's datatype are equal and not the
same term); and the SRJ reader's `its:dir` base direction, which the SRX
reader already had.

Also fixed, and neither of them a 1.2 question — both found through
`order-by.rq`, which is twenty subquery-plus-BIND branches unioned:

1. **A BIND over a subquery bound nothing in the answer.** A projection
   hands its consumer a masked *copy* of the working row, and Extend
   wrote only into the working row. Now it writes into both.
2. **A UNION's right branch started on whatever the left one left
   behind.** A blocking operator replays a whole row over the working
   row, and a LIMIT stops a branch without its input ever being asked to
   release what it bound. The union now snapshots the bindings it began
   with and restores them before the right branch. Both have regression
   cases in `sparql/memstore/blocking_test.odin`.

**Tests added.** `sparql/memstore/triple_terms_test.odin` (8 cases: the
ground/non-ground split, nesting, a variable shared with the enclosing
pattern, sameTerm vs `=`, VALUES, expression form and its subject-
position refusal, the accessors); two CONSTRUCT cases in `forms_test`;
two union/BIND regressions in `blocking_test`; triple-term queries in
both `tests/guards` leak tests plus a new allocation-free guard.

**Unchanged elsewhere.** The three long-standing near misses
(`sparql10-expr-builtin`'s language-tag case, `sparql11-negation`'s
`graph-minus`, `sparql11-subquery`'s RDF/XML data) are exactly where
T-0017 left them; the README records them unchanged.