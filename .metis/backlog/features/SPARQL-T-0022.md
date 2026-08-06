---
id: sparql-result-serialization-the
level: task
title: "SPARQL result serialization: the JSON and XML result writers"
short_code: "SPARQL-T-0022"
created_at: 2026-08-06T12:52:00.185515+00:00
updated_at: 2026-08-06T12:52:00.185515+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"
  - "#feature"


exit_criteria_met: true
initiative_id: NULL
---

# SPARQL result serialization: the JSON and XML result writers

## Objective **[REQUIRED]**

Resolve a three-way contradiction, by building the missing thing rather than by shrinking the promise.

- **SPARQL-V-0001, Major Features** listed "Result forms: SELECT (**JSON/XML result serialization**), ASK, CONSTRUCT/DESCRIBE".
- **SPARQL-V-0001, Constraints** put the HTTP and Graph Store protocols, federation, and full-text search out of scope — and *not* result serialization.
- **README.md** said result serialization was out of scope "**per the project vision**", attributing to the vision the opposite of what it said.
- **SPARQL-I-0002** recorded its own scope as "excluding result serialization writers", so the initiative excluded it while the vision still promised it.

No writer existed. Three documents disagreed, and the one a contributor reads to learn what the project promises was the one being contradicted.

The decisive argument for building rather than dropping: **CONSTRUCT and DESCRIBE already produce interchange output** through odin-rdf-parser's emitters. A caller can be handed a Turtle graph but not a result set. "The query engine exports graphs but not solutions" follows from no principle in the vision, and the protocol analogy does not hold — a protocol is a server concern, a serializer is a library function.

## Acceptance Criteria **[REQUIRED]**

- [x] `sparql/srj` writes the SPARQL Query Results JSON Format; `sparql/srx` writes the XML Format.
- [x] Both cover SELECT (streaming) and ASK, every term kind including RDF-star triple terms, unbound cells, base direction, and the escaping each format requires.
- [x] Both are exercised at both `Term_ID` widths through `make test`, and vetted by `make check`.
- [x] The vision, the README, and the code agree.

## Implementation Notes **[CONDITIONAL: Technical Task]**

**Shape.** Follows odin-rdf-parser's emitters exactly — `emitter_init` / `emit` / `emitter_finish` for the streaming SELECT form, and a stateless `emit_boolean` for ASK, which is one document with nothing to stream. A caller writes solutions one at a time; nothing materializes the result set.

**Allocation: none.** Values go straight to an `io.Writer`, escaping as they go. There is no `emitter_destroy` because there is nothing to release.

**Boundary.** The writers take `[]rdf.Term` rows aligned to a borrowed `[]string` of variable names, with a nil cell meaning unbound. They therefore name no storage backend and stay out of the engine's generic instantiation: materializing `store.Term_ID`s into terms is the caller's step, which is where the dictionary lives.

**Term encoding** matches what this repo's readers accept, so the two halves are interoperable: `uri` / `bnode` / `literal` / `triple`, blank-node labels written *without* `_:` (syntax, not identity), `xml:lang` + `its:dir` in JSON and `xml:lang` + `dir` in XML for base direction, and no datatype written for a plain literal since `xsd:string` is the data model's invariant.

**Two escaping details worth keeping.** XML character content escapes carriage return as `&#xD;` — an XML processor normalizes a literal CR away, which would silently change a literal's value. Attribute values additionally escape the quote and the whitespace that attribute-value normalization would otherwise turn into spaces. JSON escapes only what RFC 8259 requires; all non-ASCII passes through as UTF-8.

## Status Updates **[REQUIRED]**

- **2026-08-06 — Completed.** `sparql/srj` and `sparql/srx` implemented, added to `PKGS`, and documented in the README with the misattribution removed. The vision needed no change to its Major Features: the feature it promised now exists.

  **Tested two ways, deliberately.** `tests/w3c/harness/writer_roundtrip_test.odin` writes a fixture with both writers, reads it back with this repo's `read_srj`/`read_srx` — readers written independently, against the vendored W3C documents — and compares with the same §12.2 multiset comparison the evaluation suites use. But a round-trip cannot catch a writer and a reader agreeing on the *same* mistake, so each package also carries exact-output tests pinning the actual bytes against the format specification.

  Full suite green: 16 package-runs (8 packages × 2 `Term_ID` widths), `make check` clean.

  Two Odin details cost a round trip each and are recorded so they are not rediscovered: `io.write_string` returns `(int, io.Error)`, so it cannot be tail-returned from a procedure returning only `io.Error`; and a slice literal is backed by the enclosing stack frame, so a test fixture returning `[]rdf.Term{...}` hands back a dangling slice and segfaults — rows must be `make()`d and variable lists given static storage.
