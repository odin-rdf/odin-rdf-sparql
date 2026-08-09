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

> **Amendment, 2026-08-08.** The paragraph above is the record of 2026-08-06 and is left standing; three things in it have since moved. **The corpus is no longer run against two backends** — odin-rdf-store retired its in-memory one (STORE-A-0006) and SPARQL-T-0023 removed this repository's memstore instantiation, so every entry now runs against kvstore alone, still at both `Term_ID` widths. **The evaluation position improved**: 483 entries pass across 35 suite directories, with the remaining gaps tracked as SPARQL-T-0020 (GRAPH scoping for OPTIONAL and MINUS) and SPARQL-T-0021 (term identity), the latter carrying a settled decision to do nothing about IRI normalization. **A query is now one snapshot** (SPARQL-T-0024): `query_init` takes a read transaction from odin-rdf-store v0.3.0 and `query_destroy` ends it, so evaluation answers about one dataset rather than about however many its independent reads landed on. The tag is still v0.1.0; nothing since has been released.

> **Amendment, 2026-08-08 — the store under this engine now has a time dimension, and it cost this repository nothing.** odin-rdf-store's `STORE-A-0008` takes the quad indexes to format 2: every index key carries the epoch of the version it records, negated so a quad's versions sort newest first; `remove` exists and is a tombstone append rather than an erasure; and **as-of lives on the transaction** — `txn_begin_as_of(s, horizon)` returns a read transaction through which every read is as-of. Because `query_init_txn` has taken a `^kvstore.Txn` since SPARQL-T-0024, **an as-of query is this engine's ordinary evaluation through a different transaction, and no line of non-test source here changed to allow it** (SPARQL-T-0025, verifying odin-rdf-store's `STORE-T-0052`). There is no temporal SPARQL syntax, no as-of constructor, and nothing an application must remember to filter on. It is the clearest instance yet of this vision's "consume the interface, don't bypass it": a capability arrived one layer down and reached the query language by being in the right place, not by being plumbed. Two things about it are worth carrying forward. **The store's dictionary is deliberately not temporal** — a term interned at a later epoch stays nameable in a read of an earlier one, so term binding resolves it and the horizon hides its quads instead, which is the correct division and is now pinned by a test. And **`count` is the one asymmetry**: O(1) at HEAD, a scan under a horizon (`STORE-A-0008` §7). It costs this engine nothing today because the evaluator never calls it — checked, not assumed — and that stays true only while planning remains naive; a future cardinality-driven planner would meet the scan, which is a thing to know before designing one rather than after. The tag is still v0.1.0.

> **Amendment, 2026-08-09 — the last engine-semantics gap in the 1.1 evaluation corpus is closed (SPARQL-T-0020).** The two failures the amendments above kept pointing at, `graph-optional` and `graph-minus`, were one bug and one sentence of §18.5: **the variable a `GRAPH` clause binds is not in scope inside the clause.** `Graph(?g, P)` evaluates P against one graph at a time, as a plain graph, and joins `Ω(?g→i)` on afterwards — so an occurrence of `?g` inside is an ordinary variable bound by a subject, predicate or object position, and an operator in there that sees more than one solution at a time must not have the graph in its domain. This engine had been pushing `?g` into every triple pattern's graph position, which is the same computation only while P is a pure pattern; under an OPTIONAL it made the optional demand that a triple's object equal its own graph, and under a MINUS it made two disjoint domains overlap so the MINUS removed what it should have left. The fix is a plan operator (`Plan_Graph_Bind`) that performs the join the specification puts after the clause, over a graph slot of the engine's own — plus the rule that MINUS's shared-variable test counts *query* variables only, which is what the engine's invented slots were never entitled to be. SPARQL-T-0013 had declined to fit the code to the DAWG's `graph-optional` answer without a reading it could defend; the reading turned out to be in this corpus all along, as `graph-variable-scope`'s comment. **512 entries now pass across 37 enabled directories**, and the paragraph below about five unenabled directories and 59 unasserted entries reads three and 32. Of the twelve entries still failing, none is an operator: two are term identity (SPARQL-T-0021) and ten are RDF/XML data. **Unreleased.** ~~Not releasable yet — `main` already carried SPARQL-T-0026, which consumes a store capability that has no tag.~~ **Corrected the same day: that was wrong.** SPARQL-T-0026's commit filed its backlog item and changed no source; `store.NAMED_GRAPHS` appears nowhere outside a comment, and all five of its acceptance criteria are open. This repository builds and passes against the pinned `v0.5.0` at both `Term_ID` widths — measured against a `v0.5.0` checkout, not inferred. Nothing here is blocked on a store release; what is true is narrower and belongs to SPARQL-T-0027, below: the *sibling checkout* on this machine is odin-rdf-store's `main`, and against that checkout the suite aborted until the sentinel base was fixed.
>
> One thing found on the way and fixed here rather than filed for later, because it made the whole evaluation suite abort: this engine names query-computed terms in the store's Sentinel space and had been starting at counter 3, read off "the three sentinels that exist". odin-rdf-store's `STORE-T-0017` then took counter 3 for `NAMED_GRAPHS`, so the first computed term of every query *became* the named-graph wildcard and kvstore asserted. The base is now `store.SENTINEL_CONSUMER_FIRST`, which the store reserved for exactly this in v0.5.0 (`STORE-T-0021`) and which this engine had simply never adopted. Nothing about it needed a new store release; it needed the constant to be named instead of guessed.

Result serialization landed 2026-08-06 (SPARQL-T-0022): `sparql/srj` and `sparql/srx` write the SPARQL Query Results JSON and XML formats for SELECT and ASK, allocation-free and streaming, in odin-rdf-parser's emitter shape. It was listed in Major Features here while SPARQL-I-0002 excluded it and the README claimed this vision put it out of scope; building it was the resolution, because CONSTRUCT and DESCRIBE already emit interchange output and an engine that exports graphs but not solutions follows from no principle stated here.

Met without qualification: evaluation reaches storage through odin-rdf-store's public match contract alone, with no private hooks into either backend; the interface capabilities discovered along the way were fed upstream as seven evidence-backed backlog items rather than worked around, with `find_term` (STORE-T-0014) landing in both backends before the engine needed it; and the public API carries contract-level documentation to the family's standard.

**Criterion 1 is partially met and is the open decision.** 483 entries are *asserted* across 35 enabled directories; five further directories are vendored but not enabled, because enablement is per-directory and a directory with one known failure goes dark in its entirety. Those five hold 59 additional passing entries that nothing asserts. Fourteen entries fail in total: two are this engine's own semantics (`graph-optional`, `graph-minus` — what a GRAPH clause does to an operator inside it that sees more than one solution at a time; SPARQL-T-0013 declined to fit the code to a DAWG answer it could not derive from §18, and that judgement stands), two are the family's **term-identity** question (language-tag case, IRI normalization — the answer must hold for the RDF parser, both store dictionaries, and the SPARQL parser at once), and ten are `sparql11-subquery` entries whose data documents are RDF/XML. RDF/XML is out of scope in odin-rdf-parser by decision, so those ten are a permanent ceiling rather than a pending task; all eleven RDF/XML references in the corpus sit in that one directory, so the cost is bounded there.

**Criterion 4 is partially met.** CONSTRUCT and DESCRIBE are implemented and their results are compared against expected graphs under blank-node isomorphism. But the criterion as written asks for results *emitted through odin-rdf-parser* and re-parsed, and no such emit-then-re-parse path is exercised — the parser's emitters are never run over query results.

`exit_criteria_met` stays false deliberately: it records that criteria 1 and 4 are open, not that the engine is unfinished.

The store facts this engine builds on: quads are `[4]Term_ID` with kind-tagged dense IDs (STORE-A-0001), so joins and dedup are integer comparisons and a term's kind (IRI/blank/literal/triple term) is readable from the ID without a dictionary lookup; `match` streams encoded quads with no ordering guarantee in v1, that revision explicitly deferred to this engine's evidence (both backends iterated in identical numeric-ID order, so ordered iteration is nearly free when asked for — and after STORE-A-0006 retired the in-memory backend, kvstore's order stands on its own, falling out of STORE-A-0001's big-endian key rule rather than out of agreement between two implementations, so this conclusion is unaffected); kvstore's read paths are transaction-parametric so the snapshot API arrives as an additive layer, not a refactor. All of these held in practice: joins compare integer IDs throughout, and the snapshot API arrived as an additive layer rather than a refactor the engine had to force — *(amended 2026-08-08, SPARQL-T-0024: it is no longer a proposal. odin-rdf-store shipped it as `STORE-A-0007` / v0.3.0, and this engine consumed it: `query_init` takes a read transaction and `query_destroy` ends it, which is the lifetime a `Query` already had. The prediction that it would be additive was correct — `query_init`'s signature did not change and no caller was touched.)*

## Future State

A complete, well-tested Odin library where:

- SPARQL 1.1 Query (with the RDF 1.2/SPARQL 1.2 additions as their specs stabilize) parses and evaluates correctly, measured against the W3C SPARQL test suites.
- Evaluation runs against any odin-rdf-store backend through the match interface alone. *(Amended 2026-08-07, SPARQL-T-0023: this criterion read "— in-memory and LMDB behave identically apart from performance", and it was met — the engine ran verbatim against both backends at both `Term_ID` widths, which is what proved it reached storage through the contract alone. odin-rdf-store has since retired its in-memory backend (STORE-A-0006), so the identical-behaviour half is no longer verifiable and is retracted rather than left standing. The criterion itself survives: the engine still names no backend, and `sparql/kvstore` is one instantiation of a split that a second backend would reuse.)*
- The store's planner-support surface (snapshot API, ordered iteration, cardinality estimates) has been shaped by this engine's demonstrated needs, not speculation. *(Met for the snapshot API, 2026-08-08: SPARQL-T-0019 sent the evidence, the store designed `STORE-A-0007` around it and shipped v0.3.0, and SPARQL-T-0024 consumed it. Ordered iteration and cardinality estimates remain unbuilt and unasked-for — the engine has not needed them, which is the criterion working rather than failing.)*
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