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

- **2026-08-05 — Created at SPARQL-I-0002's exit verification (SPARQL-T-0019)**, which characterized these two as term-identity rather than evaluation failures.
