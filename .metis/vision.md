---
id: odin-rdf-sparql
level: vision
title: "odin-rdf-sparql"
short_code: "SPARQL-V-0001"
created_at: 2026-08-04T16:47:41.164958+00:00
updated_at: 2026-08-04T16:48:59.044903+00:00
archived: false

tags:
  - "#vision"
  - "#phase/published"


exit_criteria_met: false
initiative_id: NULL
---

# odin-rdf-sparql Vision

## Purpose

Provide the Odin RDF family with its query engine: a SPARQL implementation that parses queries into algebra and evaluates them against the match interface defined by odin-rdf-store. It is the third layer of the stack — odin-rdf-parser (parsing/serialization) → odin-rdf-store (storage, match interface) → this project — and the primary driver of evidence for how the store's interface must evolve (join-friendly iteration order, cardinality estimates for planning).

## Product/Solution Overview

odin-rdf-sparql is a library (not a server) targeting Odin developers who need to query RDF data. It offers:

- **A SPARQL query parser**: query text → abstract syntax → SPARQL algebra, with precise, position-carrying error reporting in the style established by odin-rdf-parser.
- **An evaluation engine**: executes the algebra against any implementation of odin-rdf-store's match interface — basic graph patterns as joins over `match()`, plus the algebra operators (OPTIONAL, UNION, FILTER, GROUP BY, ORDER BY, subqueries, property paths).
- **Solution and result handling**: solution sequences with proper RDF term semantics (including RDF-star), and result serialization in the standard formats (SPARQL JSON/XML results; CONSTRUCT/DESCRIBE output via odin-rdf-parser's emitters).
- **A planner seam**: query planning starts naive (fixed join order) with a designed-in place for cost-based ordering as the store grows cardinality estimates.

The library is deliberately engine-only: protocol/HTTP layers, federation (SERVICE), and full-text extensions are out of scope or later phases. SPARQL Update is a candidate later phase once the store exposes mutation beyond bulk load.

## Current State

The project is at its inception; no query code exists. Two foundations precede it: odin-rdf-parser is complete (100% W3C conformance across the four core formats, RDF 1.2/RDF-star included), and odin-rdf-store is newly started to define the match interface this engine will consume. Query parsing (grammar → algebra) has no store dependency and can begin immediately; evaluation work tracks the store's progress.

## Future State

A complete, well-tested Odin library where:

- SPARQL 1.1 Query (with the RDF 1.2/SPARQL 1.2 additions as their specs stabilize) parses and evaluates correctly, measured against the W3C SPARQL test suites.
- Evaluation runs against any odin-rdf-store backend through the match interface alone — in-memory and LMDB behave identically apart from performance.
- The store's planner-support surface (ordered iteration, cardinality estimates) has been shaped by this engine's demonstrated needs, not speculation.
- Downstream tooling (odin-rdf-shacl's SHACL-SPARQL phase, applications) can embed the engine as a library.

## Major Features

- **Query parser**: full SPARQL grammar to algebra, hand-written recursive descent in the family style; spec-referencing errors with line/column positions.
- **Algebra evaluation**: BGP matching as joins over the store's match interface; OPTIONAL/UNION/MINUS, FILTER with the SPARQL expression/function library, aggregation, solution modifiers, subqueries, property paths.
- **Expression engine**: SPARQL operators and built-in functions with correct type promotion, error-as-unbound semantics, and RDF-star term handling.
- **Result forms**: SELECT (JSON/XML result serialization), ASK, CONSTRUCT/DESCRIBE (emitting through odin-rdf-parser).
- **Naive-then-planned execution**: fixed join order first; a planner stage that consumes store cardinality estimates when they exist.
- **W3C test-suite harness**: vendored SPARQL suites executed the same hermetic way odin-rdf-parser runs its format suites.

## Success Criteria

- The engine passes the W3C SPARQL 1.1 Query evaluation and syntax test suites (vendored, offline-reproducible), with the 1.2 suites added as they are published.
- Basic graph pattern evaluation runs against odin-rdf-store through the public match interface only — no private hooks into a specific backend.
- Interface needs discovered during evaluation (ordering, cardinality) are fed back to odin-rdf-store as concrete, evidence-backed proposals rather than implemented as workarounds.
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
- Scope is SPARQL Query as a library. Out of scope: the SPARQL HTTP protocol and Graph Store protocol, federation (SERVICE), and full-text search. SPARQL Update is deferred until odin-rdf-store exposes mutation suited to it.
- Query planning sophistication is bounded by what the store's interface offers at any point — naive execution must always remain correct.