---
id: term-identity-language-tag-case
level: task
title: "Term identity: language-tag case, and whether rdf.equal agrees with the store"
short_code: "SPARQL-T-0021"
created_at: 2026-08-05T22:48:10.277277+00:00
updated_at: 2026-08-25T16:45:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#feature"


exit_criteria_met: false
initiative_id: NULL
---

# Term identity: language-tag case, and whether rdf.equal agrees with the store

## Objective **[REQUIRED]**

**Rescoped 2026-08-25.** This item was filed with two halves and they have
gone in opposite directions. The IRI half has left — it turned out not to
be a term-identity question at all — and what remains is one question that
is now sharper than when it was written.

**The question: `"x"@EN` and `"x"@en` are one literal, and this family
gives two answers depending on who is asked.**

- **odin-rdf-record folds** a language tag to lowercase on intern, so the
  two are **one term** and one id. That is RDF 1.1 Concepts §3.3's own rule
  — "the value space of language tags is always in lower case" — and it is
  correct.
- **odin-rdf-parser does not.** `rdf.equal` on two `rdf.Term`s differing
  only in tag case reports **not equal**.

So a consumer comparing ids gets one answer and a consumer comparing
`rdf.Term`s gets another, **inside one family, today**. When this item was
written the family was consistently wrong, which is a smaller problem than
being inconsistent.

## What has already been settled, and by whom

**The symptom that filed this item is gone.** `sparql10-expr-builtin/
dawg-lang-3` — `?x :p "string"@EN` against `"string"@en` — **passes**, and
the directory is enabled at 25/25 (`SPARQL-T-0033`, the port to
odin-rdf-record). It passes for the right reason rather than by luck: the
DAWG entry expects exactly the match §3.3 mandates.

But it was decided **by odin-rdf-record, for odin-rdf-record's reasons**,
not by the ADR this item asks for. The analysis below was right about
*what* should happen and wrong about *where* — it traced the fix to
`literal_lang`/`literal_dir_lang` in odin-rdf-parser on the grounds that
folding anywhere else leaves two notions of identity in one family, and
that is precisely the state the family is now in. **The analysis has been
vindicated by being ignored.**

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P3 - Low (when time permits)

**Held at P3, deliberately, and the reason has changed.** It was P3 because
two suite entries were at stake. Those are resolved. It stays P3 because
**nothing is known to be broken by the split** — every consumer that
matters compares through a store today: this engine evaluates over
`record.Term_ID`s, and odin-rdf-shacl reads through session verbs. The
exposure is a consumer comparing `rdf.Term`s outside a store, and none is
known.

It is a **latent inconsistency**, not a defect with a reproduction. That is
worth being honest about rather than inflating: the argument for doing it
is that a family should not hold two definitions of term equality, not that
anything is failing.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: One definition of when two literals are the same literal, whichever layer you ask.
- **Business Value**: Settles a question three repos would otherwise answer separately — and two of them already have, differently.
- **Effort Estimate**: S–M, and smaller than the original's M, because the hard part is done. record has demonstrated the fold is correct and costs nothing; what remains is odin-rdf-parser adopting it, which is a tagged library's behaviour change (`@EN` in, `en` out) and so a minor version rather than a patch.

## Acceptance Criteria **[REQUIRED]**

- [ ] **The decision recorded as an ADR in odin-rdf-parser**, which owns
      the data model: does `rdf.equal`/`rdf.hash` fold language-tag case,
      and if so does folding happen at literal construction (so the term
      itself is folded) or only in comparison (so two spellings compare
      equal but round-trip as written)? **record has already answered the
      same question for itself by folding the term**, and an ADR that
      disagrees with a shipped sibling should say why.
- [ ] **Whatever is decided, `rdf.equal` and record's term identity agree**
      — or the divergence is documented as deliberate, in both repos, with
      the reason. Silent disagreement is the one outcome to rule out.
- [ ] Implemented across odin-rdf-parser's four format parsers and this
      engine's SPARQL parser if the ADR says construction-time.
- [ ] **The vendored suites re-run in every repo**: odin-rdf-parser's
      1045, this engine's 537, odin-rdf-shacl's 98. `SPARQL-T-0033`
      measured the fold's blast radius here already and found none — no
      enabled entry regressed and no expected result in the corpus carries
      an uppercase tag that survives to a comparison — so the risk is
      known to be low on this side and unmeasured on the parser's.
- [ ] **`results.odin`'s `literals_equivalent` workaround removed.** It
      compares language tags with `strings.equal_fold` at comparison time,
      which is this repository's local patch for the family's split. The
      original item predicted the fix would make it unnecessary; it is the
      one concrete piece of debt the split is costing, and it is the honest
      measure of whether the ADR landed.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### What left this item, and where it went

**The IRI half is now `RDF-T-0026` in odin-rdf-parser**, filed 2026-08-25,
and it is a **bug rather than a policy question**.

The decision recorded below on 2026-08-06 — "IRIs: do nothing,
permanently", on RFC 3987 Simple String Comparison and RDF 1.1 Concepts
§3.2's "further normalization MUST NOT be performed" — **stands, and is
vindicated by the very entry that was cited against it**. Reading
`sparql10-i18n/normalization-02` settles it:

```
data:      :s1 :p <example://a/b/c/%7Bfoo%7D#xyz> .          # normalized
           :s2 :p <eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz> . # as written
query:     PREFIX p1: <eXAMPLE://a/./b/../b/%63/%7bfoo%7d#>
           SELECT ?S WHERE { ?S :p p1:xyz }
expected:  :s2 -- and explicitly NOT :s1
```

**The entry asserts that no normalization happens.** Under the do-nothing
policy it passes trivially — the query's IRI and `:s2`'s object are the
same bytes. It fails because **odin-rdf-parser's Turtle parser runs
absolute IRIs through RFC 3986 §5.2 reference resolution and removes their
dot segments**, with or without a base, so `:s2`'s object is stored as
`eXAMPLE://a/b/%63/%7bfoo%7d#xyz` while this engine's query parser —
correctly — leaves the query's IRI as written. Verified directly against
`rdf/turtle`, not inferred.

So the failure was never about whether this family normalizes IRIs. It was
one parser normalizing when it must not, which is nobody's policy and
everybody's bug. It was mis-filed here for twenty days because the DAWG
entry is called `normalization-02` and a missing normalization is the
obvious reading of a normalization test that fails.

`sparql10-i18n` stays disabled at 4/5 until `RDF-T-0026` lands. **Nothing
on this side needs to change** — the near-miss note in
`tests/w3c/README.md` and `eval_test.odin`'s header both describe it, and
the only edit due here afterwards is enabling the directory.

### Where the language-tag fold would land in odin-rdf-parser

The original tracing still holds and is worth keeping, because it was
tested rather than assumed — see the 2026-08-06 Status entry. Its
conclusion: fold in `literal_lang`/`literal_dir_lang`, because the store
dictionary's canonical bytes and direct `rdf.Term` comparison both inherit
it there. One clause it contains is now out of date — "kvstore's
`literal_canonical` … a STORE-A-0003 format-version bump" — since
odin-rdf-store is retired and has no consumers. **That removes the largest
cost the original analysis identified**: there is no persistent database
whose existing keys would stop matching. record folds already, so its
format is not at stake either.

The remaining cost is what it always was: the language slice is borrowed
from the source buffer, so a non-lowercase tag needs an allocation — the
copy-on-write shape the parser already uses for escape unescaping, and one
more clause on its documented allocation contract.

### Dependencies

None. It is a family decision that this repository does not own and is not
blocked on for anything — the entries that motivated it are green.

### Risk Considerations

**The risk of doing it** is a tagged library changing observable behaviour
(`@EN` in, `en` out, emitters round-tripping `@en`), which is a minor
version and a re-run of 1045 tests, checked for any vendored expectation
that preserves an uppercase tag.

**The risk of not doing it** is the one this item now exists to name: two
definitions of term equality in one family, with nothing to make them
disagree loudly. It will surface as a consumer comparing `rdf.Term`s and
getting an answer the store would not have given, in a context where
nobody is looking for it.

## Status Updates **[REQUIRED]**

- **2026-08-06 — Deferred until odin-rdf-shacl forces it, and the two halves separated.** Read against RDF 1.1 Concepts, these are not one question:

  **IRIs (`normalization-2`) is settled: do nothing, permanently.** §3.2 says "Two IRIs are equal if and only if they are equivalent under Simple String Comparison according to section 5.1 of [RFC3987]. **Further normalization MUST NOT be performed** when comparing IRIs for equality." Normalizing to make this entry pass would take the family *out* of RDF 1.1 conformance to satisfy a SPARQL test. `sparql10-i18n` stays 4/5 by decision, like the RDF/XML ceiling in `sparql11-subquery`. The parser's documented "IRIs stored as given, no normalization" contract is now positively required rather than merely convenient.

  **Language tags (`dawg-lang-3`) is permitted, not required — and is deferred.** §3.3 compares language tags "character by character", so folding is not mandated by a MUST; but it also says "Lexical representations of language tags MAY be converted to lower case. **The value space of language tags is always in lower case.**" An implementation that keeps `EN` distinct from `en` therefore holds a value outside the stated value space. Fixing it is sanctioned and correct; it is not forced.

  **Where it must land, when it lands: odin-rdf-parser, at literal construction.** This was traced rather than assumed:

  - Changing `rdf.equal`/`rdf.hash` alone was **ineffective** while memstore existed: it interned with `map[rdf.Literal]store.Term_ID` — Odin's built-in struct hashing — and never called them. *(Amended 2026-08-08: memstore is gone, STORE-A-0006. The point survives in weaker form — the store's dictionary is what assigns IDs, and kvstore keys on `literal_canonical` bytes rather than on `rdf.equal`, so changing the comparison functions alone still does not change what gets interned.)*
  - Folding in the store dictionaries alone leaves `rdf.equal` reporting `@EN` != `@en`, so every consumer comparing `rdf.Term`s outside the store (this engine's expression evaluation; SHACL's `sh:hasValue`/`sh:in`/`sh:languageIn`) disagrees with storage — two notions of identity in one family. It also rewrites kvstore's `literal_canonical`, which appends `v.language` verbatim into the persistent `term2id` key, so existing databases holding `EN` would stop matching: a STORE-A-0003 format-version bump.
  - Folding in `literal_lang`/`literal_dir_lang` fixes all of it at once, because memstore's struct key, kvstore's canonical bytes, and direct `rdf.Term` comparison all inherit it.

  Cost of doing it there: the language slice is borrowed from the source buffer, so a non-lowercase tag needs an allocation — the same copy-on-write shape the parser already uses for escape unescaping, and one more clause on its documented allocation contract. It is a behaviour change to a tagged library (`@EN` in, `en` out, emitters round-tripping `@en`), so v0.2.0 rather than v0.1.1, verified by re-running the 1045 W3C tests to see whether any vendored expectation preserves an uppercase tag.

  **Deferred because** the parser meets every success criterion and is tagged, the spec says MAY rather than MUST, and the only current forcing case is one W3C entry. odin-rdf-shacl is where the need becomes concrete rather than theoretical — SHACL Core is term comparison end to end — so the decision is better made with that evidence than without it. Recorded in SHACL-V-0001's current state.

  Note that `results.odin`'s `literals_equivalent` already compares language tags with `strings.equal_fold`, so the harness works around this at comparison time; that workaround is what the fix would make unnecessary.

- **2026-08-05 — Created at SPARQL-I-0002's exit verification (SPARQL-T-0019)**, which characterized these two as term-identity rather than evaluation failures.

- **2026-08-25 — Re-read after the port to odin-rdf-record (SPARQL-I-0003,
  SPARQL-T-0039). The two halves have moved in opposite directions, and
  neither moved the way this item predicted.**

  **The language-tag half is closed for this repository, and not by the
  parser.** This item traced the fix carefully to `literal_lang` /
  `literal_dir_lang` in odin-rdf-parser, on the grounds that folding anywhere
  else leaves two notions of identity in one family. **odin-rdf-record folded
  it instead**, for its own reasons: its canonical term encoding lowercases a
  language tag on intern, so `"x"@EN` and `"x"@en` are one term. The forcing
  case named above — the single `dawg-lang-3` entry — **now passes, and for
  the right reason**: RDF 1.1 Concepts §3.3 says the value space of language
  tags is lower case, and the DAWG entry expects exactly this match.
  `sparql10-expr-builtin` was enabled as a consequence (+25 entries, +1
  directory, `SPARQL-T-0033`).

  The analysis was right about *what* needed to happen and wrong about *where*
  it would happen, and the difference still matters family-wide: `rdf.equal`
  in odin-rdf-parser continues to report `@EN` != `@en`, so the two-notions-
  of-identity concern this item raised is **narrowed rather than resolved** —
  it no longer bites this engine, because everything here compares through
  record's ids, and it would still bite a consumer comparing `rdf.Term`s
  outside a store. odin-rdf-shacl reached the same position on 2026-08-20.
  **The parser-side decision is left open on purpose and is the family's, not
  this repository's.** The concrete cost of leaving it open is now one
  workaround: `results.odin`'s `literals_equivalent` still compares with
  `strings.equal_fold`, which this item predicted the fix would make
  unnecessary, and which is still there.

  **The IRI half is unchanged in its decision and wrong in its diagnosis.**
  "Do nothing, permanently" stands — RFC 3987 Simple String Comparison, and
  normalizing to pass a test would take the family out of RDF 1.1 conformance.
  But `sparql10-i18n/normalization-02`, the entry cited for it, **is not
  failing for that reason.** Measured directly at `SPARQL-T-0033`: the SPARQL
  parser leaves `eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz` as written while
  odin-rdf-parser's Turtle parser resolves it to
  `eXAMPLE://a/b/%63/%7bfoo%7d#xyz`. **Two parsers in one family, two answers,
  no store involved** — a dot-segment resolution disagreement, which is a
  question about RFC 3986 reference resolution rather than about IRI
  equivalence. That is a genuine internal inconsistency and it is not what
  this item is about. It is recorded in `tests/w3c/README.md` and
  `eval_test.odin`'s header; whether it becomes its own item is the family's
  call.

  **Two term-identity properties record introduced were checked and cost
  nothing**, which is worth recording because they were the port's live risks:
  a non-canonical numeric lexical form is a distinct term from the inlined
  canonical one (no mismatch anywhere traces to it), and an inlineable literal
  is always resolvable even when absent from the data (invisible in the
  corpus; visible in `bench/` as two `GROUP BY` read-count pins, and there it
  is an improvement).

  Left open, with its scope reduced to the family-wide `rdf.equal` question
  and its SPARQL-side forcing cases gone.

- **2026-08-25 (later the same day) — split, and the IRI half was misfiled
  from the beginning.**

  The morning's reconciliation entry above got the language-tag half right
  and under-called the IRI half. It described `normalization-02` as "two
  parsers, two answers … a genuine internal inconsistency", framed as
  symmetric and left as "whether it becomes its own item is the family's
  call". Reading the fixture and reproducing against `rdf/turtle` shows it
  is not symmetric: **the Turtle parser mangles an absolute IRI, with no
  base, which no reading of Turtle §6.3 or RFC 3986 §5.2 permits**, and the
  SPARQL parser is right. It is a bug in odin-rdf-parser, now
  **`RDF-T-0026`**, filed with odin-rdf-record named as the consumer that
  should care most — `record/ingest` loads through this parser, so a system
  of record can presently log an IRI its source document did not contain.

  This item keeps the language-tag half only, and its priority and framing
  are rewritten: the *symptom* is resolved, the *family split* is not, and
  a split is worse than the shared gap this item was filed against. The
  original two-halves text is replaced rather than annotated, because both
  halves' framing was wrong; the 2026-08-06 analysis it rested on is kept
  in full below, since it is still the best account of where a fold belongs
  and one of its costs has since disappeared with odin-rdf-store.
