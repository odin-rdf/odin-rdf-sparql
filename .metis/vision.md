---
id: odin-rdf-sparql
level: vision
title: "odin-rdf-sparql"
short_code: "SPARQL-V-0001"
created_at: 2026-08-04T16:47:41.164958+00:00
updated_at: 2026-08-06T12:00:00.000000+00:00
archived: false

tags:
  - "#vision"
  - "#phase/published"


exit_criteria_met: false
initiative_id: NULL
---

# odin-rdf-sparql Vision

## Purpose

Provide the Odin RDF family with its query engine: a SPARQL implementation that parses queries into algebra and evaluates them against the match interface defined by odin-rdf-store. It is the third layer of the stack — odin-rdf-parser (parsing/serialization) → odin-rdf-store (storage, match interface) → this project — and the primary driver of evidence for how the store's interface must evolve — the planner-support revision the store already anticipates: a per-query snapshot API, ordered iteration, and cardinality estimates (STORE-I-0002 design decision 3; STORE-A-0002 review triggers).

## Product/Solution Overview

odin-rdf-sparql is a library (not a server) targeting Odin developers who need to query RDF data. It offers:

- **A SPARQL query parser**: query text → abstract syntax → SPARQL algebra, with precise, position-carrying error reporting in the style established by odin-rdf-parser.
- **An evaluation engine**: executes the algebra against any implementation of odin-rdf-store's match interface — basic graph patterns as joins over `match()`, plus the algebra operators (OPTIONAL, UNION, FILTER, GROUP BY, ORDER BY, subqueries, property paths).
- **Solution and result handling**: solution sequences with proper RDF term semantics (including RDF-star), and result serialization in the standard formats (SPARQL JSON/XML results; CONSTRUCT/DESCRIBE output via odin-rdf-parser's emitters).
- **A planner seam**: query planning starts naive (fixed join order) with a designed-in place for cost-based ordering as the store grows planner support. The read model is one query = one store snapshot (on persistent backends, one read transaction): the store's read internals are already transaction-parametric in anticipation, and this engine's job is to cash that analysis in as the concrete snapshot API proposal. Until it lands, evaluation over per-operation reads must remain correct.

The library is deliberately engine-only: protocol/HTTP layers, federation (SERVICE), and full-text extensions are out of scope or later phases. SPARQL Update is a candidate later phase once the store exposes mutation beyond bulk load.

## Current State

**The engine is built; three of five success criteria are met outright, one partially, and one is an open decision (2026-08-06).** Both initiatives are complete: SPARQL-I-0001 delivered the parser and §18.2/§18.4 algebra translation, SPARQL-I-0002 the evaluation engine. 352 syntax tests pass (154 SPARQL 1.1, 198 SPARQL 1.2). Across the vendored evaluation corpus of 556 entries, **542 pass (97.5%)**, every one run against *both* storage backends at *both* `Term_ID` widths. CI runs on Linux, macOS, and Windows. Tagged **v0.1.0**.

Met without qualification: evaluation reaches storage through odin-rdf-store's public match contract alone, with no private hooks into either backend; the interface capabilities discovered along the way were fed upstream as seven evidence-backed backlog items rather than worked around, with `find_term` (STORE-T-0014) landing in both backends before the engine needed it; and the public API carries contract-level documentation to the family's standard.

**Criterion 1 is partially met and is the open decision.** 483 entries are *asserted* across 35 enabled directories; five further directories are vendored but not enabled, because enablement is per-directory and a directory with one known failure goes dark in its entirety. Those five hold 59 additional passing entries that nothing asserts. Fourteen entries fail in total: two are this engine's own semantics (`graph-optional`, `graph-minus` — what a GRAPH clause does to an operator inside it that sees more than one solution at a time; SPARQL-T-0013 declined to fit the code to a DAWG answer it could not derive from §18, and that judgement stands), two are the family's **term-identity** question (language-tag case, IRI normalization — the answer must hold for the RDF parser, both store dictionaries, and the SPARQL parser at once), and ten are `sparql11-subquery` entries whose data documents are RDF/XML. RDF/XML is out of scope in odin-rdf-parser by decision, so those ten are a permanent ceiling rather than a pending task; all eleven RDF/XML references in the corpus sit in that one directory, so the cost is bounded there.

**Criterion 4 is partially met.** CONSTRUCT and DESCRIBE are implemented and their results are compared against expected graphs under blank-node isomorphism. But the criterion as written asks for results *emitted through odin-rdf-parser* and re-parsed, and no such emit-then-re-parse path is exercised — the parser's emitters are never run over query results.

`exit_criteria_met` stays false deliberately: it records that criteria 1 and 4 are open, not that the engine is unfinished.

The store facts this engine builds on: quads are `[4]Term_ID` with kind-tagged dense IDs (STORE-A-0001), so joins and dedup are integer comparisons and a term's kind (IRI/blank/literal/triple term) is readable from the ID without a dictionary lookup; `match` streams encoded quads with no ordering guarantee in v1, that revision explicitly deferred to this engine's evidence (both backends already iterate in identical numeric-ID order, so ordered iteration is nearly free when asked for); kvstore's read paths are transaction-parametric so the snapshot API arrives as an additive layer, not a refactor. All of these held in practice: joins compare integer IDs throughout, and the snapshot API remains an additive proposal (STORE backlog) rather than a refactor the engine had to force.

## Future State

A complete, well-tested Odin library where:

- SPARQL 1.1 Query (with the RDF 1.2/SPARQL 1.2 additions as their specs stabilize) parses and evaluates correctly, measured against the W3C SPARQL test suites.
- Evaluation runs against any odin-rdf-store backend through the match interface alone — in-memory and LMDB behave identically apart from performance.
- The store's planner-support surface (snapshot API, ordered iteration, cardinality estimates) has been shaped by this engine's demonstrated needs, not speculation.
- Downstream tooling (odin-rdf-shacl's SHACL-SPARQL phase, applications) can embed the engine as a library.

## Major Features

- **Query parser**: full SPARQL grammar to algebra, hand-written recursive descent in the family style; spec-referencing errors with line/column positions.
- **Algebra evaluation**: BGP matching as joins over the store's match interface, comparing Term_IDs only — terms are materialized through the dictionary solely where semantics require them (expression evaluation, ORDER BY, final results); OPTIONAL/UNION/MINUS, FILTER with the SPARQL expression/function library, aggregation, solution modifiers, subqueries, property paths.
- **Expression engine**: SPARQL operators and built-in functions with correct type promotion, error-as-unbound semantics, and RDF-star term handling.
- **Result forms**: SELECT (JSON/XML result serialization), ASK, CONSTRUCT/DESCRIBE (emitting through odin-rdf-parser).
- **Naive-then-planned execution**: fixed join order first; a planner stage that consumes store cardinality estimates when they exist.
- **W3C test-suite harness**: vendored SPARQL suites executed the same hermetic way odin-rdf-parser runs its format suites.

## Success Criteria

- The engine passes the W3C SPARQL 1.1 Query evaluation and syntax test suites (vendored, offline-reproducible), with the 1.2 suites added as they are published.
- Basic graph pattern evaluation runs against odin-rdf-store through the public match interface only — no private hooks into a specific backend.
- Interface needs discovered during evaluation (snapshots, ordering, cardinality) are fed back to odin-rdf-store as concrete, evidence-backed proposals rather than implemented as workarounds.
- CONSTRUCT round-trips: query results emitted via odin-rdf-parser re-parse to isomorphic graphs.
- The public API is documented and idiomatic Odin, to the contract-documentation standard of the sibling projects.

## Principles

- **Suite-driven correctness**: the W3C SPARQL test suites define "done", exactly as the format suites did for odin-rdf-parser.
- **Consume the interface, don't bypass it**: evaluation touches storage only through odin-rdf-store's public match contract; needed capabilities are proposed upstream, never special-cased.
- **Parser first, evaluation incrementally**: grammar → algebra is standalone and starts immediately; evaluation lands operator by operator against the growing store.
- **Idiomatic Odin**: explicit memory management, allocator awareness, streaming solution sequences — the family's established conventions.
- **Primitives over frameworks**: a query engine as a library; servers, caches, and federation belong to downstream projects or later phases.

## Constraints

- Written in Odin with no external dependencies.
- Depends on odin-rdf-parser (data model, term types, emitters) and odin-rdf-store (match interface); the store's types and contracts are consumed as published, and both sibling projects remain independently usable.
- The deployment shape is ~200 processes per physical machine, each embedding a store — CPU frugality is a first-order requirement. Concretely: backend binding is compile-time (the store's procedure-set convention; no dynamic dispatch on the match/join hot path), each query reads from one snapshot, joins compare integer Term_IDs, and terms are materialized only where semantics demand.
- Term_ID width is a build-time choice inherited from the store (64-bit default, 32-bit opt-in; STORE-A-0001). The engine follows the family's dual-width test discipline wherever its code is width-sensitive.
- Scope is SPARQL Query as a library. Out of scope: the SPARQL HTTP protocol and Graph Store protocol, federation (SERVICE), and full-text search. SPARQL Update is deferred until odin-rdf-store exposes mutation suited to it.
- Query planning sophistication is bounded by what the store's interface offers at any point — naive execution must always remain correct.