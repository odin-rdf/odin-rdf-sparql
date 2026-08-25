---
id: the-record-of-the-port-vision
level: task
title: "The record of the port: vision, backlog reconciliation, the GRAPH evidence, the family file"
short_code: "SPARQL-T-0039"
created_at: 2026-08-24T20:42:47.016932+00:00
updated_at: 2026-08-25T15:20:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0034", "SPARQL-T-0035", "SPARQL-T-0038"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: SPARQL-I-0003
---
# The record of the port: vision, backlog reconciliation, the GRAPH evidence, the family file

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

The port's paper trail, in the family convention: **amend rather than
rewrite**, the old text standing with a dated note saying what moved.
This is not optional cleanup. It is this repository's half of "a release
is not done until its consumers' Current State is re-read", applied to
itself — and it is what the next session, and anyone retiring
odin-rdf-store, will trust.

## Acceptance Criteria

- [x] **`.metis/vision.md`** amended. A dated block at the head of
      Current State says what is true now; the old text stands below with
      dated notes beside each falsified sentence. What the port
      falsifies, at minimum:
      - Purpose: "evaluates against the match interface defined by
        odin-rdf-store", and the three-layer stack diagram.
      - Current State: "every one run against *both* storage backends at
        *both* `Term_ID` widths"; the 2026-08-08 and 2026-08-09
        amendments, which are about store transactions, `NAMED_GRAPHS`
        and `SENTINEL_CONSUMER_FIRST`; the `count`-is-O(1)-at-HEAD
        asymmetry, which is a store fact and does not describe record.
      - Future State: "**Evaluation runs against any odin-rdf-store
        backend through the match interface alone**" — **retired** with a
        dated note, per owner decision 1, naming the narrower surviving
        form. And "the store's planner-support surface … shaped by this
        engine's demonstrated needs" — which is *met*, differently: the
        surface arrived designed for SPARQL rather than shaped by it
        (record's api.md §12 was drafted against "a SPARQL engine will
        eventually sit on this"), and SPARQL-T-0037/38 consumed it.
      - Success Criteria: "**runs against odin-rdf-store through the
        public match interface only — no private hooks**" — retired the
        same way.
      - Constraints: the odin-rdf-store dependency, the `Term_ID` width
        discipline, and "backend binding is compile-time (the store's
        procedure-set convention)".
      - Principles: "**Consume the interface, don't bypass it**" —
        amended rather than retired. It still governs; what changed is
        that there is one store and no interface to be portable across.
      - **The owner's four decisions of 2026-08-24 recorded verbatim**
        where the next session will read them, exactly as odin-rdf-shacl
        recorded its two.
- [x] **The backlog is reconciled**, not left reading as open:
      - **`SPARQL-T-0026`** (`store.NAMED_GRAPHS`) — **closed** with a
        dated note: the sentinel leaves with the store, and the problem
        takes a different shape on record, where `Filter.graphs` scopes to
        a *set* of graphs but "every graph that has a name" is not
        expressible as a prefix at all (`RECORD-A-0004`).
      - **`SPARQL-T-0028`** and **`SPARQL-T-0029`** — closed as
        superseded by SPARQL-T-0037 and -T-0038, with the substantive
        differences named (an exact count rather than a decinable
        estimate; a named order rather than an orderability question).
      - **`SPARQL-T-0021`** (term identity) re-read: record has decided
        the language-tag half by lowercasing on intern, and
        SPARQL-T-0033's corpus findings fold in here. The IRI
        normalization half is untouched and its "do nothing" decision
        stands.
      - **`SPARQL-T-0019`**'s evidence items re-read: the query-local
        term space is answered by record's `CONSUMER_ID_FIRST` range, and
        `triple_parts` by the triple-term encoding (SPARQL-T-0035).
- [x] **The GRAPH evidence filed with odin-rdf-record**, with
      SPARQL-T-0036's numbers rather than speculation: `RECORD-A-0004`'s
      G-residual permutations make `GRAPH <g> { … }` a scan where a
      graph-first index gave a prefix, this is a first-class SPARQL
      operator, and the deployment shape is ~200 processes per machine.
      Filed as an evidence-backed backlog note under the family's
      "capability gaps become evidence, not workarounds" convention —
      **not** as a request, and not as a precondition for anything.
      Cross-repository filing is discussed with the owner first.
- [x] **`README.md`** updated: dependencies, the collections, no width
      matrix, the quick start mirroring `tests/readme` verbatim, scratch
      stores over `Mem_FS`, the POSIX-only note with the `mem_file_ops`
      answer, and `make bench` being two builds.
- [x] **Source comments** swept for store-era prose. The known
      stragglers: `sparql/exec.odin`'s `Triple_Reader` note,
      `sparql/expr_eval.odin`'s synthetic-id history,
      `sparql/plan.odin`'s `join_order` seam comment,
      `tests/w3c/harness/dataset.odin`'s memstore history,
      `tests/w3c/README.md`. Deliberate historical references may stay —
      mark them as history rather than deleting the record.
- [x] **Family side** (`odin-rdf/.github`, the family root, its own git
      repository): the sparql section rewritten for what this engine now
      is; the record section's "shacl's port is done; sparql's is next"
      updated to say both are done; the intro's LMDB sentence and the
      dependency diagram amended, since after this port **nothing in the
      family links LMDB** and odin-rdf-store is retirable; the
      sibling-checkout and dual-width conventions updated. Note the Metis
      MCP reports no active workspace at the family root — edit the file
      directly.
- [x] **A handoff for whoever retires odin-rdf-store**, since this port
      is the last thing that was holding it: what remains pointing at it
      across the family, and what "retire" should mean concretely.
- [x] **Every claim in the amended documents checked against the built
      code** — procedure names, counts, version numbers. The family
      convention is that documents are trusted by the next session, and a
      stale number is worse than a missing one.

## Implementation Notes

### Technical Approach

Documentation only; no library change. Expect `make test` and `make
check` to stay green throughout, and treat a red build as a sign that a
"comment" edit was not one.

The tag is the owner's act and is not gated here. This task leaves the
documents ready for it; the convention is an annotated tag,
`Release vX: title`, with a bulleted body.

Cross-repo pieces — the family `CLAUDE.md`, the GRAPH evidence on
record's side — follow the family convention: discussed with the owner
before filing on a sibling's side.

### Dependencies

Blocked by SPARQL-T-0034, SPARQL-T-0035 and SPARQL-T-0038 — everything
whose outcome this document records.

### Risk Considerations

**The failure mode here is silent and expensive**: a vision that still
claims two backends and a width matrix is what the *next* session
believes. odin-rdf-shacl's equivalent task found claims to amend that
were not in its own acceptance criteria, discovered by reading the vision
in full rather than by working from a list. Do the same — the list above
is a floor.

**Do not rewrite.** The convention everywhere in this family is that the
old paragraph stands as the record of what was true, with a dated note
saying what moved. A tidier document that has lost its history is the
wrong outcome.

## Status Updates

*To be added during implementation*

### 2026-08-25 — the port's paper trail, in three repositories

Documentation only; `make check` and `make test` green throughout, 286
tests and 537/537 across 38 directories unchanged.

**`.metis/vision.md`** — a dated block at the head of Current State (what
the engine is now, the two measured costs of record's design, what the
port gained, and **the owner's four decisions of 2026-08-24 recorded
verbatim**, so the next session reads them here rather than reconstructing
them from an initiative), then a dated note beside each falsified
sentence. Retired: the dual-backend Future State bullet, its Success
Criteria twin, and the `Term_ID` width constraint. Superseded: the
store-facts paragraph, replaced with record's. Amended rather than
retired: **"Consume the interface, don't bypass it"**, which still governs
— what the port removed is portability, not discipline.

**Three amendments the acceptance criteria did not list**, found by
reading the document in full as the Risk section said to:

- The "met without qualification" paragraph, whose middle clause about
  feeding capabilities upstream was *tested to destruction* by this port
  and held.
- The **interface-needs Success Criterion**, which turns out to cover a
  case it did not anticipate: two needs were found to be **unmeetable**
  and were filed as evidence anyway. "Evidence-backed proposal" stretched
  to mean "here is a measured cost of your design, filed as a note and not
  a request", which is the form both findings took.
- The **SPARQL Update deferral**, and this one is a live question rather
  than a note. It reads "deferred until odin-rdf-store exposes mutation
  suited to it" — and record has `apply`, so **the recorded reason has
  expired**. Nothing is proposed and no work is implied; the note exists
  so a future decision does not cite a condition that is already met.

**Backlog reconciled.** `SPARQL-T-0026` closed — the `NAMED_GRAPHS`
sentinel left with the store, and the problem is *harder* on record, where
there is no graph-first index whose tail can simply be cut off; filed with
the GRAPH evidence as one note with two consequences. `SPARQL-T-0028` and
`-T-0029` were closed at their superseding tasks, each with its retired
criteria and the reason. `SPARQL-T-0021` re-read: **both halves moved in
ways it did not predict** — the language-tag half is closed for this
repository and *not by the parser* (record folds on intern), narrowing but
not resolving the family-wide `rdf.equal` question; and the IRI half keeps
its "do nothing" decision while its cited entry turns out to fail for an
entirely different reason, two parsers in this family disagreeing about
dot-segment removal. `SPARQL-T-0019`'s evidence log was already closed by
`SPARQL-T-0035` and gets one correction: of the planner pair it handed
forward, **only `range_len` proved consumable**.

**Filed on odin-rdf-record** (owner approved cross-repository filing):
`RECORD-T-0026`, the GRAPH scan, with `SPARQL-T-0040`'s graph-first
numbers beside `SPARQL-T-0036`'s — neither half was evidence alone, which
is why `bench/` was built before the port; and `RECORD-T-0027`, the
ordered-read gap, which **corrects `api.md` §12.8**: it says numeric
ordering is nearly free while string ordering is not, and numeric ordering
is not free either. Both are labelled evidence, not requests, not
preconditions. Committed in that repository, not pushed.

The most transferable thing in `RECORD-T-0026` is not the timing: **a
consumer instrumenting its own calls cannot see a residual scan at all**,
because `scan_next` filters inside its own loop. This engine's read
counter is precise enough to have reproduced fourteen of sixteen pins to
the integer, and it reported identical numbers for a query whose window
grew eightfold. `range_len` is the only instrument that shows it, and
nothing signposts that.

**Family `CLAUDE.md`** (`odin-rdf/.github`, committed, not pushed): the
intro's LMDB sentence, a second dependency diagram beside the old one, the
sparql section rewritten with the store-era text left beneath it, the
record section's "sparql's is next", the store section headed **RETIRABLE**,
and three conventions — `store:` is declared by nothing, dual-width testing
is retired, and `make bench` being two builds is now two repositories'
shape.

**`README.md`** gains a Benchmarks section: why `make bench` is two builds,
what a pin is for, and why the counter needed a sixth verb.

**The source-comment sweep found the named stragglers already done.** Every
surviving `odin-rdf-store`/`kvstore`/`LMDB` reference in `sparql/`,
`tests/` and `bench/` reads as history — contrastive ("where a kvstore
cursor…"), which is what the convention asks for. `sparql/plan.odin`'s
`join_order` seam comment was rewritten at `SPARQL-T-0037`, and its file
header's claim that the term resolver is "a procedure pointer … a
deliberate exception to the no-dynamic-dispatch rule" — false since
`SPARQL-T-0031` — was corrected there too.

**One claim checked and wrong.** `make test` is **286** tests, not the 289
this session wrote into `SPARQL-T-0038`'s Status and commit message.
Counted rather than summed. Corrected in the documents; the commit message
stands with the slip. This is exactly the failure mode the last criterion
names, and it took verifying to catch.

### Handoff: retiring odin-rdf-store

This port was the last thing holding it. **Nothing in the family depends
on it** — verified rather than assumed: no `Makefile`, `ci.yml` or
`ols.json` in any of the four other repositories declares
`-collection:store=`, and every remaining textual mention across
odin-rdf-record, odin-rdf-shacl and odin-rdf-sparql is a comment
explaining history.

**What retiring should mean, concretely.** The store is not broken. It is
a working, tested, tagged LMDB store that passes its own conformance
suite; what changed is that it has no consumers. So this is a maintenance
decision, and the honest options are *archive* rather than *delete*:

- **Archive the GitHub repository** (read-only) rather than deleting it.
  Its ADRs are cited by name throughout the family's documents —
  `STORE-A-0001` on kind-tagged dense ids, `STORE-A-0002` on the match
  interface as a procedure-set convention, `STORE-A-0006` on the
  single-backend stance, `STORE-A-0007` on transactions, `STORE-A-0008` on
  transaction time — and several of those citations are load-bearing
  explanations of why odin-rdf-record is shaped as it is. A dead link
  there costs more than the repository does.
- **`main` is six commits past `v0.6.0` and those will never be
  released**: `STORE-T-0052`, `-T-0055`, `-T-0056`, `-T-0057`
  (`lookup_term_borrow_txn`), `-T-0058` (`match_feed`). Three of the
  capabilities the family file lists as "unreleased on `main`" — the
  `NAMED_GRAPHS` wildcard, `graphs`, `nodes` — are in that window. Either
  cut a final `v0.7.0` so `main` and the last tag agree, or **say
  explicitly in the repository that `main` carries unreleased work that
  is not going to be tagged**. Leaving it silently ahead is the outcome
  to avoid: the next reader cannot tell whether it is unfinished or
  merely unreleased.
- **Its own Metis has open items** — `STORE-T-0054` (a bug),
  `STORE-T-0026` and `-T-0027` in `STORE-I-0003`. They should be closed
  with a dated "closed: the repository is retired, no consumers" note
  rather than left reading as work someone might pick up.
- **The family `CLAUDE.md` keeps its section**, now headed RETIRABLE with
  the store-era text beneath. Do not delete it: it is the record of the
  layer both engines were built against, and half the design decisions in
  odin-rdf-record are legible only against it.

**What retiring must not mean**: deleting the ADRs, or rewriting the
family's history so that odin-rdf-record looks like it was always the
plan. It was not — the store came first, and both engines were written
backend-independent against it, which is precisely why two ports were
possible at all in a day each.

**Not this task's call, and not this repository's.** Filed here because
`SPARQL-T-0039` was asked for it and because this port is why the question
is live.
