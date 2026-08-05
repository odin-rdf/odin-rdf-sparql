# Vendored W3C SPARQL test suites

Official conformance test suites for SPARQL 1.1 Query, vendored so the
harness runs hermetically with no network access.

- **Source**: https://github.com/w3c/rdf-tests
- **Upstream commit**: `767554e135eb6665949d870e6fa7bbc813837293` (main) —
  the same commit odin-rdf-parser pins for its format suites
- **Retrieved**: 2026-08-05
- **License**: W3C Test Suite License / W3C 3-clause BSD License (see the
  header of each `manifest.ttl`)

| Directory | Upstream path | Contents |
|---|---|---|
| `sparql11-syntax-query/` | `sparql/sparql11/syntax-query/` | SPARQL 1.1 query syntax tests (positive + negative) |
| `sparql11-aggregates/` | `sparql/sparql11/aggregates/` | Aggregate tests (5 negative syntax; rest evaluation) |
| `sparql11-construct/` | `sparql/sparql11/construct/` | CONSTRUCT tests (2 positive syntax; rest evaluation) |
| `sparql11-grouping/` | `sparql/sparql11/grouping/` | GROUP BY tests (2 negative syntax; rest evaluation) |
| `sparql12-syntax/` | `sparql/sparql12/syntax/` | SPARQL 1.2 general syntax tests (GROUP BY scope, nested aggregates) |
| `sparql12-syntax-triple-terms-positive/` | `sparql/sparql12/syntax-triple-terms-positive/` | Triple terms, reified triples, reifiers, annotations (positive) |
| `sparql12-syntax-triple-terms-negative/` | `sparql/sparql12/syntax-triple-terms-negative/` | The same surface, negative |
| `sparql12-codepoint-escapes/` | `sparql/sparql12/codepoint-escapes/` | 1.2 codepoint-escape restriction (strings/IRIs only) |
| `sparql12-lang-basedir/` | `sparql/sparql12/lang-basedir/` | Directional language tags |
| `sparql12-version/` | `sparql/sparql12/version/` | VERSION declaration |

The vendored directories are the sparql11 and sparql12 directories
whose manifests contain query syntax tests. Directories are copied
verbatim, so evaluation entries and SPARQL Update entries mixed into
them ride along: evaluation queries must parse (evaluation itself runs
in the evaluation initiative), while Update tests
(`mf:*UpdateSyntaxTest`, `mf:UpdateEvaluationTest`) are explicitly
acknowledged as out of the engine's scope by the harness — SPARQL
Update is a vision-level exclusion, counted in the log line and never
silently skipped. Intentionally not vendored, per the vision's scope:
`syntax-update-1/`, `syntax-update-2/`, `delete-insert/` (SPARQL
Update), `syntax-fed/` (federation), the protocol and service
directories, and the purely-evaluation suites (sparql11 eval dirs and
sparql12 `expression/`, `grouping/`, `eval-triple-terms/` — vendored
later by the evaluation initiative).

The harness lives in `harness/` and runs under `odin test`. Manifests
are parsed with the family's own Turtle parser through the `rdf:`
collection. Each suite test asserts a pinned entry count — the guard
against a manifest-reader regression silently dropping tests. All four
directories are enabled (SPARQL-T-0005) and must stay fully green — no
skip lists, no expected-failure files. Positive syntax tests and the
query side of evaluation tests must parse; negative syntax tests must
be rejected; evaluation itself belongs to the evaluation initiative.
Each test's base IRI is the upstream suite location plus the query
file name.
