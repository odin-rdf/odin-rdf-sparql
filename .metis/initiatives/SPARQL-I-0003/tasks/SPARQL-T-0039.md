---
id: the-record-of-the-port-vision
level: task
title: "The record of the port: vision, backlog reconciliation, the GRAPH evidence, the family file"
short_code: "SPARQL-T-0039"
created_at: 2026-08-24T20:42:47.016932+00:00
updated_at: 2026-08-24T20:42:47.016932+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0034", "SPARQL-T-0035", "SPARQL-T-0038"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
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

- [ ] **`.metis/vision.md`** amended. A dated block at the head of
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
- [ ] **The backlog is reconciled**, not left reading as open:
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
- [ ] **The GRAPH evidence filed with odin-rdf-record**, with
      SPARQL-T-0036's numbers rather than speculation: `RECORD-A-0004`'s
      G-residual permutations make `GRAPH <g> { … }` a scan where a
      graph-first index gave a prefix, this is a first-class SPARQL
      operator, and the deployment shape is ~200 processes per machine.
      Filed as an evidence-backed backlog note under the family's
      "capability gaps become evidence, not workarounds" convention —
      **not** as a request, and not as a precondition for anything.
      Cross-repository filing is discussed with the owner first.
- [ ] **`README.md`** updated: dependencies, the collections, no width
      matrix, the quick start mirroring `tests/readme` verbatim, scratch
      stores over `Mem_FS`, the POSIX-only note with the `mem_file_ops`
      answer, and `make bench` being two builds.
- [ ] **Source comments** swept for store-era prose. The known
      stragglers: `sparql/exec.odin`'s `Triple_Reader` note,
      `sparql/expr_eval.odin`'s synthetic-id history,
      `sparql/plan.odin`'s `join_order` seam comment,
      `tests/w3c/harness/dataset.odin`'s memstore history,
      `tests/w3c/README.md`. Deliberate historical references may stay —
      mark them as history rather than deleting the record.
- [ ] **Family side** (`odin-rdf/.github`, the family root, its own git
      repository): the sparql section rewritten for what this engine now
      is; the record section's "shacl's port is done; sparql's is next"
      updated to say both are done; the intro's LMDB sentence and the
      dependency diagram amended, since after this port **nothing in the
      family links LMDB** and odin-rdf-store is retirable; the
      sibling-checkout and dual-width conventions updated. Note the Metis
      MCP reports no active workspace at the family root — edit the file
      directly.
- [ ] **A handoff for whoever retires odin-rdf-store**, since this port
      is the last thing that was holding it: what remains pointing at it
      across the family, and what "retire" should mean concretely.
- [ ] **Every claim in the amended documents checked against the built
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
