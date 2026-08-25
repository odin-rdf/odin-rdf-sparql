---
id: plumbing-the-record-checkout-the
level: task
title: "Plumbing: the record checkout, the collections, and a store that opens"
short_code: "SPARQL-T-0030"
created_at: 2026-08-24T20:42:25.718435+00:00
updated_at: 2026-08-25T09:38:35.406923+00:00
parent: SPARQL-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---

# Plumbing: the record checkout, the collections, and a store that opens

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Make odin-rdf-record reachable from this repository, and prove it by
opening one and answering one query — before anything store-side is
touched. This task **adds only**. `store:`, `sparql/kvstore` and the
width matrix are all still standing when it ends, and the suite is still
green at 512/512, because the deletion motion is SPARQL-T-0031's and
mixing the two would make a red build ambiguous.

## Acceptance Criteria

- [x] **`Makefile`**: `COLL` gains `-collection:record=../odin-rdf-record`
      alongside the existing `rdf:` and `store:`. `rdf:` stays for good —
      record's own sources import it, and a collection resolves in the
      importing compilation, not the imported checkout.
- [x] **`ols.json`** mirrors the collection set, so the language server
      resolves what the compiler does.
- [x] **`ci.yml`** checks out `odin-rdf/odin-rdf-record` as a sibling
      directory (`actions/checkout@v5`, `repository:`/`ref:`/`path:`) at
      ~~**`v0.3.0`**~~ **`v0.4.0`**, beside the existing parser and store
      checkouts. The pin gets a comment in the style of odin-rdf-shacl's
      store-floor history, recording *why* `v0.3.0` is the floor:
      `v0.2.0` for `ingest`'s set semantics (RECORD-T-0019), `v0.3.0` for
      the distinct `Term_ID`/`Fact_ID`/`Epoch` types (RECORD-T-0020).
      **Amended 2026-08-25, owner's call**: the floor is `v0.4.0`,
      because `RECORD-I-0004` — the §6 gate this whole initiative was
      blocked on — landed between this task being filed and being worked.
      Both older reasons are kept in the comment, since they are still
      true and still the reason a lower pin is impossible; `v0.4.0` sits
      above them. See the Status below for why the pin did not stay at
      `v0.3.0` for four more tasks.
- [x] **A smoke test** in a new package: open a store over `Mem_FS` +
      `mem_file_ops`, `ingest.turtle` a two-triple document, `apply` it,
      take `store_latest`, answer one `snapshot_match` and release the
      snapshot before `store_close`. It asserts nothing about SPARQL —
      it asserts that the collection resolves, the library links, and the
      lifetime discipline is understood.
- [x] **The smoke test runs on all three CI runners.** This is the real
      point of the task: record has no Windows `File_Ops` and its POSIX
      file is `#+build linux, darwin`, so a Windows leg compiles record
      only if the suite never names `posix_file_ops`. Proving that now,
      on a 30-line test, is much cheaper than discovering it during
      SPARQL-T-0033 with the whole harness in flight.
      **Green on all three, run 32832865466.** Read from the Windows
      job's own log rather than from the run's colour: it checked out
      `odin-rdf-record` at `435c2b3`, vetted `tests/smoke`, and ran
      `Finished 2 tests … successful` **twice**, once per width. No link
      error, no missing `File_Ops` — the `#+build linux, darwin` line on
      `record/writer_posix.odin` does the whole job, and nothing here
      names `posix_file_ops`.
- [x] `make test` still green at both widths, 512/512 — nothing removed
      yet.

## Implementation Notes

### Technical Approach

The new package is the whole design decision here. Put it where it can be
deleted later without ceremony (`tests/smoke/` is the lean, matching
odin-rdf-shacl's) and add it to `PKGS` so `make test` and `make check`
both see it. It builds against `record:record` and `record:record/ingest`
and must not import `sparql` at all — a smoke test that needs the engine
to compile is not testing the plumbing.

Two record lifetime rules the smoke test exists to encode, both of which
cost odin-rdf-shacl a debugging session:

- **The store must not be copied or moved after `store_open`.** The
  writer holds a pointer to the `Mem_FS` living inside it, so returning
  one by value segfaults. Declare it in place; pass `^Store`.
- **Every snapshot is released before `store_close`.** `store_destroy`
  asserts it.

`blank_prefix` must be label characters (`t1_`, not `t1/`) — the rule
matters the moment anything is dumped and re-ingested, and starting
correct is free.

### Dependencies

None. First task of the initiative.

### Risk Considerations

**The Windows leg is the one that can actually fail here**, which is why
it is an acceptance criterion rather than an assumption. odin-rdf-shacl's
first record CI run also failed for an unrelated reason worth knowing:
the record repository was private at the time. It is public now, but if
the checkout step fails, check that before debugging the build.

Low risk otherwise: nothing is deleted, so the worst outcome is a task
that does not finish rather than a repository that does not build.

## Status Updates

### 2026-08-25 — the plumbing is in, and the pin came out a release higher than filed

`Makefile`, `ols.json` and `ci.yml` carry `record:`; `tests/smoke` is a
new package in `PKGS`; `make check` is clean and `make test` is green at
**both widths, 512/512 across 37 directories**, counted from the run
rather than recalled. Nothing store-side was touched — `store:`,
`sparql/kvstore` and `WIDTHS` are all still standing, which is what
this task's "adds only" discipline is for.

**The pin is `v0.4.0`, not the `v0.3.0` this task was filed asking
for, and the reason is that the gate moved while the task sat.** When
SPARQL-I-0003 was decomposed, `RECORD-I-0004` was unbuilt and the plan
was to pin `v0.3.0` now and bump at SPARQL-T-0035. record then built the
whole thing — `RECORD-T-0021`…`-T-0025`, two ADRs, format version 2 —
and left exactly one thing undone: the tag, deliberately withheld
because `RECORD-T-0025`'s own risk note says *do not tag before a
consumer has built against it*. This task is that consumer. Walked
through with the owner, who chose to tag now and pin the tag rather than
pin a SHA or hold at `v0.3.0` for four more tasks.

Holding at `v0.3.0` was the option with the hidden cost, and it is worth
writing down: the local checkout is at record's head either way, so for
four tasks a new-API call would compile here and fail on CI — and worse,
SPARQL-T-0033's plan to pin *a named refusal count* for the vendored
documents `apply` rejects would have been correct against CI and wrong
against the machine it was written on. That trap is now gone: against
`v0.4.0` the refusal count is zero.

### What this repository verified before the tag was cut

`tests/smoke` is two tests, and the second is deliberately more than the
criterion asked for, because it is this repository's **acceptance of
RECORD-I-0004** and a nominal approval would have been worth nothing.

- `record_round_trip` — the plumbing. `Mem_FS` + `store_open`, an
  `ingest.turtle` document, `apply`, `store_latest`, one
  `snapshot_match`, release before close. It also pins **`ingest` emits
  a document's set**: the fixture states one triple twice and yields two
  ops, not three (RECORD-T-0019), which is the fact a harness gets
  bitten by rather than a purist.
- `triple_terms_from_the_corpus` — the gate. It reads
  `tests/w3c/sparql12-eval-triple-terms/data-0-tripleterms.ttl`, **this
  repository's own vendored data file and not a fixture written for the
  occasion**, ingests and applies it (`Apply_Error{}` where the same
  call returned `{.Unsupported_Term, 0}` before), then walks
  `snapshot_triple_parts` down through the nested triple term to the
  inlined `123` at the bottom. That walk is exactly the `Triple_Reader`
  binding SPARQL-T-0031 will make, and it allocates nothing — the
  `triple_adapter` it replaces materialized the whole term and
  re-resolved each component (`SPARQL-T-0019`).

**One finding, and it is the §5 hazard confirmed rather than
predicted.** The innermost component of that nested triple term is an
inlined `"123"^^xsd:integer`, and the test now asserts that its id is
**`>= record.CONSUMER_ID_FIRST`**. So an ordinary term — not a
consumer-space one — sits above the consumer range's floor, which means
`is_synthetic`'s current `id >= SYNTHETIC_FIRST` threshold test would
call it synthetic. SPARQL-I-0003 §5 wrote that down before it happened;
it is now a passing assertion in the suite rather than a paragraph, and
SPARQL-T-0031 inherits a test that fails if the range check is written
as a threshold.

### Two smaller things, recorded so nobody re-derives them

- **`make test` warns once per width** that
  `-define:RDF_STORE_TERM_ID_BITS is unused` when it reaches
  `tests/smoke`. That is correct and not worth silencing: the package
  names no store, so the store's width define has nothing to bind to. It
  disappears with `WIDTHS` at SPARQL-T-0033.
- **`os.read_entire_file` needs its allocator argument** in this Odin
  version — the one-argument form no longer resolves, and the second
  return is an `os.Error` rather than a `bool`. The W3C harness already
  calls it the right way; a new file copying the older shape does not
  compile.

### The tag, cut

`v0.4.0` is an annotated tag at record's `3692aac`, with
`RECORD-T-0025`'s prepared body plus a line recording that this
repository built against it first. It is at HEAD rather than at the
source commit `77982ce` on purpose: `v0.3.0` was cut one commit early
and missed `RECORD-T-0020`'s Status, which that task's own title records
as a regret.

### 2026-08-25 — pushed, and green on all three runners

Run
[32832865466](https://github.com/odin-rdf/odin-rdf-sparql/actions/runs/32832865466):
ubuntu, macOS and **windows** all `success`. The Windows leg is the one
this task existed to prove, and it was checked in its own log rather
than taken from the run's conclusion — record checked out at `435c2b3`,
`tests/smoke` vetted, and both tests run at both widths. The task is
complete.

**A finding from pushing, and it is a process one worth keeping.**
record's `main` and the `v0.4.0` tag were *already on GitHub* when the
push was attempted — the tag at `435c2b3`, which is this session's
record-side commit before it was amended. The amend had added one more
paragraph (RECORD-I-0004's closing Status) to an object that was already
published, so the push was correctly rejected as non-fast-forward. It
was resolved by **re-landing the amended paragraph as a new commit and
leaving the tag alone**, not by forcing: a published tag is not moved,
and the consequence — that `v0.4.0` holds every source and document
change of RECORD-I-0004 but not the paragraph announcing its completion
— is recorded in that initiative rather than repaired. The general rule
this ran into: **amend only what is provably unpushed, and re-check
immediately before the amend rather than relying on a check from
earlier in the session.**

**Also observed, and not acted on:** odin-rdf-record still has no CI of
its own, and it now has a consumer pinning a tag of it. Every claim
about that release having been proven on three platforms is a claim this
repository's CI makes, not record's. Worth someone's attention; it is
not this task's scope and not this initiative's.