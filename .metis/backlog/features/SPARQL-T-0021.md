---
id: term-identity-language-tag-case
level: task
title: "Term identity: language-tag case and IRI normalization, a family question"
short_code: "SPARQL-T-0021"
created_at: 2026-08-05T22:48:10.277277+00:00
updated_at: 2026-08-05T22:48:10.277277+00:00
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

# Term identity: language-tag case and IRI normalization, a family question

## Objective **[REQUIRED]**

Two vendored W3C evaluation entries fail because a term the query writes
and a term the data holds are *the same term* by the specification and
two different dictionary keys in this family. Neither is an evaluation
bug: the engine compares Term_IDs, and by the time it sees them the
decision has already been made.

**`sparql10-expr-builtin/dawg-lang-3`** — "Graph matching with lang tag
being a different case". The query asks for `?x :p "string"@EN`; the data
holds `"string"@en`. BCP 47 language tags are case-insensitive, so those
are one literal. Neither the RDF parser nor the SPARQL parser folds the
case, so they intern as two.

**`sparql10-i18n/normalization-2`** — the query writes
`eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz` and the data writes the same IRI
after RFC 3987 syntax-based normalization (lowercase scheme, dot-segment
removal, percent-decoding of unreserved characters, uppercase
percent-encodings). Again one IRI by the specification, two keys here.

Both are **term-identity** questions, and they are the family's rather
than this engine's: whatever the answer is, it has to hold for the RDF
parser, the store's dictionary, and the SPARQL parser at once, or the
same document loaded twice would produce different terms.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Feature - New functionality or enhancement

### Priority
- [x] P3 - Low (when time permits)

Two entries in 488, and both are corner cases of *how a term is written*
rather than of what a query means. They keep two directories disabled —
`sparql10-expr-builtin` (24/25) and `sparql10-i18n` (4/5) — which is 29
entries of coverage, and that is the cost worth weighing.

### Business Justification **[CONDITIONAL: Feature]**
- **User Value**: `"x"@EN` and `"x"@en` are one literal, and two spellings of one IRI are one IRI — which is what every other RDF toolkit does and what a user comparing this engine's answers to Jena's will expect.
- **Business Value**: Enables two more suite directories, and settles a question all three family repos would otherwise answer separately (or, worse, differently).
- **Effort Estimate**: M, and it is a *design* decision before it is an implementation. Where does normalization happen — the parsers, the dictionary, or both? Doing it in the dictionary makes every consumer inherit it and makes `lookup_term` return something the document did not say; doing it in the parsers makes it a property of ingestion and leaves a hand-built term unnormalized.

## Acceptance Criteria **[REQUIRED]**

- [ ] The decision recorded as an ADR in the repo that owns it (odin-rdf-parser's data model, most likely): whether the family normalizes language-tag case and IRIs, where, and what `lookup_term` then promises to return.
- [ ] Language-tag case folding implemented wherever the ADR says, consistently across odin-rdf-parser's four format parsers, this engine's SPARQL parser, and both store dictionaries.
- [ ] RFC 3987 syntax-based normalization likewise. Note that odin-rdf-parser already has `remove_dot_segments` in its IRI resolution, so part of this exists and is applied only on the resolution path.
- [ ] `dawg-lang-3` and `normalization-2` pass; `sparql10-expr-builtin` (25) and `sparql10-i18n` (5) enabled with pinned counts; `tests/w3c/README.md`'s near-miss section updated.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The two halves are not equally settled. Language-tag folding is
unambiguous — BCP 47 says tags are case-insensitive, RDF 1.1 says a
language-tagged string's tag is compared case-insensitively, and this
engine *already* folds case in `value_equal` and `value_same_term`
(`sparql/value.odin`). It is only the *dictionary key* that does not,
which is why the FILTER-level tests pass and the graph-matching one does
not.

IRI normalization is the genuinely open one: RFC 3987 defines several
levels, RDF says IRIs are compared by simple string comparison after the
IRI is *established*, and how much normalization happens before that is
the family's call.

### Dependencies

Owned by odin-rdf-parser's data model; this repo is where the evidence
is (the two suite entries) and would consume the answer. Both store
dictionaries key on the strings the parsers hand them, so a change there
is a change everywhere.

### Risk Considerations

Normalizing in the dictionary means `lookup_term` can return a term that
is not byte-identical to what the document said, which would break the
round-trip property odin-rdf-store pins in its conformance suite. That
is the constraint the ADR has to work around, and the reason this is a
design task and not a patch.

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
