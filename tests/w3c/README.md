# Vendored W3C SPARQL test suites

Official conformance test suites for SPARQL 1.1 Query, vendored so the
harness runs hermetically with no network access.

- **Source**: https://github.com/w3c/rdf-tests
- **Upstream commit**: `767554e135eb6665949d870e6fa7bbc813837293` (main) —
  the same commit odin-rdf-parser pins for its format suites
- **Retrieved**: 2026-08-05 (syntax suites), 2026-08-05 (evaluation
  suites, SPARQL-T-0010)
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

Not vendored, per the vision's scope: the SPARQL Update directories
(`add/`, `basic-update/`, `clear/`, `copy/`, `delete*/`, `drop/`,
`move/`, `update-silent/`, `syntax-update-1/`, `syntax-update-2/`),
federation (`service/`, `service-description/`, `syntax-fed/`), the
protocol directories (`protocol/`, `graph-store-protocol/`,
`http-rdf-update/`), entailment regimes (`entailment/`), the SPARQL 1.0
syntax directories (`syntax-sparql1/` … `syntax-sparql5/`, superseded by
the 1.1 syntax suite), and the result-serialization suites
(`csv-tsv-res/`, `json-res/`) — writing result formats is a later
initiative, and this one needs expected-result *readers* only. The
SPARQL 1.2 evaluation directories (`eval-triple-terms/`, `expression/`,
`grouping/`) are vendored by SPARQL-T-0018.

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
RDF/XML, used only by `sparql10-sort/`). The XML and RDF/XML readers work
over deliberately narrow subsets — see the notes at the top of
`harness/xml.odin` and `harness/rsvocab.odin` — and `readers_test.odin`
holds those assumptions to the whole vendored corpus by reading every
expectation the manifests name.

Suite directories are enabled individually; once a directory is enabled,
it must be fully green — no skip lists, no expected-failure files.
Positive syntax tests and the query side of evaluation tests must parse;
negative syntax tests must be rejected. SPARQL Update entries mixed into
a vendored directory are counted and acknowledged as out of engine
scope, never silently skipped. Each test's base IRI is the upstream
suite location plus the file name.

Evaluation *enablement* — running a directory's queries and comparing
their answers — arrives per task through the evaluation initiative. The
floor for every vendored evaluation directory, enabled or not, is that
its manifest reads, its expectations parse (508 across four formats), its
data loads, and its queries parse and translate.

Enabled for evaluation so far, each fully green against **both** backends
(memstore and kvstore) at both Term_ID widths:

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

That is **203 evaluation tests across nineteen directories**, each run against
both backends at both Term_ID widths.

`harness/zz_survey_test.odin` runs *every* vendored directory and logs
pass/mismatch/unsupported counts without asserting anything. It is a
development instrument rather than a guard: it is what turns "which
directory should this task enable" into a measurement, and setting its
`DETAIL` list prints the got/want of a directory's mismatches.
