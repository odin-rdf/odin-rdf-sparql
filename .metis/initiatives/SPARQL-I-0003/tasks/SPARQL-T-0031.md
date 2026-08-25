---
id: the-core-ports-ids-to-record-the
level: task
title: "The core ports: ids to record, the parapoly seam collapsed, kvstore deleted"
short_code: "SPARQL-T-0031"
created_at: 2026-08-24T20:42:33.614314+00:00
updated_at: 2026-08-25T12:00:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0030", "SPARQL-T-0040"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# The core ports: ids to record, the parapoly seam collapsed, kvstore deleted

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

The demolition and the rebuild, in one motion, because the compiler will
not let them be two: `sparql` stops being generic over a backend and
starts calling odin-rdf-record's read API directly, ids become
`record.Term_ID`, `sparql/kvstore` and every `store:` import are deleted,
and the engine becomes one package.

This is the largest task in the initiative and the one whose shape the
owner's decision 1 dictates: **no dual-backend goal at any point, record
is the one and only store forever**, so every seam that existed to span
backends goes rather than being re-instantiated as `sparql/record`.

Green boundary: `make check` vets every surviving package. The tests come
back in SPARQL-T-0032; between the two this repository does not run.

## Acceptance Criteria

- [x] **`Exec` is concrete.** `Exec($D, $It)` loses its parameters and
      holds a `record.Snapshot` and record's `Scan`; `$MATCH`, `$NEXT`
      and `$DESTROY` stop being threaded through operators and become
      direct calls to `snapshot_match` + `range_iter` + `scan_next`. Every
      operator in `sparql/exec.odin` and every builder in
      `sparql/plan.odin` follows.
- [x] **All six backend-spanning procedure types are retired**, not
      re-pointed at record. Each exists so `sparql` could name no
      backend, and owner decision 1 retires that reason:
      `Term_Resolver` (`sparql/construct.odin:46`), `Term_Loader` and
      `Exists_Runner` (`sparql/expr_eval.odin:34`, `:45`),
      `Path_Expander` and `Triple_Reader` (`sparql/exec.odin:234`,
      `:257`), `Term_Finder` (`sparql/plan.odin:548`). **This is the
      checklist** — the compiler will report that an indirection does not
      compile, never that it is unnecessary, so grep for `#type proc` in
      `sparql/` at the end and expect nothing backend-shaped to remain.
      `Triple_Reader` is the one exception worth weighing: it may survive
      as a plain procedure if record's component-ids entry point wants
      wrapping, but not as a seam.
- [x] **`exists_adapter` and `expand_adapter` are gone, not ported.**
      They exist only because an expression calling back into the generic
      executor "would complete a cycle of generic instantiations that the
      compiler cannot close" (`sparql/kvstore/eval.odin`). With one
      concrete executor the cycle closes: `exec_exists` and
      `exec_path_expand` are called directly. **If they survive the port
      in any form, the collapse did not happen** — this is the criterion
      that distinguishes a real collapse from a rename.
- [x] **Ids are `record.Term_ID` natively**, and `Fact_ID`/`Epoch` are
      held as the distinct types they are. No `u32` aliasing, no
      widen/narrow layer, no `RDF_STORE_TERM_ID_BITS`.
- [x] **The sentinels are remapped deliberately, with §4 of the
      initiative as the checklist.** `store.UNBOUND` and `store.WILDCARD`
      both become `0`. `store.DEFAULT_GRAPH` **splits**: in a pattern it
      is `record.MATCH_DEFAULT_GRAPH`; in a fact the default graph is
      stored as `G = 0`, which is also "unbound". Every site that reads a
      quad's graph component into a row slot is audited by hand —
      `graph_scan_next` (`sparql/exec.odin:880`), `unify_quad`
      (`:2295`), `probe_pattern` (`:2265`), and `Plan_Graph_Bind`'s
      evaluation — and the default-graph skip is a deliberate test on `0`
      with a comment saying why, not an accident of a constant's value.
- [x] **`is_synthetic` becomes a bounded range test.**
      `SYNTHETIC_FIRST` becomes `record.CONSUMER_ID_FIRST`, and the test
      checks **both ends** (`>= CONSUMER_ID_FIRST && <= CONSUMER_ID_LAST`).
      A bare `>=` is wrong on record, where bit 31 marks *inlined
      literals*, so every small canonical integer would read as
      synthetic. `expr_eval.odin`'s comment is rewritten to say that
      record reserved this range for exactly this use — which is the
      answer to the gap `SPARQL-T-0019` recorded.
- [x] **`ground_ref`'s sentinel assert is re-derived, not deleted.**
      `sparql/plan.odin:1943` asserts `id_kind(id) != .Sentinel` on a
      resolved ground term. record has no `.Sentinel` kind; the property
      worth keeping is that `snapshot_resolve` never returns a
      consumer-range id, and the assert should say that.
- [x] **`store.id_kind` becomes `snapshot_kind`** at its four call sites,
      with the one `.Triple` test (`sparql/exec.odin:2358`) left standing
      against the record kind that SPARQL-T-0035 will make reachable.
- [x] **The error slot and every failure path behind it are deleted.**
      A read on record cannot fail — the projection is resident — so
      `Session.err`, `query_error` and every `err != nil` branch the
      kvstore adapters carry go. An empty answer is the answer.
      odin-rdf-shacl deleted the same machinery and found no consumer.
- [x] **A query is still one snapshot, and there is now exactly one
      constructor** — decided by the owner, 2026-08-24.
      `query_init(q, algebra, snapshot, base)` takes a
      `record.Snapshot`, holds it for the `Query`'s life, and
      `query_destroy` releases it. **`query_init_txn` is deleted.** The
      distinction the two drew was who owns the handle, and on record
      that distinction collapses: a snapshot is a snapshot whether it
      came from `store_latest`, from `store_at`, or from a `Validator`'s
      candidate at the new epoch. The consumer that motivated
      `query_init_txn` — one judging whether a candidate may join the
      dataset — is served by record's `Validator` hook handing it a
      candidate snapshot, so SHACL-SPARQL querying a candidate becomes
      the ordinary call. A branch the suite cannot exercise is a branch
      that rots.
- [x] **One package.** `sparql/kvstore` deleted outright (all 4344
      lines). `sparql/srj` and `sparql/srx` stay separate — they are
      output formats, never instantiations.
- [x] **The public API moves from `sparql_kvstore` to `sparql`.**
      `Query`, `query_init`, `query_next`, `query_destroy`, `query_term`,
      `query_var_names` and `query_var_internal` were the instantiation
      package's surface and become the engine's. `query_error` goes with
      the error slot. This is a breaking rename for every caller —
      `tests/readme` and the README are the only ones in the tree, and
      both move in SPARQL-T-0032.
- [x] **No `store:` import anywhere**, and `make check` green on every
      surviving package with `-vet -strict-style`.

## Implementation Notes

### Technical Approach

**The compiler is the checklist.** Delete `sparql/kvstore` and the
`store:` imports first and let the errors enumerate the work; that is how
odin-rdf-shacl's equivalent task ran, and it is more reliable than a
hand-built site list for 449 references over 52 names.

**Order within the task.** The ids and the seam cannot be separated —
`Match_Pattern` is store-typed and appears in the generic signatures — so
expect one long red period. Take `exec.odin` before `plan.odin`: the plan
builder's shape follows from what the executor needs, not the reverse.

**The quad representation is decided: keep `[4]Term_ID`, copy at the
scan boundary** (owner, 2026-08-24). record yields a `Fact` with named
`s, p, o, g` fields plus the epoch interval; the engine indexes quads
positionally at ten sites, and **four of those are dynamic** — `quad[i]`
inside `unify_quad`'s per-position loop, the hottest code in the
executor. Copying the four components into the engine's own
`[4]Term_ID` at the scan boundary costs one 16-byte copy per matched
fact and leaves that loop untouched, which is much the smallest diff
through the riskiest task. Revisit with numbers afterwards —
SPARQL-T-0040's baseline and SPARQL-T-0036's re-measurement will show
whether the copy is visible at all.

**Explicitly rejected: reinterpreting the layout.** record's `Quad` is
`{s, p, o, g: Term_ID}` and is layout-identical to `[4]Term_ID` given
`QUAD_S..QUAD_G` are `0..3`, so a transmute would be free and would
change no engine code. It is rejected because it couples this engine to
a sibling's struct field order across a repository boundary: a reorder
in record would compile cleanly here and corrupt every result. The
copy is the price of not making that bet.

**What the read path becomes**, per the record handoff: `0` is unbound in
a `Pattern`; `Filter{origin = .Any}` — origin must be stated, and
`Origin(0)` is refused by an assert in `range_iter`; `snapshot_match`
returns a `Range` and `range_iter` a `Scan`; `scan_next` yields a
`Fact_ID` and `snapshot_fact` reads the `Fact` behind it. Note that the
engine's `Encoded_Quad` (a `[4]Term_ID`) has no direct record equivalent
— a `Fact` carries `s/p/o/g` as fields — so the join and unification code
either reads fields or builds the array; **measure before assuming the
array is free**, since this is the hot path.

~~**`snapshot_term` borrows** — the dictionary arena or a caller-provided
`Term_Buf` bounded by `record.INLINE_LEXICAL_MAX`. The `Query`'s
materialized-term table must clone what it keeps, and closing the store
frees the arena, so anything outliving a store owns its terms. This is
the same contract kvstore had for a different reason; do not assume the
old ownership code is right just because it looks right.~~

**Amended 2026-08-25 — the paragraph above was written against record
`v0.3.0` and is wrong against `v0.4.0`, which is what this repository now
pins.** `RECORD-A-0008` changed the contract: **`snapshot_term` sometimes
owns.** A decoded triple term is owned *wholly*, every component
allocated; a split IRI owns its joined string (it always did — there was
simply nothing to free it with). The rule is now:

- **Call `snapshot_term_destroy(snap, id, t, allocator)` on everything
  `snapshot_term` returns**, without deciding which case it is. It is
  total: a no-op for the borrowing kinds, `delete` for a split IRI's
  string, `rdf.destroy_term` for a triple term's whole tree. It takes the
  **id** because the term alone cannot tell a joined IRI from a borrowed
  one.
- It is safe on a term `snapshot_term` refused (a nil term frees
  nothing), which is what lets a caller pair it with every call rather
  than with some.
- The borrowing half of the old paragraph still holds for the kinds that
  borrow, and `INLINE_LEXICAL_MAX` is still the buffer floor.

So the `Query`'s materialized-term table does **not** simply "clone what
it keeps" — it must record the id alongside each term and destroy through
that verb. The warning in the struck paragraph turns out to be the right
warning aimed at the wrong contract: do not assume the old ownership code
is right, because the contract moved under it between this task being
written and being worked.

### Dependencies

Blocked by SPARQL-T-0030 (the collection must resolve before anything can
compile against record) **and by SPARQL-T-0040** — once this task
collapses the seam, the easy read-instrumentation point is gone and the
"before" numbers can no longer be taken. Taking them is the whole reason
T-0040 runs first.

### Risk Considerations

**This task is red for its whole duration and there is no honest
intermediate commit.** That is the accepted cost of a replacement port,
but it means the work should be done in one sitting or with a very
explicit hand-off note, and `make check` — not `make test` — is the only
signal available until SPARQL-T-0032.

**The default-graph/unbound collision (§4) is the likeliest silent bug in
the whole initiative**: it produces wrong answers rather than crashes, and
the W3C corpus is the only thing that will catch it — one task later.
Auditing those sites by hand *now*, with comments, is cheaper than
finding it through a failing `sparql10-graph` entry.

**The scan-boundary copy is the likeliest performance regression
introduced by this task rather than by the backend.** It is a decided
trade rather than an open one, but SPARQL-T-0040's pinned read counts and
timings are the baseline that will show it: if the port's timings move
more than the backend change explains, this copy is the first suspect.

## Status Updates

### 2026-08-25 — handoff into this task, written at the end of the session that finished SPARQL-T-0030 and -T-0040

Everything below is what that session knew and the repository does not
say on its own. Read the amended ownership note in Technical Approach
first — it corrects a factual error in this task's own text.

#### State of the tree

`main` at `f3b01bd`, everything committed. Both blockers are **complete**:
`SPARQL-T-0030` (plumbing, green on all three CI runners) and
`SPARQL-T-0040` (`bench/`, sixteen pinned read counts). `make test` is
green at both widths, **512/512 across 37 directories**, and `make check`
is clean. odin-rdf-record `v0.4.0` is published and pinned.

**This task is unblocked and is the actionable one.**

#### The obligation this task inherited from SPARQL-T-0040, which its criteria do not mention

**`bench/` imports `sparql/kvstore`, and this task deletes that package.**
Concretely: `bench/store.odin:14` imports `store:store/kvstore`, and
`bench/main.odin:65` imports `sparql/kvstore` for `Query`,
`SPARQL_COUNT_READS` and `read_counts_get`. `make check` now vets `bench`
**twice** (plain and instrumented) and `sparql/kvstore` instrumented as
well — so this task's green boundary, "`make check` vets every surviving
package", **is unreachable without dealing with bench.** That is a real
plan defect created by T-0040 landing between this task being filed and
being worked, not an oversight in the original decomposition.

`SPARQL-T-0036` is the task that rebuilds bench against record, and it is
blocked on `SPARQL-T-0033` — so bench cannot simply wait, or `make check`
stays red across three tasks.

**Recommended resolution, for the next session to confirm rather than
assume** (it moves scope between two tasks, so it is the owner's call if
there is any doubt): **this task ports `bench/store.odin` and rehomes the
counting; `SPARQL-T-0036` runs and compares.** That is smaller than it
sounds and is what `store.odin` was isolated for — it is ~80 lines,
`open_ephemeral` + `load_turtle` + `load_trig` becoming `Mem_FS` +
`store_open` + `ingest` + `apply`, and its own doc comment says it is the
file T-0036 rewrites. It also matches T-0036's title, which says *"the
same workload, and whether the read counts held"* — running and
comparing, not building. The alternative is to drop `bench` from
`SRC_DIRS` for three tasks and restore it at T-0036, which works but
leaves a package nothing compiles, and a `when`-gated branch nothing
compiles is a branch that rots.

**And the counting has to move with the seam.**
`sparql/kvstore/counting.odin` declares `SPARQL_COUNT_READS`,
`Read_Counts`, `read_counts_reset` and `read_counts_get`, and the
increments live in the five adapters in `eval.odin` — 36 lines, all
inside `when`. When those adapters become direct calls, the counters go
to the direct call sites in `sparql/` and the file moves there. This is
exactly the shape odin-rdf-shacl ended up with (`shacl/counting.odin`)
after its own seam collapsed, for the same reason, so that file is the
model.

**Keep the counter names and their meanings identical**, or T-0036's
comparison is worthless: `match`/`next`/`load`/`find`/`triple` are *one
tick per question the engine asks*, and `store_ops` is *every round trip
into the store*. The first five are what should hold to the integer
across the port; `store_ops` is what the port is expected to change and
is deliberately not pinned.

Three Makefile lines this task must update: `check`'s
`-- sparql/kvstore (instrumented) --` step, and the two `bench` /
`build-bench` recipes' `-define:SPARQL_COUNT_READS=true` builds (the
define survives; only the package declaring it moves).

#### record v0.4.0 API, as actually compiled against rather than as documented

From `tests/smoke/smoke_test.odin`, which is a working call site for most
of this — read it before writing new ones.

- `store_open(&s, dir, ops, validator, target_size, allocator)` returns
  **four** values: `(tear, err, load_err, write_err)`. Exactly one of the
  error slots is set on failure; `tear` non-`.None` with `err == .None`
  means a repair happened and the boot continued.
- `snapshot_triple_parts(snap, id) -> ([3]Term_ID, bool)`. `false` for an
  inlined id and for any term that is not a triple term. It **asserts**
  on an id the snapshot does not know, like `snapshot_bytes` — so it is
  not a safe way to ask "is this a term of this snapshot".
- `snapshot_term(snap, id, buf, allocator) -> (rdf.Term, bool)`, `buf` at
  least `record.INLINE_LEXICAL_MAX` bytes. Pair with
  `snapshot_term_destroy` — see the amended Technical Approach note.
- `snapshot_resolve(snap, term, allocator) -> (Term_ID, bool)`, and it
  recurses: a component the snapshot has never seen makes the whole term
  a miss in one probe.
- `ingest.turtle(src, graph, allocator, kind, blank_prefix, base) ->
  (ops, Error)` — `graph` is an `rdf.Graph_Label` (`nil` for the default
  graph) and comes **second**, before the allocator. Check
  `err.kind != .None`, not the value. `ops_destroy(ops, allocator)`.
- `apply(&s, Changeset{ops = ops}) -> (Epoch, bool, Apply_Error)`;
  success is `Apply_Error{}`, and the middle value is the validator's
  verdict.
- The store must not be copied or moved after `store_open` — the writer
  holds a pointer to the `Mem_FS` inside it. Every snapshot must be
  released before `store_close`; `store_destroy` asserts it.

#### §5's hazard is confirmed, not predicted

`tests/smoke` asserts that an inlined literal's id is
**`>= record.CONSUMER_ID_FIRST`**. So an *ordinary term* does sit above
the consumer range's floor, and this task's `is_synthetic` criterion is
guarding against a bug that demonstrably exists rather than a theoretical
one. Written from the corpus: the innermost component of
`data-0-tripleterms.ttl`'s nested triple term is an inlined
`"123"^^xsd:integer`.

#### Two stale claims to fix when their subjects move

- **`ci.yml`'s record-pin comment** argues the `v0.4.0` floor partly from
  "`tests/smoke` names `snapshot_triple_parts`, `Term_Kind.Triple` and
  `snapshot_term_destroy`". `tests/smoke` is deleted at
  `SPARQL-T-0032`/`-T-0033`, at which point that sentence is false and the
  floor argument has to move to the engine itself (which will name the
  same procedures). Whoever deletes the package owns that edit.
- **`SPARQL-T-0035`'s "pin the record release" criterion is already
  satisfied** — the pin moved at T-0030 rather than at T-0035, by the
  owner's call. What is left there is enabling the directory, restoring
  512/512, and replacing `triple_adapter`'s two-round-trip note.

#### Odin toolchain traps, all of which cost time this session

This task writes a lot of new code, so: `os.read_entire_file` requires
the allocator argument in this Odin version and returns `os.Error`, not a
`bool`. In `core:fmt`, `{` and `}` are **verbs** — an unescaped `{` in a
format string is written into the output as
`%!(MISSING CLOSE BRACE)` with no error at the call, which surfaces
arbitrarily far away; double them. And `%10d` **zero-pads** integers
while `%-10d` pads on the *right* with zeros; render the number with
`%d` and pad the resulting string with `%10s`.

#### What the baseline says about this task's own risk

`SPARQL-T-0040`'s numbers are in its Status. The one that bears directly
here is the **scan-boundary copy** this task decided on: the pinned read
counts are what will show whether the port's timings moved more than the
backend change explains. `bgp3` at 36.6 ms over 164,933 triples and
`path` at 13.3 ms are the cases where a per-fact 16-byte copy would show
first — 380,006 and 117,674 store operations respectively.


### 2026-08-25 — done: one package, one snapshot, no seam

`make check` is green on every package this task owns and `make test`
runs the four that survive it. The engine compiles against
odin-rdf-record alone; nothing in the repository links LMDB.

#### The shape of it

`sparql/kvstore` is deleted (4453 lines). `sparql` gained four files —
`ids.odin` (the id vocabulary that `store:` used to publish),
`query.odin` (the prepared-query API, which was `kvstore/eval.odin`
minus its bridge), `counting.odin` (moved, verbs and meanings
unchanged), and `tests/portcheck` (see below) — and lost every
`#type proc` in the package: `grep '#type proc' sparql/` returns
nothing, which is the check the criteria asked for. `Exec($D, $It)` is
`Exec`; `Exec_Node(It)` is `Exec_Node`; the three compile-time
procedure constants are `match_open` and `match_next`, two ordinary
private procedures in `exec.odin`.

The two adapters that existed only to break a generic call cycle are
gone rather than ported: `exec_exists` and `exec_path_expand` are
called directly, from `expr_eval.odin` and from `path_closure`. That
was the criterion that distinguished a collapse from a rename and it
holds.

#### Three decisions this task had to make that its criteria did not anticipate

**1. The AST type was renamed, because `Query` collided.** This package
already had a public `Query` — the parsed query the grammar's `Query`
production produces, which `parse` returns and `translate` consumes.
The prepared query could not also be called that. The prepared query
took the name (`sparql.Query` beside `sparql.query_init` and
`sparql.query_next`, which is what a consumer holds and steps; a
`query_init` initialising something that is not a `Query` reads as a
mistake), and the AST node became **`Parsed_Query`**. It is named by
consumers rarely — both of its entry points return or take it by
inference — which is what made it the one that moves. 26 sites, all
inside this package. `ast.odin` carries the reason.

**2. `query_destroy` does not release the snapshot**, and the criterion
saying it does is wrong in the one case the single constructor exists
to serve. record's `Validator` hands its `check` a
`Snapshot{epoch = E, idx = candidate, store = s}` built by hand and
released by record itself — a *borrowed* handle that took no reference.
A query that released it would drop a count it never raised. There is
also no verb that would let `query_init` take its own reference: record
acquires through `store_latest`/`store_at`, and `store_at` on a
candidate would return the head rather than the candidate. So the
snapshot is the caller's, stated in `query_init`'s contract next to the
algebra and the store, and the criterion's substance — *one*
constructor, `query_init_txn` deleted — is unaffected. **This is the
one place the port departs from the plan, and it is the owner's to
overrule.**

**3. `bench/store.odin` was ported here rather than at SPARQL-T-0036**,
which is what the handoff into this task recommended and this session
confirmed rather than assumed: `bench` is vetted by `make check`, so a
task whose green boundary is "check vets every surviving package"
cannot leave it naming a deleted one. `Bench_Store` is now heap-allocated
and passed by pointer — record's writer holds a pointer to the `Mem_FS`
inside it, so returning one by value would leave the writer pointing at
a dead frame. `run_once` acquires and releases a snapshot per query,
where it used to begin and abort a read transaction. What T-0036 does
with it is what its title says: run it and compare.

#### The port runs, and it is not only `make check` that says so

**`make bench` executes every case and every solution count is
identical to SPARQL-T-0040's odin-rdf-store baseline** — all sixteen,
across both configurations: bgp2, bgp3, graph, optional, group, order,
order-limit, path. That is a stronger signal than the green boundary
promised, and it covers BGP joins, a bound named graph, left join,
aggregation, sorting, LIMIT and a transitive path.

**Fourteen of the sixteen read-count pins hold to the integer.** Two
moved, both `group`, both by exactly the number of groups: `load`
4000 -> 4012 (small) and 40000 -> 40012 (large), with `store_ops`
following. **The cause is understood and is not a control-flow
regression.** `bindable_id` resolves an aggregate's result against the
store so that a computed term the data already holds gets the store's
own id; `COUNT(?s)` produces a small canonical integer, which
odin-rdf-store had never interned and record **inlines** — it resolves
without ever having been stored. So the id is a real one rather than a
synthetic one, and reading it back in the projection is a load where it
used to be a lookup in the engine's own computed table. `AVG(?r)`
produces a decimal, is not inlineable, and did not move; `find` is 26
in both, unchanged. This is the "inlineable literals always resolve"
difference the record handoff named, showing up as arithmetic.

**The pins were deliberately not updated.** They are SPARQL-T-0040's
baseline and re-pinning them here would destroy the comparison
SPARQL-T-0036 exists to make. `make bench` therefore fails its
assertion step until that task runs, by design.

**And `tests/portcheck` is new.** This task leaves the repository with
no executing coverage of the engine for two tasks — `tests/guards`,
`tests/readme` and `tests/w3c/harness` all name the deleted package —
so there is now one query of every operator shape (SELECT, ORDER BY,
GROUP BY, FILTER with string functions, `+` path, EXISTS, BIND,
OPTIONAL, CONSTRUCT, DESCRIBE, `GRAPH ?g`, ASK, and a non-ground
triple-term pattern) against a small document, under
`ODIN_TEST_FAIL_ON_BAD_MEMORY`, materialising every column of every
solution. It asserts almost nothing about answers. It exists for the
ownership rework: `snapshot_term` borrows for most kinds and owns for
two, against a kvstore loader that always owned. **Delete it at
SPARQL-T-0033**, with `tests/smoke`.

#### What the ownership rework actually cost

`record.snapshot_term_destroy` takes the **id**, so every materialised
term is remembered with the id it came from. Two places keep such a
list: `Expr_Context.scratch` (now `[]Scratch_Term`, with id 0 meaning
"the engine built this one, use `rdf.destroy_term`" — TRIPLE() and the
§17 constructors) and `Query.materialized`.

The trap worth passing on: **an inlined literal materialises into a
caller-supplied buffer and *borrows* it.** A stack buffer would dangle
the moment the loader returned, and the term has to survive until the
value has been rendered into a binding. `Expr_Context` therefore keeps
a pool of individually-allocated 16-byte buffers (individually, so
appending never moves one), reused across evaluations and reset by
`expr_context_release`, so the per-solution allocation guarantee
survives; `query_term` allocates one per materialised term, which is
cheaper than the whole term kvstore used to build.

#### Three things audited by hand, as the risk note asked

`store.DEFAULT_GRAPH` split into `DEFAULT_GRAPH`
(= `record.MATCH_DEFAULT_GRAPH`, valid in a pattern) and
`STORED_DEFAULT_GRAPH` (= 0, what a fact carries), both in `ids.odin`
with the reason. The three sites that read a quad's G — `graph_scan_next`,
`unify_quad`, and `Plan_Graph_Bind`'s evaluation — each say which they
mean. `path_graph_id`'s `!= UNBOUND` assert survives *because* the
default graph is excluded before a graph variable is ever bound, and
says so.

`probe_pattern`'s "UNBOUND leaked into a match pattern" assert is
**deleted, not moved**: UNBOUND and WILDCARD are the same value on
record by design, so the same text would assert 0 != 0 and fail every
probe over an unbound variable. `unify_shape` gained an `id == UNBOUND`
guard, because `record.snapshot_kind` asserts on an id the snapshot does
not know where `store.id_kind` was a total bit test.

#### Also done, and not in the criteria

`ci.yml`'s odin-rdf-store checkout and its five-paragraph pin history
are retired to a dated note; the record pin's floor argument moved off
`tests/smoke` (which SPARQL-T-0032 deletes) and onto the engine, which
names `snapshot_triple_parts`, `Term_Kind.Triple` and
`snapshot_term_destroy` itself now. That was the stale claim the handoff
into this task flagged, and it is closed. The `Term_ID` width matrix is
gone from the Makefile and from CI. All three runners now build the same
thing, since nothing links LMDB.

#### What is left red, and who owns it

`tests/guards`, `tests/w3c/harness` and `tests/readme` still name
`store:` and `sparql/kvstore`. They are listed as `PENDING` in the
Makefile rather than deleted, and `make test` names them and skips them
rather than pretending they passed. **The README is stale** — 24
references to `sparql/kvstore` — which is where the plan put it
(SPARQL-T-0032 owns it with `tests/readme`), but it is the repository's
front door and it currently tells a reader to import a package that
does not exist.
