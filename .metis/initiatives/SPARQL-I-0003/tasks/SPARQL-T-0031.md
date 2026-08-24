---
id: the-core-ports-ids-to-record-the
level: task
title: "The core ports: ids to record, the parapoly seam collapsed, kvstore deleted"
short_code: "SPARQL-T-0031"
created_at: 2026-08-24T20:42:33.614314+00:00
updated_at: 2026-08-24T20:42:33.614314+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0030", "SPARQL-T-0040"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


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

- [ ] **`Exec` is concrete.** `Exec($D, $It)` loses its parameters and
      holds a `record.Snapshot` and record's `Scan`; `$MATCH`, `$NEXT`
      and `$DESTROY` stop being threaded through operators and become
      direct calls to `snapshot_match` + `range_iter` + `scan_next`. Every
      operator in `sparql/exec.odin` and every builder in
      `sparql/plan.odin` follows.
- [ ] **All six backend-spanning procedure types are retired**, not
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
- [ ] **`exists_adapter` and `expand_adapter` are gone, not ported.**
      They exist only because an expression calling back into the generic
      executor "would complete a cycle of generic instantiations that the
      compiler cannot close" (`sparql/kvstore/eval.odin`). With one
      concrete executor the cycle closes: `exec_exists` and
      `exec_path_expand` are called directly. **If they survive the port
      in any form, the collapse did not happen** — this is the criterion
      that distinguishes a real collapse from a rename.
- [ ] **Ids are `record.Term_ID` natively**, and `Fact_ID`/`Epoch` are
      held as the distinct types they are. No `u32` aliasing, no
      widen/narrow layer, no `RDF_STORE_TERM_ID_BITS`.
- [ ] **The sentinels are remapped deliberately, with §4 of the
      initiative as the checklist.** `store.UNBOUND` and `store.WILDCARD`
      both become `0`. `store.DEFAULT_GRAPH` **splits**: in a pattern it
      is `record.MATCH_DEFAULT_GRAPH`; in a fact the default graph is
      stored as `G = 0`, which is also "unbound". Every site that reads a
      quad's graph component into a row slot is audited by hand —
      `graph_scan_next` (`sparql/exec.odin:880`), `unify_quad`
      (`:2295`), `probe_pattern` (`:2265`), and `Plan_Graph_Bind`'s
      evaluation — and the default-graph skip is a deliberate test on `0`
      with a comment saying why, not an accident of a constant's value.
- [ ] **`is_synthetic` becomes a bounded range test.**
      `SYNTHETIC_FIRST` becomes `record.CONSUMER_ID_FIRST`, and the test
      checks **both ends** (`>= CONSUMER_ID_FIRST && <= CONSUMER_ID_LAST`).
      A bare `>=` is wrong on record, where bit 31 marks *inlined
      literals*, so every small canonical integer would read as
      synthetic. `expr_eval.odin`'s comment is rewritten to say that
      record reserved this range for exactly this use — which is the
      answer to the gap `SPARQL-T-0019` recorded.
- [ ] **`ground_ref`'s sentinel assert is re-derived, not deleted.**
      `sparql/plan.odin:1943` asserts `id_kind(id) != .Sentinel` on a
      resolved ground term. record has no `.Sentinel` kind; the property
      worth keeping is that `snapshot_resolve` never returns a
      consumer-range id, and the assert should say that.
- [ ] **`store.id_kind` becomes `snapshot_kind`** at its four call sites,
      with the one `.Triple` test (`sparql/exec.odin:2358`) left standing
      against the record kind that SPARQL-T-0035 will make reachable.
- [ ] **The error slot and every failure path behind it are deleted.**
      A read on record cannot fail — the projection is resident — so
      `Session.err`, `query_error` and every `err != nil` branch the
      kvstore adapters carry go. An empty answer is the answer.
      odin-rdf-shacl deleted the same machinery and found no consumer.
- [ ] **A query is still one snapshot, and there is now exactly one
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
- [ ] **One package.** `sparql/kvstore` deleted outright (all 4344
      lines). `sparql/srj` and `sparql/srx` stay separate — they are
      output formats, never instantiations.
- [ ] **The public API moves from `sparql_kvstore` to `sparql`.**
      `Query`, `query_init`, `query_next`, `query_destroy`, `query_term`,
      `query_var_names` and `query_var_internal` were the instantiation
      package's surface and become the engine's. `query_error` goes with
      the error slot. This is a breaking rename for every caller —
      `tests/readme` and the README are the only ones in the tree, and
      both move in SPARQL-T-0032.
- [ ] **No `store:` import anywhere**, and `make check` green on every
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

**`snapshot_term` borrows** — the dictionary arena or a caller-provided
`Term_Buf` bounded by `record.INLINE_LEXICAL_MAX`. The `Query`'s
materialized-term table must clone what it keeps, and closing the store
frees the arena, so anything outliving a store owns its terms. This is
the same contract kvstore had for a different reason; do not assume the
old ownership code is right just because it looks right.

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

*To be added during implementation*
