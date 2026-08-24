---
id: port-to-odin-rdf-record-the-query
level: initiative
title: "Port to odin-rdf-record: the query engine moves off odin-rdf-store"
short_code: "SPARQL-I-0003"
created_at: 2026-08-24T19:22:39.833634+00:00
updated_at: 2026-08-24T21:21:26.025273+00:00
parent: SPARQL-V-0001
blocked_by: []
archived: false

tags:
  - "#initiative"
  - "#phase/active"


exit_criteria_met: false
estimated_complexity: L
initiative_id: port-to-odin-rdf-record-the-query
---

# Port to odin-rdf-record: the query engine moves off odin-rdf-store Initiative

## Context **[REQUIRED]**

On 2026-08-20 the family decided to move odin-rdf-shacl, and after it this
repository, off odin-rdf-store and onto **odin-rdf-record** — the
tamper-evident system of record (append-only hash-chained log, replayed into
a memory-resident projection serving epoch-pinned snapshots) — and to retire
odin-rdf-store once both ports are done. shacl's port landed the same day
(`SHACL-I-0004`, seven tasks); **this is the second and last one**, and the
store's retirement follows it.

The governing stance, stated once in `RECORD-I-0003` and inherited here: **the
siblings adapt to the record store, not the reverse.** record changed only
where record was wrong or untyped — three tags came out of shacl's port
(`v0.2.0` ingest set-semantics, `v0.3.0` distinct id types) and nothing else.
This initiative holds to that with one deliberate exception, decided below and
by the owner: triple terms, which record's own design reserved a tag byte for
and left unbuilt pending a consumer.

The starting point is not a blank page. `SHACL-T-0037`'s Status
(`odin-rdf-shacl/.metis/initiatives/SHACL-I-0004/tasks/SHACL-T-0037.md`) is a
written handoff addressed to this initiative's author: what shacl's port cost,
the call-site transformation patterns that worked, the record facts an engine
must know, and the explicit instruction that shacl's governing decisions were
made *for shacl* and that sparql asks the owner rather than assuming. That was
done — see the four decisions below. `RECORD-I-0003`'s Status carries the
seven-point API mapping and the CI list; the family `CLAUDE.md`'s record
section carries the rest. Read all three before designing further.

### The owner's four decisions, 2026-08-24

Asked before this document was written, because each one changes the work:

1. **The stance carries over in full.** No dual-backend goal at any point;
   odin-rdf-record is the one and only store, forever. Every seam that existed
   to span backends is deleted rather than re-instantiated — `sparql/kvstore`,
   the parapoly `$MATCH`/`$NEXT`/`$DESTROY` binding, the harness `Backend`
   enum, the `store:` collection, the `Term_ID` width matrix. Where targeting
   record directly makes the code simpler, faster or smaller, that path is
   taken.
2. **The port is gated on record gaining triple terms.** Rather than accept
   the loss of SPARQL 1.2 triple-term evaluation as a recorded backend limit,
   the owner chose to make record able to store them. This initiative is
   therefore **blocked on record-side work** (§6 below), filed the same day as
   **`RECORD-I-0004`** — *RDF 1.2 term kinds: triple terms and base direction,
   for the SPARQL port* — with this repository named as the consumer.
   Base-direction literals are bundled into the same ask.
3. **One larger initiative, not several small ones.** The planner surface —
   `SPARQL-T-0028` (cardinality-ordered joins) and `SPARQL-T-0029` (ordered
   iteration) — is **folded into this initiative** rather than deferred to a
   follow-on. Both were filed against odin-rdf-store procedures that will not
   exist after this port, and record answers both better than the store did
   (§9). There are no production installations to consider.
4. **A `bench/` is built inside the port.** This repository has none today, so
   the one known performance regression (§12) is unmeasurable and any claim
   about the port's cost would be speculation. shacl paid this cost inside its
   own port for the same reason.

### What this repository consumes today — the survey, 2026-08-24

A demolition survey, not a parity checklist. Measured, not recalled.

- **The baseline is green and was re-run for this document.** `make test`
  passes at both `Term_ID` widths: 278 tests per width (`sparql` 102,
  `sparql/srj` 6, `sparql/srx` 7, `sparql/kvstore` 80, `tests/guards` 9,
  `tests/w3c/harness` 71, `tests/readme` 3), and **512 of 512 evaluated W3C
  entries pass across 37 enabled directories** (12 further entries in those
  directories are syntax or Update entries, accounted for and not evaluated).
  Three vendored directories are not enabled — `sparql10-expr-builtin`,
  `sparql10-i18n`, `sparql11-subquery`, 44 entries between them. That 512 is
  the number this port must still show at the end.
- **The core** (`sparql`) reaches storage through two seams, both built to span
  backends. The **parapoly binding**: `Exec($D, $It)` in `sparql/exec.odin`
  (2406 lines) and the plan builder in `plan.odin` (2040 lines) are generic
  over the dataset handle and the iterator, with `$MATCH`, `$NEXT` and
  `$DESTROY` threaded through nearly every operator as procedure parameters.
  The **vocabulary**: 22 files import `store:store` for 449 references over 52
  distinct names — `store.Term_ID` (134), `store.UNBOUND` (61),
  `store.Match_Pattern` (24), `store.Encoded_Quad` (19), `store.WILDCARD`
  (12), `store.DEFAULT_GRAPH` (6), `store.id_kind` (4),
  `store.SENTINEL_CONSUMER_FIRST` (1, load-bearing — see §5).
- **The instantiation** (`sparql/kvstore`) is 4344 lines: `eval.odin` is the
  492-line library that binds the seams, and the other 3852 lines are nine
  test files that exist only because there is an instantiation to test. All of
  it is deleted by this port.
- **The harness**: `tests/w3c/harness` builds datasets with
  `kvstore.open_ephemeral` + `load_turtle`/`load_triples`/`load_trig`/
  `load_quads`, and `tests/guards` and `tests/readme` do the same at smaller
  scale. `load_turtle` appears 23 times, `open_ephemeral` 20.
- **The syntax suites touch no store at all** and cannot be moved by this
  port: `sparql11-syntax-query` (94), `sparql12-syntax` (6),
  `sparql12-syntax-triple-terms-positive` (113) and `-negative` (65) are
  parse-only. That is worth stating precisely because it bounds what triple
  terms are at risk: **158 triple-term syntax tests are unaffected** (178 pinned
  entries, 20 of them Update and out of engine scope); the exposure is the **38
  evaluated entries of `sparql12-eval-triple-terms`** (41 pinned, 3 Update).
- **CI** pins `odin-rdf-parser@v0.1.0` and `odin-rdf-store@v0.6.0` as sibling
  checkouts; the `Makefile`'s `COLL` declares `rdf:` and `store:`, mirrored in
  `ols.json`; `WIDTHS := 64 32` drives the matrix. The store checkout and the
  `store:` collection are removed, not joined.

### What already exists here, and what a fresh session should read first

Checked on 2026-08-24, so a session starting cold does not rediscover it.
The family checkout root is the parent directory: `../odin-rdf-record`,
`../odin-rdf-parser`, and `../odin-rdf-shacl` — whose completed port
(`SHACL-I-0004`) is the precedent this one follows.

- **The backend-spanning seams are six named procedure types, not two.**
  The `$MATCH`/`$NEXT`/`$DESTROY` parameters are the visible half; the
  rest are `#type proc` declarations in the core, each one an indirection
  that exists so `sparql` could name no backend, and each one retired by
  owner decision 1: `Term_Resolver` (`sparql/construct.odin:46`),
  `Term_Loader` and `Exists_Runner` (`sparql/expr_eval.odin:34`, `:45`),
  `Path_Expander` and `Triple_Reader` (`sparql/exec.odin:234`, `:257`),
  and `Term_Finder` (`sparql/plan.odin:548`). **That list is
  SPARQL-T-0031's checklist** — more useful than "the compiler will tell
  you", because the compiler will not tell you that an indirection is
  *unnecessary*, only that it does not compile.
- **`tests/w3c/harness/zz_survey_test.odin` is the instrument for the
  hard part.** It runs every entry of every vendored suite and reports
  pass / mismatch / unsupported / failed per directory, **asserting
  nothing so it cannot fail**. Its own comment says it exists because
  every enablement decision in SPARQL-T-0012 and T-0013 came out of it —
  it turns "which directory is one bug from green" from a guess into a
  measurement. During SPARQL-T-0033 it is the difference between a
  failing suite and a diagnosis. It also calls `evaluate_entry(…,
  .Kvstore)`, so it ports with the rest.
- **`readers_test.odin` loads every vendored suite's data into a real
  store** (`:232`–`:235`, via `Test_Dataset` + `load_entry_dataset`) —
  including directories the evaluator does not enable. That is a trap
  for this port: see SPARQL-T-0033.
- **`UPDATE_ENTRIES :: 3` is pinned in `readers_test.odin`** and is
  exactly the three SPARQL Update entries inside
  `sparql12-eval-triple-terms` — which corroborates this document's
  38-evaluated-of-41-pinned split from a second place in the tree.
- **The harness's other files are already backend-free.** Only
  `dataset.odin`, `eval_runner.odin` and `readers_test.odin` import
  `store:store`; `expected.odin`, `graph.odin`, `manifest.odin`,
  `results.odin`, `srj.odin`, `srx.odin`, `xml.odin` and `rsvocab.odin`
  need nothing from this port.

**Process** is the family's usual: the `metis` CLI from the repo root
(`metis transition <CODE> <phase>`, `metis sync` after editing a
`.metis/*.md` file directly), annotated tags as `Release vX: title`, and
**no push unless the owner says so**. Cross-repo edits are discussed with
the owner before being made on a sibling's side; the Metis MCP reports no
active workspace at the family root, so `CLAUDE.md` there is edited
directly.

**Size.** Ten tasks. odin-rdf-shacl's whole port was seven tasks in one
day, but its seam was one struct of four verbs where this one is
parapoly through the executor — SPARQL-T-0031 alone is larger than
shacl's equivalent, and three of these tasks (T-0036 … T-0038) are work
shacl had no counterpart for.

### Why this port is bigger than shacl's

Three reasons, each of which shapes the plan: the seam is load-bearing rather
than vocabulary-deep (shacl imported `store:store` for `Term_ID`, sentinels and
`id_kind`, and bound its backend through one struct of four verbs — this engine
is generic over the backend all the way down); the corpus is five times larger
and carries term kinds record refuses; and this initiative folds in two
capability-consuming tasks that shacl had no counterpart for.

## Goals & Non-Goals **[REQUIRED]**

**Goals:**

- **odin-rdf-record is the backend, targeted directly.** The dependencies after
  this initiative are odin-rdf-parser and odin-rdf-record. `store:` is gone from
  the `Makefile`, `ols.json`, CI and every import; no LMDB in any link; no
  `Term_ID` width matrix.
- **512 of 512 evaluated entries green across the same 37 directories**, at the
  same standard as today: no skip list, no expected-failure file.
  `sparql12-eval-triple-terms`'s 38 evaluated entries are inside that number —
  that is what the gate in §6 buys.
- **Simpler, not parallel, and no store abstraction at all.** The parapoly
  binding and the 64-bit `Term_ID` vocabulary go with the backend they spanned.
  `sparql/kvstore` disappears rather than being re-instantiated as
  `sparql/record`. No replacement abstraction is designed, and none is to be
  reintroduced.
- **A query is one snapshot, still** — the property `SPARQL-T-0024` established
  and `SPARQL-T-0025` pinned. On record a read handle *is* a snapshot, so the
  store/transaction split collapses into it rather than being reproduced.
- **As-of queries still cost this engine nothing**, via `store_at(epoch)` where
  the store used `txn_begin_as_of`. `SPARQL-T-0025`'s scenarios survive the port
  as tests, translated.
- **The planner surface consumed** (§9): `join_order` orders a BGP by
  `range_len`, and the four operators of `SPARQL-T-0029` take the order record
  can be asked for. No evaluation result changes.
- **A `bench/` that measures what this port claims** (§10), including the
  GRAPH case of §12.
- **The record of the port**: vision Current State and success criteria amended
  under dated notes (several name odin-rdf-store and are falsified by this
  port), the backlog reconciled (`SPARQL-T-0026`, `-T-0028`, `-T-0029` all name
  store procedures that will not exist), and the family `CLAUDE.md` amended.

**Non-Goals:**

- **Changing odin-rdf-record beyond the §6 ask.** That one exception is the
  owner's decision and is scoped to what record's own design already reserved.
  Anything else discovered becomes an evidence-backed note for record's
  backlog, never a workaround and never a precondition.
- **Keeping any store-era compatibility**: no transitional dual build, no
  store-shaped shim over record, no deprecation window. There are no
  deployments; the suites are the only consumer and they move in the same
  motion.
- **Retiring odin-rdf-store itself** — a family-level act that follows this
  port. This initiative ends *this repository's* dependency on it, which is the
  last one.
- **SPARQL Update, the HTTP and Graph Store protocols, federation, full-text.**
  Unchanged by the port and still out of scope by the vision. Note that record's
  `apply` would make Update newly *expressible* — that is an observation for a
  future initiative, not a goal here.
- **Enabling the three vendored-but-unenabled directories.** `sparql11-subquery`
  is blocked on RDF/XML, which odin-rdf-parser declines by decision; the other
  two are their own question and not this port's.
- **SHACL-SPARQL.** odin-rdf-shacl's remaining phase consumes this engine; it is
  unaffected except that it will find a sibling on the same store, which is
  simpler than the alternative.

## Detailed Design **[REQUIRED]**

To be settled fully in the design phase; what is already known, with the lean or
the decision where one exists. The test for every choice is the owner's rule:
simpler, faster or smaller by targeting record directly beats parity with
anything.

**1. Ids: `record.Term_ID` natively.** The engine drops `store.Term_ID` for
record's distinct `Term_ID` (a `u32` underneath). Every resident id halves —
solution rows, join keys, path frontiers, group keys, the `Encoded_Quad`
equivalent — and no widen/narrow layer is ever written. shacl's equivalent
adaptation was 105 sites and one mechanical commit; this repository's is larger
(134 `store.Term_ID` references plus everything typed by inference) but the same
in kind. **Hold `record.Term_ID`, `record.Fact_ID` and `record.Epoch` as the
distinct types they are** — that is what `v0.3.0` exists for, and an engine
holding raw `u32` does not compile against it.

**2. The seams: collapsed — decided (owner decision 1).** The parapoly binding
exists so the core could name no backend, and that property is retired by
decision rather than merely unexercised. `Exec` loses `$D` and `$It` and holds a
`record.Snapshot` and `record.Scan`; `MATCH`/`NEXT`/`DESTROY` become direct calls
to `snapshot_match` + `range_iter` + `scan_next`. **The dividend is larger than
the deletion.** `sparql/kvstore/eval.odin` documents two adapters —
`exists_adapter` and `expand_adapter` — that exist solely because an expression
calling back into the generic executor "would complete a cycle of generic
instantiations that the compiler cannot close". With one concrete executor the
cycle closes and both disappear, along with the monomorphization of every
operator. `sparql/srj` and `sparql/srx` are untouched; they never named a
backend.

**3. One package.** Everything lands in `sparql`, importing `rdf:rdf` and
`record:record` (plus `record:record/ingest` in the suites). The
core/instantiation split guarded exactly one property — that the core names no
backend — and that criterion is retired with a dated note. Design-phase
question, small: whether `sparql/srj` and `sparql/srx` stay separate packages
(lean: yes — they are output formats, not instantiations, and were never part of
the seam).

**4. The session over a snapshot, one constructor, and the sentinel remapping.**
**Decided 2026-08-24: there is exactly one constructor,
`query_init(q, algebra, snapshot, base)`, and `query_init_txn` is deleted.** The
distinction the two drew was who owns the handle, and record collapses it — a
snapshot is a snapshot whether it came from `store_latest`, `store_at`, or a
`Validator`'s candidate at the new epoch. The consumer that motivated
`query_init_txn` (one judging whether a candidate may join the dataset) is served
by record's `Validator` hook handing it exactly that snapshot, so SHACL-SPARQL
querying a candidate is the ordinary call rather than a second entry point. A record read
handle *is* a snapshot (acquire, use, release; `store_latest`/`store_at`), so
`Session`'s two fields both go: the transaction becomes the snapshot itself, and
the error slot becomes nothing — **a read on record cannot fail**, the
projection being resident, so the `query_error` path and every `err != nil`
check the kvstore adapters carry are deleted rather than ported (shacl deleted
the same machinery and found no consumer for it). The sentinel mapping is the
delicate part and needs a design-phase pass over all 79 `store.UNBOUND` /
`store.WILDCARD` / `store.DEFAULT_GRAPH` sites:

- `store.UNBOUND` and `store.WILDCARD` are distinct in the store and both become
  `0` in record — `0` is unbound in a `Pattern`, and an unbound row slot has to
  be `0` too if a row slot can be copied into a pattern position.
- **`store.DEFAULT_GRAPH` splits in two, and this is the one real hazard.** In a
  *pattern*, binding the default graph is `MATCH_DEFAULT_GRAPH`
  (`0x8000_0000`). In a *fact*, the default graph is stored as `G = 0` — which
  is also "unbound". Any path that reads a quad's graph component into a row
  slot (`Plan_Graph_Bind` from `SPARQL-T-0020`, `Plan_Graph_Scan`'s enumerator
  at `exec.odin:875`, `unify_quad`) must not let a default-graph fact bind `?g`
  to something indistinguishable from unbound. `GRAPH ?g` ranges over the *named*
  graphs and the default graph has no name to bind, so the correct behaviour is
  the skip that is already there — but it must be a skip on `0`, deliberately,
  with a test, rather than an accident of the constant's value.

**5. Synthetic term ids: a range test, not a threshold test.** `SYNTHETIC_FIRST`
becomes `record.CONSUMER_ID_FIRST`, the range record reserved for exactly this
(`CONSUMER_ID_FIRST ..= CONSUMER_ID_LAST`, `0x8000_0001 ..= 0x8FFF_FFFF`). But
`is_synthetic` currently reads `id_kind(id) == .Sentinel && id >=
SYNTHETIC_FIRST`, and **on record a bare `>=` is wrong**: record sets bit 31 on
every *inlined literal*, so ids above the consumer block are ordinary terms. The
test must become a bounded range check against both ends. This is the same class
of bug as `SPARQL-T-0027` — a term space read off a neighbouring constant — and
it is being written down before it happens rather than after. record's reserved
range is also the direct answer to the gap `SPARQL-T-0019` recorded ("an engine
that has to invent a term space because the store has no query-local one is
describing a gap in the interface"); the note in `expr_eval.odin` gets amended to
say so.

**6. Triple terms — the prerequisite (owner decision 2).** record's term format
has no encoding for a triple term and `apply` refuses one with
`.Unsupported_Term`; 20 of the 25 data files in `sparql12-eval-triple-terms`
carry `<<`. **This is not a frozen decision being reopened.** `record/term.odin`
already reserves `0x07` for RDF 1.2 triple terms, citing architecture.md §11.3,
which specifies the encoding outright — `0x07 | sID | pID | oID` — and closes
with: *"the only decision needed today is whether to reserve the tag byte, which
costs nothing and preserves the option."* This port is the consumer that brings
the deferred decision due. The record-side ask, being filed on record's side
with this repository as the named consumer:

- tag `0x07` in `term_encode`/`term_decode`, a recursive intern that defines
  components before the triple term (first-appearance order already gives that),
  `.Triple` added to `snapshot_kind`, and the format-version question left to
  record's design gate (record's own no-migration precedent applies; there are
  no deployments);
- **base-direction literals bundled in** (owner decision 2, second half) —
  refused today by the same `.Unsupported_Term`. Note precisely what this
  does and does not buy here: `sparql12-lang-basedir` is run as a
  **syntax** suite (`harness_test.odin:64`, 11 entries, parse-only and
  already green), so a base-direction literal never reaches a store in
  this engine today. Bundling it removes a latent limit and costs one
  format question instead of two — it does not unlock an evaluation
  directory, and this initiative should not claim it does;
- and the argument that this *also* closes a piece of this repository's recorded
  store evidence: `sparql/kvstore`'s `triple_adapter` materializes a whole term
  and re-resolves each component — "two round trips through the database for
  something the dictionary knows outright", filed as `SPARQL-T-0019` — whereas
  an encoding that holds the three component ids makes taking a triple term
  apart a read of three ids. The capability record is being asked for is
  *cheaper* here than the one being left behind.

Sequencing: everything else in this initiative can proceed against record
`v0.3.0`; only the final suite-green criterion needs the release that carries
triple terms, and the CI pin moves to it at the end.

**7. Term identity: three shifts, and one of them is new here.** From shacl's
port, inherited: language tags **fold to lowercase on intern**, and a
non-canonical numeric lexical form (`"01"^^xsd:integer`) is a *different term*
from the inlined canonical one. Both are RDF term identity; value equality
remains the engine's job and is unchanged. What is new for this repository:
**sparql renders terms in its output** — `sparql/srj` and `sparql/srx` write
language tags into results, and the corpus is five times shacl's. shacl found
exactly two uppercase-tagged literals and neither reached an expected report; the
handoff says in as many words that sparql must check rather than assume. The
design phase runs that check over the corpus, and `SPARQL-T-0021` (the family
term-identity question) gets re-read in the light of a store that has now decided
the language-tag half.

**8. The harness.** Per the shacl patterns, which are known to work: a harness
store type holding `Mem_FS` + `store_open(&s, "x", mem_file_ops(&fs))`, loading
each document with `ingest.<format>(src, graph, allocator, blank_prefix, base)` +
`apply` + `ops_destroy`, pinning the head snapshot, releasing before
`store_close` — and **never copied or moved after open**, because the writer
points at the `Mem_FS` inside. `blank_prefix` is the load scope and must be label
characters (`t1_`, not `t1/`). `base` is needed for the W3C documents' relative
IRIs; this harness already computes exactly that string for `load_turtle`.
`Test_Dataset` in `tests/w3c/harness/dataset.odin` and the runner's own loading
path in `eval_runner.odin` converge onto one loader, since the reason they were
separate (two backends, two instantiations) is gone. The `Backend` enum and its
dispatch go; `run_eval_suite`'s signature loses its parameter. Two record facts
the fixtures must respect: **a candidate is the delta** (re-asserting a live quad
is `.Already_Live`), and **`ingest` emits a document's set**, so a document
stating a triple twice loads.

**9. The planner surface, folded in (owner decision 3).** `SPARQL-T-0028` and
`SPARQL-T-0029` were filed from the store side against `estimate`/`estimate_txn`
and `match_order`/`match_orderable`/`match_ordered`. Those procedures leave with
the store, and **record answers both asks in better form**:

- *Cardinality.* `range_len(r)` is an **exact** candidate count in O(1) —
  arithmetic on a window, the binary searches already paid by `snapshot_match` —
  and therefore an exact upper bound on visible matches. `SPARQL-T-0028`'s whole
  "a declined estimate is handled explicitly" criterion, built around
  `ESTIMATE_UNKNOWN`, **evaporates**: record does not decline. The acceptance
  criteria are rewritten accordingly; the substance — a stable ordering by
  ascending count, no result changes, and a test that the reordering *happens*
  rather than is merely permitted — survives intact.
- *Ordered iteration.* `snapshot_match_as(snap, p, order)` lets the planner name
  the permutation outright, and `Range.order` reports what it got. That is
  strictly more than `match_orderable`'s yes/no: **any order answers any
  pattern**, only the window width differs, so the operator never has to fall
  back — it chooses. `SPARQL-T-0029`'s four consumers (MIN/MAX in one read, a
  streaming `Plan_Order`, `ORDER BY … LIMIT n` stopping at n, and the
  fallback rule) port onto it directly. The one caveat record names and this
  engine must respect: **ordering by term is not ordering by value** — dictionary
  ids are in first-appearance order, so only inlined numerics sort correctly by
  id (api.md §12.8). The streaming path is available for exactly the cases where
  SPARQL's `ORDER BY` and record's id order agree, and the plan must decide that
  at build time from the pattern and the sort key, never from the data.

Both are held to the same standard as the rest of the port: **no evaluation
result changes.** 512/512 before and after. A changed answer means the
reordering is not order-independent, which is an evaluator bug rather than a plan
one.

**10. `bench/`, in two steps — before the port and after (owner decision 4,
resequenced 2026-08-24).**

**The resequencing is the important part.** The original plan built bench once,
after the port. That would have made this initiative's central correctness claim
unprovable, because odin-rdf-shacl's most valuable port finding — **read counts
survived to the integer**, 7503 and seven other pins identical across memstore,
kvstore and record — was available only because `SHACL-I-0003` built bench
*before* its port. `SHACL-T-0036`'s Status records that its own acceptance
criterion predicted the opposite and asked for the two to be "stated to be
incomparable"; the author had written that into the prose before the first run
and removed it after. Equal counts prove the engine asks the new store exactly
the questions it asked the old one — that the port moved cost and not behaviour.

So: **SPARQL-T-0040** builds bench against the engine as it stands,
instrumenting reads through the five seam adapters in
`sparql/kvstore/eval.odin` — easy today, materially harder once SPARQL-T-0031
collapses that seam — and pinning the counts per case; **SPARQL-T-0036**
rebuilds it against record with the same workload and reports whether the pins
held. Read counting follows shacl's `SHACL_COUNT_READS` shape: a build-time
switch, `make bench` as two builds, because counting inside the timed build
measures the counter. Timings across the two are context, not a target — LMDB
against a resident projection is not like-for-like. The workload covers the
operator classes the port touches (BGP joins, GRAPH, OPTIONAL, aggregation,
ORDER BY, a property path) and the §12 GRAPH case explicitly, at more than one
graph-size ratio.

**11. Build and CI.** `COLL` becomes `-collection:rdf=../odin-rdf-parser
-collection:record=../odin-rdf-record`; `rdf:` stays, because record's own
sources import it and a collection resolves in the importing compilation.
`ols.json` mirrors it. `ci.yml` replaces the `odin-rdf-store` checkout with
`odin-rdf/odin-rdf-record` at the release carrying §6, keeps the parser checkout,
and drops the width override; the pin gets a comment in the style of shacl's
floor history. `WIDTHS`, `PKGS`' kvstore entry and the matrix loop leave the
`Makefile`. The Windows leg compiles record without its POSIX `File_Ops`
(`#+build linux, darwin`) and runs the suites over `mem_file_ops`, which is
platform-free — so all three runners run the same `make test`. No `python3`
needed (that is record's own test-suite dependency, not a consumer's). Adopt
shacl's redundant-import-alias grep in `make check` while the imports are being
rewritten anyway.

**12. The GRAPH cost — the one known regression, and it becomes evidence.**
record has **no graph-first permutation by design** (`RECORD-A-0004`): all six
orders end with `G` as the residual tiebreaker, so a bound graph never enters a
prefix. `GRAPH <g> { ?s ?p ?o }` therefore becomes a full scan of the fact table
with a per-fact residual check, where odin-rdf-store — whose every index was
graph-first — answered it as one prefix range. **Correctness is unaffected**; the
cost is real, it lands on a first-class SPARQL operator, and the deployment shape
is ~200 processes per machine. `sparql10-graph` (17 entries) and
`sparql10-dataset` (12) exercise it. Three consequences: the port measures it
(§10) rather than asserting it; the measurement is filed as an evidence-backed
note on record's backlog under the family's "capability gaps become evidence, not
workarounds" convention, with numbers rather than speculation — and it needs
**both** benches, T-0040's graph-first number and T-0036's G-residual one, since
neither alone is evidence. **Decided 2026-08-24: record's design gate is also
told now**, rather than only at T-0039. `RECORD-A-0004` is the ADR in question
and `RECORD-T-0021` is convening on the format; a short note there, labelled
explicitly as an unmeasured consumer concern and not a request or a
precondition, costs nothing and means the gate closes knowing that a
first-class SPARQL operator lands on that choice. And
**`SPARQL-T-0026` dies here** — it asks for `store.NAMED_GRAPHS`, a sentinel that
leaves with the store, and its problem takes a different shape on record, where
`Filter.graphs` scopes to a set of graphs (`FROM`/`FROM NAMED`) but "every graph
that has a name" is not expressible as a prefix at all. Its backlog entry is
closed with a dated note rather than left reading as open.

## Alternatives Considered **[REQUIRED]**

- **Keeping the parapoly seam and adding `sparql/record` beside
  `sparql/kvstore`** — the shape this repository is built in, and the one shacl's
  initiative drafted before its owner decision. Rejected by owner decision 1:
  dual-backend operation was never a goal, there are no deployments to migrate,
  and parity with the store's interface is cost without a customer. It would also
  preserve the generic-instantiation-cycle workaround (§2) that the collapse
  deletes outright.
- **Keeping the split as code organization only** (core names no backend, one
  instantiation package): a much smaller diff, and it would preserve the vision's
  success criterion literally. Rejected with the above — the criterion protected
  a property no longer wanted, and an indirection nothing exercises is an
  indirection that rots. The criterion is retired with a dated note rather than
  quietly reinterpreted.
- **Keeping the 64-bit `Term_ID` and widening at the record seam** (the record
  handoff's transitional rule): correct for an engine spanning both stores, pure
  overhead for one that spans nothing.
- **A shim implementing odin-rdf-store's match interface over record**, so
  `sparql/kvstore` runs unmodified: a third contract to maintain, and it would
  hide exactly the seams — snapshot values, epoch pinning, ordered ranges, exact
  counts — that §9 exists to use.
- **Accepting the loss of triple-term evaluation** as a recorded backend limit,
  with the engine's triple-term code kept and the suite disabled with a stated
  reason. This was the recommendation put to the owner; **the owner chose to gate
  on record instead**, and the reasoning holds up: record reserved the tag for
  this, the encoding is already specified, and the alternative permanently
  narrows a headline capability of this engine to buy a slightly earlier port.
- **Engine-side encoding of triple terms** (skolemizing them into blank nodes or
  the consumer id range): rejected outright as precisely the backend-specific
  workaround the family convention forbids, and it would break term identity in
  a way the corpus would catch.
- **Deferring the planner surface to a follow-on initiative** — the
  recommendation put to the owner, on the grounds that mixing "the backend moved"
  with "the plan changed" muddies what a red suite means. **The owner chose one
  larger initiative.** The objection is answered by discipline rather than by
  sequencing: §9's work lands *after* the suite is green on record and is held to
  "no evaluation result changes", so the two signals stay separable in the task
  order even though they share an initiative.

## Implementation Plan **[REQUIRED]**

Sequenced so each step ends green; the honest unit of "green" is the step
boundary, not every intermediate commit. Decomposed 2026-08-24 into
SPARQL-T-0030 … T-0040; dependencies are in each task's `blocked_by`:

0. **The record-side prerequisite** (§6) — `RECORD-I-0004`, tracked on record's
   side. Everything below through step 4 proceeds against `v0.3.0` in parallel
   with it; step 5 needs its release.
1. **Plumbing** (SPARQL-T-0030): record checkout, collections, `ols.json`, CI
   leg changes, a smoke test that opens a record store over `Mem_FS` and answers
   one query. Adds only; nothing store-side deleted yet. **In parallel, `bench/`
   against the engine as it stands** (SPARQL-T-0040): the workload, and read
   counts pinned through the seam adapters while that seam still exists. Step 2
   is blocked on it — see §10.
2. **The core ports**: ids to `record.Term_ID`, the seam collapsed to direct
   calls, one package, the session over a snapshot, sentinels remapped (§4),
   synthetic ids range-tested (§5). `sparql/kvstore` and every `store:` import
   deleted in the same motion — the compiler is the checklist. Green boundary:
   `make check` plus the ported non-W3C tests.
3. **The full suite**: the harness onto `Mem_FS` + `ingest` + `apply`, every
   remaining call site, the width matrix and the last `store:` references gone.
   Green boundary: **474 of 474** evaluated entries across 36 directories — every
   enabled directory except `sparql12-eval-triple-terms`, which waits for step 5.
   The term-identity corpus check (§7) is settled here, by running.
4. **As-of preserved**: `SPARQL-T-0025`'s scenarios translated onto `store_at`,
   including the two facts that differ — `store_at` past head is `.Future_Epoch`
   (refused, not clamped) and there is no `epoch_at(wall)`, the epoch being the
   only as-of coordinate.
5. **Triple terms green**: pin the record release from step 0,
   `sparql12-eval-triple-terms` enabled and passing, **512/512 restored**, and
   `triple_adapter`'s two-round-trip note replaced by what the encoding now
   gives directly.
6. **`bench/` rebuilt against record** (SPARQL-T-0036, §10): the same workload
   over `Mem_FS` + `ingest`, read counting rehomed, and the comparison against
   SPARQL-T-0040's pins — did the counts hold?
7. **The planner surface** (§9): cardinality-ordered `join_order`, then the
   ordered-iteration consumers. Held to no result changes, with tests that the
   chosen path is *taken* rather than merely available. `SPARQL-T-0028` and
   `-T-0029` are rewritten against record's API rather than closed.
8. **The record of the port**: vision Current State and success criteria amended
   under dated notes; `SPARQL-T-0026` closed (§12); the README and source-comment
   pass; the GRAPH evidence filed with record; the family `CLAUDE.md` amended on
   the family side.

**Exit:** `make test` green with odin-rdf-parser and odin-rdf-record as the only
dependencies — no `store:` collection, no LMDB in any link, no width matrix;
512/512 evaluated entries across 37 enabled directories; as-of demonstrated
through `store_at`; the planner surface consumed with no result changes; `bench/`
producing the numbers this initiative's claims rest on; CI green on all three
runners; odin-rdf-store's retirement unblocked.

## Status

**2026-08-24, later still — four open questions walked through with the owner
and closed.** Three of them changed the plan:

1. **`bench/` splits in two and the first half moves before the port** (§10;
   SPARQL-T-0040 added, SPARQL-T-0031 now blocked on it). Found by checking
   odin-rdf-shacl's actual numbers rather than trusting this document's summary
   of them: its read-count invariant was obtainable only because bench predated
   its port, and the original single-bench plan would have made the same check
   impossible here.
2. **One query constructor** (§4) — `query_init_txn` deleted, not ported.
3. **The quad representation is decided rather than deferred**
   (SPARQL-T-0031): keep `[4]Term_ID` and copy at the scan boundary, preserving
   `unify_quad`'s dynamic positional loop. Reinterpreting record's
   layout-identical `Quad` was considered and **rejected** — it would couple
   this engine to a sibling's struct field order, where a reorder compiles
   cleanly and corrupts every result.
4. **record's design gate is told about the GRAPH cost now** (§12), unmeasured
   and labelled as such, while `RECORD-T-0021` is open. The evidence filing
   stays at SPARQL-T-0039.

Two smaller ones settled without the owner: `sparql/srj` and `sparql/srx` stay
separate packages (output formats, never instantiations), and `readers_test`'s
store-loading trap is resolved by pinning a named refusal count in the style of
`RDF_XML_DATA_ENTRIES`, which disappears at SPARQL-T-0035.

**2026-08-24, later — active, and the gate moved to where it bites.** The
initiative's own `blocked_by` named `RECORD-I-0004` while it was in discovery;
that is now removed, because nine of the ten tasks proceed against record
`v0.3.0` and only **SPARQL-T-0035** waits — it carries the dependency in its
own `blocked_by`, alongside SPARQL-T-0033. An initiative marked blocked while
its first task is actionable misreports the board; the prerequisite is
unchanged and is stated in Context, §6 and the Implementation Plan's step 0.
The cross-repository reference resolves nowhere automatically: the Metis
workspaces are per-repository, so `RECORD-I-0004` lives in
`../odin-rdf-record/.metis/` and is read from there.

**SPARQL-T-0030 is the actionable task.** It adds only — nothing store-side is
deleted until SPARQL-T-0031 — so the suite is still green at 512/512 when it
ends.

**2026-08-24 — founded.** Survey complete and re-measured (the 512/512 baseline
above was run today, not recalled). The owner's four scoping decisions are
recorded in Context. The record-side prerequisite (§6) is filed as
`RECORD-I-0004` in odin-rdf-record, with this repository named as its consumer;
this initiative's `blocked_by` names it, and the reference is cross-repository —
the Metis workspaces are per-repository, so nothing resolves it automatically.
Awaiting the owner's review of both documents before decomposition into tasks.