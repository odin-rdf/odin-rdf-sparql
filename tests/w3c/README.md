# Vendored W3C SPARQL test suites

Official conformance test suites for SPARQL 1.1 and 1.2 Query, vendored
so the harness runs hermetically with no network access.

- **Source**: https://github.com/w3c/rdf-tests
- **Upstream commit**: `767554e135eb6665949d870e6fa7bbc813837293` (main) —
  the same commit odin-rdf-parser pins for its format suites
- **Retrieved**: 2026-08-05 (syntax suites), 2026-08-05 (evaluation
  suites, SPARQL-T-0010), 2026-08-05 (SPARQL 1.2 evaluation suites,
  SPARQL-T-0018)
- **License**: W3C Test Suite License / W3C 3-clause BSD License (see the
  header of each `manifest.ttl`)

Directories are copied verbatim from upstream, so a directory's data
files, expected results, and any entries outside this engine's scope
ride along with it.

## Syntax suites

Vendored by the parser initiative (SPARQL-I-0001); the sparql11 and
sparql12 directories whose manifests contain query syntax tests.

| Directory | Upstream path | Contents |
|---|---|---|
| `sparql11-syntax-query/` | `sparql/sparql11/syntax-query/` | SPARQL 1.1 query syntax tests (positive + negative) |
| `sparql12-syntax/` | `sparql/sparql12/syntax/` | SPARQL 1.2 general syntax tests (GROUP BY scope, nested aggregates) |
| `sparql12-syntax-triple-terms-positive/` | `sparql/sparql12/syntax-triple-terms-positive/` | Triple terms, reified triples, reifiers, annotations (positive) |
| `sparql12-syntax-triple-terms-negative/` | `sparql/sparql12/syntax-triple-terms-negative/` | The same surface, negative |
| `sparql12-codepoint-escapes/` | `sparql/sparql12/codepoint-escapes/` | 1.2 codepoint-escape restriction (strings/IRIs only) |
| `sparql12-lang-basedir/` | `sparql/sparql12/lang-basedir/` | Directional language tags |
| `sparql12-version/` | `sparql/sparql12/version/` | VERSION declaration |

## Evaluation suites

Vendored by the evaluation initiative (SPARQL-I-0002, SPARQL-T-0010).
The engine is measured against the SPARQL 1.1 Query test suite, which is
the sparql11 evaluation directories *plus* the DAWG `data-r2` corpus the
1.1 suite carries forward — the core of the algebra (BGP matching,
OPTIONAL, GRAPH, FILTER, sorting, DISTINCT) has its tests there, not
under `sparql11/`.

| Directory | Upstream path | Covers |
|---|---|---|
| `sparql10-algebra/` | `sparql/sparql10/algebra/` | Algebra rewriting: nested optionals, filter placement |
| `sparql10-ask/` | `sparql/sparql10/ask/` | ASK |
| `sparql10-basic/` | `sparql/sparql10/basic/` | Basic graph patterns, prefixes, lists, quoting |
| `sparql10-bnode-coreference/` | `sparql/sparql10/bnode-coreference/` | Blank-node identity across a result |
| `sparql10-boolean-effective-value/` | `sparql/sparql10/boolean-effective-value/` | EBV in FILTER |
| `sparql10-bound/` | `sparql/sparql10/bound/` | BOUND |
| `sparql10-cast/` | `sparql/sparql10/cast/` | XPath casts |
| `sparql10-construct/` | `sparql/sparql10/construct/` | CONSTRUCT template instantiation |
| `sparql10-dataset/` | `sparql/sparql10/dataset/` | FROM / FROM NAMED dataset construction |
| `sparql10-distinct/` | `sparql/sparql10/distinct/` | DISTINCT over every term kind |
| `sparql10-expr-builtin/` | `sparql/sparql10/expr-builtin/` | STR, LANG, DATATYPE, isIRI, sameTerm, … |
| `sparql10-expr-equals/` | `sparql/sparql10/expr-equals/` | Value equality vs. term equality |
| `sparql10-expr-ops/` | `sparql/sparql10/expr-ops/` | Arithmetic and relational operators |
| `sparql10-graph/` | `sparql/sparql10/graph/` | GRAPH over named graphs |
| `sparql10-i18n/` | `sparql/sparql10/i18n/` | Non-ASCII IRIs and literals |
| `sparql10-open-world/` | `sparql/sparql10/open-world/` | Unknown datatypes, ill-typed literals, type errors |
| `sparql10-optional/` | `sparql/sparql10/optional/` | OPTIONAL |
| `sparql10-optional-filter/` | `sparql/sparql10/optional-filter/` | Filters inside OPTIONAL (the LeftJoin conditions) |
| `sparql10-reduced/` | `sparql/sparql10/reduced/` | REDUCED (`mf:LaxCardinality`) |
| `sparql10-regex/` | `sparql/sparql10/regex/` | REGEX |
| `sparql10-solution-seq/` | `sparql/sparql10/solution-seq/` | LIMIT / OFFSET |
| `sparql10-sort/` | `sparql/sparql10/sort/` | ORDER BY (the only directory with RDF/XML expectations) |
| `sparql10-triple-match/` | `sparql/sparql10/triple-match/` | Single triple patterns |
| `sparql10-type-promotion/` | `sparql/sparql10/type-promotion/` | Numeric type promotion |
| `sparql11-aggregates/` | `sparql/sparql11/aggregates/` | COUNT/SUM/MIN/MAX/AVG/SAMPLE/GROUP_CONCAT (5 negative syntax; rest evaluation) |
| `sparql11-bind/` | `sparql/sparql11/bind/` | BIND |
| `sparql11-bindings/` | `sparql/sparql11/bindings/` | VALUES |
| `sparql11-cast/` | `sparql/sparql11/cast/` | 1.1 casts |
| `sparql11-construct/` | `sparql/sparql11/construct/` | CONSTRUCT WHERE (2 positive syntax; rest evaluation) |
| `sparql11-exists/` | `sparql/sparql11/exists/` | EXISTS / NOT EXISTS |
| `sparql11-functions/` | `sparql/sparql11/functions/` | The §17 built-in function library |
| `sparql11-grouping/` | `sparql/sparql11/grouping/` | GROUP BY (2 negative syntax; rest evaluation) |
| `sparql11-negation/` | `sparql/sparql11/negation/` | MINUS and negation idioms |
| `sparql11-project-expression/` | `sparql/sparql11/project-expression/` | `(expr AS ?v)` in SELECT |
| `sparql11-property-path/` | `sparql/sparql11/property-path/` | §18.4 property paths |
| `sparql11-subquery/` | `sparql/sparql11/subquery/` | Subqueries |

The SPARQL 1.2 evaluation directories were vendored by SPARQL-T-0018,
from the same pinned commit: the top-level `sparql/sparql12/manifest.ttl`
includes all four there, so no second pin and no documented gap was
needed. `rdf11/` is one the SPARQL-T-0010 note did not name; it is an
evaluation directory of the 1.2 suite like the others, so it rides along.

| Directory | Upstream path | Covers |
|---|---|---|
| `sparql12-eval-triple-terms/` | `sparql/sparql12/eval-triple-terms/` | Triple terms and reified triples in patterns, expressions, CONSTRUCT, GRAPH, ORDER BY (3 Update entries; rest evaluation) |
| `sparql12-expression/` | `sparql/sparql12/expression/` | TRIPLE() over every argument shape, and `!!` |
| `sparql12-grouping/` | `sparql/sparql12/grouping/` | 1.2's grouping clarifications |
| `sparql12-rdf11/` | `sparql/sparql12/rdf11/` | RDF 1.1 literal handling (rdf:langString, xsd:string) |

Not vendored, per the vision's scope: the SPARQL Update directories
(`add/`, `basic-update/`, `clear/`, `copy/`, `delete*/`, `drop/`,
`move/`, `update-silent/`, `syntax-update-1/`, `syntax-update-2/`),
federation (`service/`, `service-description/`, `syntax-fed/`), the
protocol directories (`protocol/`, `graph-store-protocol/`,
`http-rdf-update/`), entailment regimes (`entailment/`), the SPARQL 1.0
syntax directories (`syntax-sparql1/` … `syntax-sparql5/`, superseded by
the 1.1 syntax suite), and the result-serialization suites
(`csv-tsv-res/`, `json-res/`) — writing result formats is a later
initiative, and this one needs expected-result *readers* only.

## The harness

The harness lives in `harness/` and runs under `odin test`. Manifests
are parsed with the family's own Turtle parser through the `rdf:`
collection. Each suite test asserts a pinned entry count — the guard
against a manifest-reader regression silently dropping tests; the
evaluation suites' counts are in `harness/suites.odin`, the syntax
suites' in `harness/harness_test.odin`.

Expected results are read by `harness/`'s own readers, which handle the
four formats the suites use: `.srx` (SPARQL Results XML), `.srj` (SPARQL
Results JSON), `.ttl` (the DAWG result-set vocabulary, or a plain graph
for CONSTRUCT/DESCRIBE), and `.rdf` (the result-set vocabulary in
RDF/XML, used only by `sparql10-sort/`). Both the XML and the JSON reader
handle SPARQL 1.2's additions: a `triple` binding whose value is a
subject/predicate/object object, and a literal's base direction beside
its language tag. The XML and RDF/XML readers work
over deliberately narrow subsets — see the notes at the top of
`harness/xml.odin` and `harness/rsvocab.odin` — and `readers_test.odin`
holds those assumptions to the whole vendored corpus by reading every
expectation the manifests name.

Suite directories are enabled individually; once a directory is enabled,
it must be fully green — no skip lists, no expected-failure files.
Positive syntax tests and the query side of evaluation tests must parse;
negative syntax tests must be rejected. SPARQL Update entries mixed into
a vendored directory are counted and acknowledged as out of engine
scope, never silently skipped — the three in
`sparql12-eval-triple-terms/` are pinned as `UPDATE_ENTRIES` in
`harness/readers_test.odin`. Each test's base IRI is the upstream suite
location plus the file name.

Data documents load through the store's own bulk loaders, in the four
formats the suites name them in: `.ttl`, `.nt`, `.trig`, and `.nq`. A
quad-bearing document names its own graphs, so one loads as it stands
rather than into a graph the manifest chose.

Evaluation *enablement* — running a directory's queries and comparing
their answers — arrives per task through the evaluation initiative. The
floor for every vendored evaluation directory, enabled or not, is that
its manifest reads, its expectations parse (556 across four formats), its
data loads, and its queries parse and translate.

Enabled for evaluation so far, each fully green against odin-rdf-record.
(This line read "both backends, memstore and kvstore" until
odin-rdf-store retired the in-memory one — STORE-A-0006 — then "against
kvstore at both Term_ID widths" until SPARQL-T-0033 ported the engine
onto odin-rdf-record, whose widths are fixed by design. One
configuration, one run.)

| Directory | Enabled by | Tests |
|---|---|---|
| `sparql10-triple-match/` | SPARQL-T-0011 | 4 |
| `sparql10-basic/` | SPARQL-T-0011 | 27 |
| `sparql10-ask/` | SPARQL-T-0012 | 4 |
| `sparql10-bnode-coreference/` | SPARQL-T-0012 | 1 |
| `sparql10-expr-equals/` | SPARQL-T-0012 | 15 |
| `sparql10-type-promotion/` | SPARQL-T-0012 | 30 |
| `sparql10-boolean-effective-value/` | SPARQL-T-0013 | 7 |
| `sparql10-bound/` | SPARQL-T-0013 | 1 |
| `sparql10-distinct/` | SPARQL-T-0013 | 11 |
| `sparql10-open-world/` | SPARQL-T-0013 | 18 |
| `sparql10-optional/` | SPARQL-T-0013 | 7 |
| `sparql10-reduced/` | SPARQL-T-0013 | 2 |
| `sparql10-algebra/` | SPARQL-T-0013 | 14 |
| `sparql10-expr-ops/` | SPARQL-T-0013 | 18 |
| `sparql10-optional-filter/` | SPARQL-T-0013 | 5 |
| `sparql11-bind/` | SPARQL-T-0013 | 10 |
| `sparql10-dataset/` | SPARQL-T-0013 | 12 |
| `sparql11-exists/` | SPARQL-T-0013 | 6 |
| `sparql11-bindings/` | SPARQL-T-0013 | 11 |
| `sparql11-functions/` | SPARQL-T-0014 | 75 |
| `sparql10-regex/` | SPARQL-T-0014 | 21 |
| `sparql10-cast/` | SPARQL-T-0014 | 7 |
| `sparql11-cast/` | SPARQL-T-0014 | 6 |
| `sparql11-aggregates/` | SPARQL-T-0015 | 42 |
| `sparql11-grouping/` | SPARQL-T-0015 | 4 |
| `sparql10-sort/` | SPARQL-T-0015 | 14 |
| `sparql10-solution-seq/` | SPARQL-T-0015 | 13 |
| `sparql11-project-expression/` | SPARQL-T-0015 | 7 |
| `sparql11-property-path/` | SPARQL-T-0016 | 33 |
| `sparql10-construct/` | SPARQL-T-0017 | 5 |
| `sparql11-construct/` | SPARQL-T-0017 | 5 |
| `sparql12-eval-triple-terms/` | SPARQL-T-0018 | 38 |
| `sparql12-expression/` | SPARQL-T-0018 | 5 |
| `sparql12-grouping/` | SPARQL-T-0018 | 2 |
| `sparql12-rdf11/` | SPARQL-T-0018 | 3 |
| `sparql10-graph/` | SPARQL-T-0020 | 17 |
| `sparql11-negation/` | SPARQL-T-0020 | 12 |
| `sparql10-expr-builtin/` | SPARQL-T-0033 | 25 |

That is **537 evaluation tests across thirty-eight directories**, in one
configuration.

**The last row is the port's own doing.** `sparql10-expr-builtin` sat
out for one entry — `dawg-lang-3`, `?x :p "string"@EN` against
`"string"@en` — because neither the RDF parser nor the SPARQL parser
normalized a language tag's case, so the two terms were different keys
in odin-rdf-store's dictionary. odin-rdf-record folds language tags to
lowercase on intern, which is RDF 1.1's own rule (Concepts §3.3: the
value space of language tags is lower case) and what the DAWG entry
expects. The directory went green without anything in this engine
changing.

Two directories are still out, neither for a reason the port touched:
`sparql11-subquery` (ten entries whose data is RDF/XML, which
odin-rdf-parser does not implement — the count is pinned in
`readers_test.odin`) and `sparql10-i18n` (`normalization-02` expects an
IRI to match unnormalized, and the two parsers disagree: Turtle's removes
dot segments where SPARQL's does not — measured at SPARQL-T-0033, and a
question for the family's IRI normalization decision rather than for any
store).

## What DESCRIBE returns

§16.4 defines DESCRIBE's *shape* and leaves its *content* to the
implementation: the result is an RDF graph "describing" the named
resources, and which triples that is nobody's business but the engine's.
So no W3C evaluation directory pins DESCRIBE output. That is measured
rather than assumed: the vendored corpus contains no `qt:QueryDescribe`
entry and no query whose form is DESCRIBE at all. The form is therefore
covered by `sparql/forms_test.odin` instead, which is the only place its
behaviour is stated. (It was `sparql/kvstore/forms_test.odin` until
SPARQL-T-0032 made the engine one package.)

This engine answers a DESCRIBE with **every triple of the query's default
graph whose subject is a described resource**. Nothing else: no
blank-node closure, no incoming triples, no schema. A resource the data
says nothing about, or one the store has never heard of, contributes
nothing rather than failing. It is the smallest answer that is a
description, and it is stable — which is what a caller can build on when
the specification promises nothing.

## The three that are not enabled

Forty evaluation directories are vendored and thirty-seven are enabled.
Two of the other three fail exactly one entry; the third fails ten, all
for one reason. Across the corpus of 556 evaluable entries, 544 pass —
97.8%. Each failure is recorded here rather than skipped, with what it
is waiting for. Re-measured 2026-08-09; the 2026-08-06 correction below
still stands.

| Directory | | Entry | Waiting on |
|---|---|---|---|
| `sparql10-expr-builtin/` | 24/25 | `dawg-lang-3` | SPARQL-T-0021 |
| `sparql10-i18n/` | 4/5 | `normalization-2` | SPARQL-T-0021 |
| `sparql11-subquery/` | 4/14 | `subquery01`–`subquery10` | RDF/XML in odin-rdf-parser |

Those three directories hold **32 passing entries** that no test asserts,
because enablement is per-directory: a directory with one known failure
is dark in its entirety. Enabling all three with pinned counts would take
asserted coverage from 512 to 544 without fixing anything.

**It was five directories until 2026-08-09**, when SPARQL-T-0020 settled
the last two failures that were this engine's own semantics and
`sparql10-graph` and `sparql11-negation` joined the enabled list at 17 and
12. Both entries — `graph-optional` ("the variable bound by the GRAPH
operator is not used when evaluating a nested OPTIONAL") and `graph-minus`
("outer GRAPH operator does not affect MINUS disjointness") — turned out
to be one reading of §18.5 and not two problems: `Graph(?g, P)` evaluates
P against one graph at a time and joins `?g` on afterwards, so `?g` is not
in scope inside the clause and an operator in there that sees more than
one solution at a time must not have it in its domain. SPARQL-T-0013 had
declined to fit the code to the DAWG's `graph-optional` answer without a
reading it could defend; the reading is `graph-variable-scope`'s own
comment, which is in this corpus and says "the variable bound by the GRAPH
operator is not in-scope inside it". See `Plan_Graph_Bind` in
`sparql/plan.odin`.

**Two are term identity, and they are the family's question rather than
this engine's.** `dawg-lang-3` asks for `?x :p "string"@EN` against
`"string"@en`: BCP 47 tags are case-insensitive, so those are one
literal, but neither the RDF parser nor the SPARQL parser folds the case
and they intern as two keys. `normalization-2` is the same shape for
IRIs — `eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz` against its RFC 3987
syntax-normalized form. The engine compares Term_IDs; by the time it
sees them the decision has been made upstream, and the answer has to
hold for the RDF parser, both store dictionaries, and the SPARQL parser
at once.

**Ten wait on a format, not on an operator.** `subquery01` through
`subquery10` carry RDF/XML data documents, which odin-rdf-parser does
not implement and — per its own vision, which puts RDF/XML and JSON-LD
out of scope — is not planned to. Those ten are a permanent ceiling
rather than a pending task, so `sparql11-subquery` tops out at 4/14.
What is lost with them is this directory's coverage of subqueries
interacting with `GRAPH` and `FROM NAMED`, since those are the entries
whose datasets are RDF/XML; subqueries themselves are exercised
throughout the enabled directories. All eleven RDF/XML references in the
vendored corpus are in this one directory, so the cost is bounded here
and nowhere else.

**Correction (2026-08-06).** This section previously recorded
`sparql11-subquery` as 4/5 failing the single entry `sq11`. It is 4/14
failing ten, and `sq11` is one of the four that *pass* — its data
document is Turtle. `zz_survey_test.odin` formatted its counters with
`%-3d`, which fills on the right with `0`, so `1` and `10` both printed
as `100` and ten failures read as one. `dataset.odin`'s comment had the
number right all along; only these summaries were wrong. The format
string now right-aligns, and the four other rows are re-verified.

`harness/zz_survey_test.odin` runs *every* vendored directory and logs
pass/mismatch/unsupported counts without asserting anything. It is a
development instrument rather than a guard: it is what turns "which
directory should this task enable" into a measurement, and setting its
`DETAIL` list prints the got/want of a directory's mismatches.
