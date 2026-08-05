---
id: property-path-evaluation-per-18-4
level: task
title: "Property-path evaluation per §18.4"
short_code: "SPARQL-T-0016"
created_at: 2026-08-05T15:15:40.931668+00:00
updated_at: 2026-08-05T20:49:29.590483+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Property-path evaluation per §18.4

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Property-path evaluation per §18.4, over the path expressions the algebra translation produced (link-only paths were already simplified to triple patterns in SPARQL-I-0001): inverse (`^`), sequence (`/`), alternative (`|`), negated property sets (including inverse members), zero-or-one (`?`), and the reachability forms zero-or-more (`*`) and one-or-more (`+`) with cycle-safe traversal and the spec's set (not bag) semantics for those forms.

## Acceptance Criteria

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [x] Sequence/alternative/inverse compose with the existing operator machinery (sequence introduces a fresh internal join variable; inverse swaps probe direction). — a sequence's steps chain through fresh internal slots and `join_plans` folds the resulting BGPs back into one probe chain; an alternative is a `Plan_Union`, so it stays a bag; an inverse swaps the two ends at compile time and, inside a repeat, at run time as the traversal's direction.
- [x] Negated property sets: forward and inverse member partitions evaluated per spec (match any predicate not in the set, in the respective direction). — the two partitions are two `Plan_NPS` nodes under a union, which is what `nps_direct_and_inverse` distinguishes from one set applied both ways. A member the store does not hold is dropped: it cannot equal any predicate, so excluding it excludes nothing.
- [x] `*`/`+`: BFS reachability over Term_IDs with a visited set; all four binding cases correct (both ends bound, either end bound, both free — both free iterates all subject/object nodes per spec); `*` includes zero-length paths for every relevant node including literals-as-objects cases the suites encode. — the case is picked from the *pattern*, not from the row, which is what makes the operator safe to correlate; nodes(G) is subjects ∪ objects and `test_path_zero_length_counts_literal_objects` pins the literal.
- [x] Set semantics for `?`/`*`/`+` results (no duplicate solutions from multiple routes); bag semantics preserved elsewhere. — the set is per start node, never global: `path-ng-01` projects `?t` and expects `b` twice, from two different `?s`. `test_path_alternation_and_sequence_are_bags` is the other side of the same line.
- [x] Cycles terminate; deep chains do not overflow (iterative BFS frontier, not recursion). — a node is expanded at most once, which is the whole termination argument; `test_path_deep_chain_does_not_overflow` walks ten thousand links at stack depth zero.
- [x] Property-path evaluation directories enabled and fully green; dual-width matrix green; visited-set/frontier allocations through the query allocator, guard-checked. — **sparql11-property-path, 33/33 on both backends**, at 64 and 32 bits; `test_property_path_traversal_is_bounded_by_the_graph` measures both halves of the memory claim, and seven path queries joined the no-leaks loop.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
A path-evaluation iterator family beside the BGP probe: evaluates one path step as match() probes, with reachability driven by an explicit frontier queue. Both-ends-free reachability enumerates candidate start nodes from the graph's terms — note in the store-evidence log that a term-enumeration/ordered-iteration capability would serve this better than MATCH_ALL scans.

### Dependencies
SPARQL-T-0011 (BGP probe machinery, GRAPH interaction comes via T-0013 but path suites gate on both).

### Risk Considerations
Zero-length-path semantics (which nodes count, graph vs dataset scope) is the classic error well — encode the spec's definition as unit cases first. Visited-set growth on dense graphs is bounded by node count, acceptable for suite scale; note real-world bounds in the evidence log rather than engineering around them now.

## Status Updates **[REQUIRED]**

### Design settled (read from the suites, not from memory)

Read the 33 `sparql11-property-path` entries and their expectations before
writing anything; four of them pin semantics that are easy to get wrong and
that decide the whole shape:

- `zero_or_more_set_end` — `:s :p* ?o` over the **empty** graph answers
  `?o = :s`. A ground endpoint's zero-length path applies even when the store
  has never heard of the term. So a path endpoint must **not** short-circuit to
  `Plan_Nothing` the way a BGP's ground term does; it gets a synthetic ID,
  exactly as a VALUES cell naming an unknown term does.
- `values_and_path` — `VALUES ?v { 1 } . ?v <p>? ?v` over the empty graph
  answers **nothing**. When *both* endpoints are variables *in the pattern*,
  the zero-length pairs range over `nodes(G)` (subjects ∪ objects of the active
  graph). The case is chosen by the pattern, not by what happens to be bound at
  run time — which is what keeps the operator probe-safe: correlating it only
  filters, it never changes the case.
- `path-p2` (`(:p1|:p2)/(:p3|:p4)`) expects `c` **twice** → alternation and
  sequence keep bag semantics; `diamond-loop-5a` (`(:p/:p)?`) dedupes → the
  three repeat forms are sets.
- `path-ng-01` (`GRAPH <g> { ?s :p1* ?t }`, projecting `?t`) expects `b` twice,
  from two different `?s` — so the set is per start node, never global.

### Plan

**plan.odin** — the path expression is compiled into ordinary plan nodes:

- `link` → a one-triple `Plan_BGP`; `inv` → swap ends; `seq` → a chain through
  fresh internal slots, which `join_plans` merges back into one probe chain;
  `alt` → `Plan_Union` (bag).
- `Plan_NPS` — a negated property set in one direction. `!(:a|^:b)` becomes the
  union of a forward branch excluding `{:a}` and an inverse branch excluding
  `{:b}`, which is what `nps_direct_and_inverse` asserts.
- `Plan_Path` — the three repeat forms as one node: `include_start` (`*`, `?`)
  × `closure` (`*`, `+`). Its operand is compiled as a **step sub-plan** over
  two dedicated internal slots, so an arbitrary inner path — `(p1/p2)+`,
  `((:P)*)*` — costs nothing extra.
- `Plan_Path_End` carries the ground-but-absent case (id assigned at exec
  setup, like a VALUES cell).
- `Alg_Graph` gains a third check: a `GRAPH ?g` body holding a path node is
  driven by `Plan_Graph_Scan` even when it also has triple patterns, because a
  path node reads the graph position rather than binding it.

**exec.odin** — the traversal is an explicit BFS, never recursion:

- `Plan_Path` state: a start list, a per-start result list, a visited set and an
  expanded set, and a frontier queue, all from the query allocator.
- Expanding one node means running the step sub-plan with the in-slot bound.
  That is `run()` called from inside `run()`, which the generic-with-compile-
  time-proc-constants constraint forbids — so it goes out through a procedure
  value and back in, exactly as EXISTS does: a new `Path_Expander` on `Exec`,
  bound by the two instantiation packages.
- Direction is chosen at run time: forward from a fixed subject, backward from a
  fixed object, otherwise a `nodes(G)` enumeration. A synthetic ID never reaches
  a match pattern — a term the store does not hold has no edges.

### Done

`sparql11-property-path` is enabled and 33/33 green against both backends, at
both `Term_ID` widths. `make check` clean; `make test` clean at 64 and 32 bits.

**The suite survey, before and after, directory by directory.** Only
property-path moved: `pass 3 / mismatch 4 / unsupported 26` →
`pass 33 / mismatch 0 / unsupported 0`. Every other directory's line is
byte-identical, including the ones not yet enabled — so nothing was traded for
this.

**One bug this uncovered that was not property-path evaluation at all.** Four
of the entries were already failing before any of this, and they were failing
in the *translation*: §18.2.2.5 turns `X (P/Q) Y` into
`X P ?fresh . ?fresh Q Y`, and `?fresh` was an ordinary query variable, so
`SELECT *` projected it. The translation calls it fresh, which is to say not in
scope. Fixed at the slot table: a variable named with `PATH_VAR_PREFIX` gets an
internal slot, so it behaves like a pattern blank node and never reaches an
answer. The aggregate substitution's `.N` variables share the leading `.` and
are deliberately left alone — those are read back by the expressions §18.2.4.1
rewrote to use them, and an internal slot is not findable by name.

**What the traversal needed beyond the plan.**

- The step runs out through a procedure value and back into
  `exec_path_expand`, the same shape EXISTS uses. Worth being explicit about
  why: `run → source_next → path → run` is a cycle among generic procedures
  taking compile-time procedure constants, and that hangs the Odin compiler
  rather than failing. The concrete adapter in each instantiation package is
  where the cycle is cut.
- A synthetic ID must never reach a match pattern — the Sentinel space is not
  one the store issued terms in. So a ground endpoint the store does not hold
  gets a synthetic name for its zero-length binding and is then treated as a
  node with no edges, which is exactly what it is.
- `GRAPH ?g` needed a third case in plan building. A triple pattern binds `?g`
  by matching; a path *reads* the active graph before it starts, both to
  traverse and to enumerate nodes(G). So a body holding a path is driven by
  `Plan_Graph_Scan` even when it also has triple patterns that could have bound
  `?g` themselves. Without it, `GRAPH ?g { ?s :p* ?t . ?a :q ?b }` would have
  depended on which side of the join came first.

**Tests.** Twelve cases in `sparql/memstore/path_test.odin`, one per rule
rather than one per query shape: the zero-length path over a ground endpoint
and over two variables (the pair that decides the whole design), literal
objects counting as nodes(G), `+` excluding its start unless a cycle returns,
the repeats as sets against alternation and sequence as bags, nesting, backward
traversal, negated sets split by direction, and a ten-thousand-link chain that
a recursive ALP would have overflowed.

Two guards. `test_property_path_traversal_is_bounded_by_the_graph` measures
both halves of the memory claim: ten times the solutions over the same graph
must cost the same peak (the traversal follows the graph, not the answer), and
four times the graph must cost *more* — which is what proves the visited set
and the frontier are taken from the query's allocator rather than from
somewhere the guard cannot see. Seven path queries joined the no-leaks loop,
which runs each to exhaustion and again abandoned mid-stream.

**Store evidence for SPARQL-T-0019**, recorded in `path_collect_nodes`: a path
with two variable endpoints has to enumerate nodes(G), and the match interface
can stream quads but cannot be asked which terms a graph holds — so it reads
every quad to rebuild a set the store already has. That is the same gap
`Plan_Graph_Scan` hits from the other side, and it is now two operators paying
for it.

**Known, out of scope, worth writing down.** `SELECT *` emits no projection at
all, so `SELECT DISTINCT *` over a pattern with a path sequence would
deduplicate on the internal slot as well as the visible ones. No suite entry
reaches it, and the fix is to make `SELECT *` project the in-scope variables
the way §18.2.4.3 says — a translation change that touches every SSE golden,
which belongs with the result forms rather than here.