---
id: triple-terms-green-pin-the-record
level: task
title: "Triple terms green: pin the record release, restore 512 of 512, read the parts directly"
short_code: "SPARQL-T-0035"
created_at: 2026-08-24T20:42:40.933827+00:00
updated_at: 2026-08-24T20:42:40.933827+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033", "RECORD-I-0004"]
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---
# Triple terms green: pin the record release, restore 512 of 512, read the parts directly

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Close the gate. Pin the odin-rdf-record release that carries RDF 1.2
triple terms (`RECORD-I-0004`), re-enable `sparql12-eval-triple-terms`,
and restore this engine to **512 of 512 evaluated entries across 37
directories** — the number it has today on odin-rdf-store.

And collect the dividend: `sparql/kvstore`'s `triple_adapter` took a
stored triple term apart by materializing the whole term and re-resolving
each of its three components — "two round trips through the database for
something the dictionary knows outright", recorded as this repository's
own evidence under `SPARQL-T-0019`. record's encoding holds the component
ids, so that becomes three id reads and no lookup at all.

## Acceptance Criteria

- [ ] **The CI pin and the `Makefile`/`ols.json` floor move** to the
      record release carrying triple terms, with the pin comment extended
      to say why the floor moved again — the same running history
      odin-rdf-shacl keeps for its store floor.
- [ ] **`sparql12-eval-triple-terms` is re-enabled**, its "disabled
      because the backend refuses triple terms" note in the source
      deleted rather than left stale, and **38 of 38 evaluated entries
      pass** (41 pinned, 3 SPARQL Update and out of engine scope).
- [ ] **512 of 512 across 37 enabled directories.** The initiative's
      headline criterion, and the point at which the port has lost
      nothing.
- [ ] **The `Triple_Reader` binding reads component ids directly.** No
      `snapshot_term` call, no `rdf.Triple` materialization, no
      re-resolution — whatever entry point `RECORD-T-0024` exposes,
      consumed here. If record ships it as a named procedure, call it; if
      the encoding must be read from `snapshot_bytes`, that is a finding
      worth reporting back rather than parsing a format by hand.
- [ ] **`sparql/exec.odin`'s `.Triple` kind test resolves against
      `snapshot_kind`.** The site left standing by SPARQL-T-0031 now has
      a record kind to test against.
- [ ] **`sparql/kvstore/triple_terms_test.odin`'s subject matter survives
      the port**, moved into `sparql` and rewritten against record. The
      W3C directory is the verdict, but this file is where someone
      *learns* what a triple-term pattern does, and that is worth keeping.
- [ ] **Nesting is exercised.** The corpus contains
      `<< _:reifier2 rdf:reifies <<( :a :b :c )>> >>`, whose expansion is
      a triple term one of whose components is itself a triple term.
      Assert that the engine matches and takes apart a nested one — if
      `RECORD-I-0004` got the recursion wrong, this is what finds it.
- [ ] **`SPARQL-T-0019`'s evidence note is closed with a dated amendment**
      recording that the ask was answered, by which record task, and what
      it cost (nothing here — the capability arrived in the encoding).

## Implementation Notes

### Technical Approach

**What the parser hands over matters and has been checked.**
odin-rdf-parser expands RDF 1.2 reifying triples: `<< :a :b :c >> :q :z`
becomes `_:b rdf:reifies <<( :a :b :c )>> . _:b :q :z .`. So a triple term
reaches the store as the **object** of `rdf:reifies`, and the subject of
the outer statement is a blank node. Fixtures written as though the
triple term were the subject are testing the parser's expansion, not the
engine.

**The syntax side needs nothing.** 158 triple-term syntax tests already
pass and never touch a store; they are unaffected by this task and by the
whole port. If any of them moves, something is very wrong.

**Watch the annotation form.** The corpus also carries
`<< :a :b :c ~ _:reifier2 >>`, which names the reifier explicitly rather
than minting one. It is a parser concern, but it produces a different
blank node and therefore a different fixture; the expected results account
for it, so trust the manifest over intuition.

### Dependencies

Blocked by SPARQL-T-0033, and by **`RECORD-I-0004`** — a cross-repository
dependency that nothing resolves automatically, because the Metis
workspaces are per-repository. This is the only task in the initiative
that cannot start until record ships.

### Risk Considerations

**This task is the initiative's schedule risk and its only external
one.** Everything else proceeds against `v0.3.0`; this waits. If
`RECORD-I-0004` stalls, the honest position is a port that is complete
except for one directory, with the reason stated — which is materially
better than where the port would have been without the gate, but it is
not the initiative's exit criterion and should not be reported as one.

**A second-order risk worth naming**: if record's design gate chooses to
restrict triple terms to the object position (`RECORD-I-0004` §4 weighs
it and leans against), a query pattern naming a triple term in the
subject position must still *evaluate* — to no solutions, because no fact
carries one there — rather than fail. Check that the refusal, if any, is
on the write path only.

## Status Updates

*To be added during implementation*


### 2026-08-25 — most of this task is already done

**`sparql12-eval-triple-terms` is enabled and green: 38 of 38, at
SPARQL-T-0033.** This task's criteria were written when odin-rdf-record
refused a triple term at `apply`, so they had the directory disabled
through the port and restored here. `RECORD-I-0004` landed in between —
it was filed *by* this initiative, precisely so the capability would not
be narrowed — and SPARQL-T-0030 moved the pin to `v0.4.0`. The directory
was simply enabled and simply passed on the first run.

So of this task's criteria:

- **"pin the record release" was already satisfied** at SPARQL-T-0030,
  by the owner's call — noted in SPARQL-T-0031's handoff.
- **"restore 512 of 512" is superseded**: the suite stands at **537 of
  537 across 38 directories**, because SPARQL-T-0033 also enabled
  `sparql10-expr-builtin`, which record's language-tag folding made
  green.
- **"read the parts directly" is done**: `Triple_Reader` is retired and
  `exec_triple_parts` calls `record.snapshot_triple_parts` — one read out
  of the encoding, no allocation, no decode, where odin-rdf-store needed
  a `lookup_term` plus three `find_term`s.

**What is genuinely left is the record of it**: `triple_adapter`'s
two-round-trip note was the store evidence `SPARQL-T-0019` recorded, and
the gap it described is closed. The replacement text is in
`sparql/exec.odin`'s `exec_triple_parts` and in `expr_eval.odin`'s
`SYNTHETIC_FIRST` (the consumer id range, the other half of that
evidence). Whether this task still needs to exist, or whether its
remaining content folds into SPARQL-T-0039's reconciliation, is the
owner's call.
