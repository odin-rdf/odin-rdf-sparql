---
id: built-in-function-library-the-full
level: task
title: "Built-in function library: the full §17 set"
short_code: "SPARQL-T-0014"
created_at: 2026-08-05T15:15:38.105123+00:00
updated_at: 2026-08-05T18:59:09.162557+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/active"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Built-in function library: the full §17 set

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The complete §17 built-in function library on top of the T-0012 value model: term accessors/tests (STR, LANG, DATATYPE, isIRI/isBlank/isLiteral/isNumeric, langMatches), constructors (IRI, BNODE, STRDT, STRLANG, UUID, STRUUID), strings (STRLEN, SUBSTR, UCASE, LCASE, STRSTARTS, STRENDS, CONTAINS, STRBEFORE, STRAFTER, CONCAT, ENCODE_FOR_URI, REGEX, REPLACE), numerics (ABS, ROUND, CEIL, FLOOR, RAND), dateTime (NOW, YEAR…SECONDS, TIMEZONE, TZ), hashes (MD5, SHA1, SHA256, SHA384, SHA512), COALESCE/IF, the XSD casts (§17.5), and the RDF-star accessors (TRIPLE, SUBJECT, PREDICATE, OBJECT, isTRIPLE) matching what the 1.2 grammar already parses.

## Acceptance Criteria

## Acceptance Criteria **[REQUIRED]**

- [ ] Every §17 function callable with spec-conformant argument-type checking and error propagation; unit tests per function sourced from the spec's definitions and examples.
- [ ] REGEX/REPLACE semantics documented against Odin's `core:text/regex` capabilities; any deviation from XPath regex flavor is called out explicitly and every suite-exercised pattern works.
- [ ] Hash functions via `core:crypto`; UUID/BNODE/RAND/NOW deterministic-enough handling for tests (suites avoid asserting exact values; NOW fixed per query per spec).
- [ ] XSD casts per the §17.5 cast table, reusing T-0012's lexical parsing module.
- [ ] String functions correct on unicode (argument compatibility rules for lang-tagged strings per §17.4.3.1 — the derived-lang rules for CONCAT/SUBSTR etc.).
- [ ] Function-heavy evaluation directories enabled and fully green (candidates: functions, regex, cast, type-promotion remainder, project-expression per final harness mapping); dual-width matrix green.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
One dispatch table from the algebra's function IDs to implementations over the value union. BNODE's per-solution/per-label scoping and NOW's fixed-per-query value live in the query's evaluation context, not globals.

### Dependencies
SPARQL-T-0012 (value model, lexical parsing, error semantics). Runs in parallel with SPARQL-T-0013 after that.

### Risk Considerations
Regex flavor mismatch (XPath vs core:text/regex) is the main unknown — scope it early by running the regex suite's patterns through core:text/regex before committing; hand-implement the gap or document the deviation with suite evidence if any pattern is unrepresentable.

## Status Updates **[REQUIRED]**

### Regex flavour scoped first (the task's named risk)

Measured `core:text/regex` (Odin dev-2026-07) against every pattern the
suites exercise before committing to it. Four gaps, two of them not
fixable from outside the library:

| Behaviour | XPath requires | `core:text/regex` | Workaround |
| --- | --- | --- | --- |
| `.` without `s` | must not match `\n`/`\r` | always matches; no dot-all flag (it is the default) | rewrite `.` to `[^\n\r]` |
| `q` flag | pattern is literal | unsupported | escape the pattern |
| `^` with `m` | matches after a newline | **never matches** | none |
| `$N` in REPLACE | unmatched group is empty | capture slots compacted | none |

The multiline failure is an upstream off-by-one at
`virtual_machine/virtual_machine.odin:204`: `Assert_Start_Multiline`
compares `sp := vm.string_pointer + vm.current_rune_size` (one rune
ahead) against `vm.last_rune` (one rune behind), so the two never line
up. Measured: `^b` with `Multiline` on `"a\nb"` gives false, also with
`No_Optimization`, inside a group, and behind an alternation. That is
`regex-start-end-multiline`, whose expectation is that `^b$` matches
`"a\nb\nc"`.

The REPLACE gap: both `match_and_allocate_capture` and
`match_with_preallocated_capture` skip `a == -1` groups and compact the
array, so an unmatched group disappears rather than reporting empty —
and `replace03` is exactly that case
(`REPLACE("abcd","(ab)|(a)","[1=$1][2=$2]")` yields `[1=ab][2=]cd`).
Backreferences and `\p{...}` are also unsupported, though no suite
pattern needs them.

**Decision (with the user, who raised the question directly): hand-write
the XPath 2.0 flavour** in `sparql/regex.odin` — the task's stated
fallback. Keeps the package dependency-free and lets `sparql10-regex`
and the REPLACE tests be held to the same no-skip-list rule as every
other enabled directory.

### Bug found in the value layer while surveying

`sparql10-expr-builtin/dawg-str-4` and `dawg-lang-2` fail today for a
reason that is not about built-ins at all: `value_compare` uses
`strings.compare`, which bottoms out in `runtime.memory_compare`, and
that returns plus/minus 1 rather than 0 for two zero-length strings
whose data pointers differ (`case x == nil: return -1`). So
`lang(?v) = ""` was false for every solution. `core:bytes.compare`
guards this case; `runtime.string_cmp` does not. Fixing with a local
codepoint-order comparison in value.odin.

`dawg-lang-3` (`?x :p "string"@EN` must match `"string"@en`) is a
separate, term-level issue: neither the RDF parser nor the SPARQL parser
normalizes language-tag case, so `find_term` misses. Out of scope here —
recorded for a follow-up.

### Baseline (survey, memstore)

Target directories before this task: `sparql10-regex` 0/21
(unsupported), `sparql11-functions` 7/75, `sparql10-cast` 0/7 and
`sparql11-cast` 0/6 (both "extension function" — the §17.5 casts arrive
as `Function_Call` with an XSD IRI), `sparql10-expr-builtin` 22/25.

### Done

Four new files and five edited ones; `make test` green at both Term_ID
widths, `make check` clean.

- **`sparql/regex.odin`** — the XPath 2.0 flavour: a backtracking
  bytecode VM (Thompson construction, Cox's recursive matcher). No AST —
  a quantifier lifts the code its atom just emitted and re-places it,
  rebasing absolute jump targets. Flags i/s/m/x/q, character classes
  with XSD subtraction (`[a-z-[aeiou]]`), `\d \s \w \i \c` and the
  `\p{...}` categories, back-references, reluctant quantifiers, and a
  Mark/Progress guard so an empty-matching loop body terminates. A step
  budget bounds the search and an overrun is *reported* (type error),
  never answered "no match". `regex_replace` keeps unmatched capture
  slots at -1, which is what `$N` needs.
- **`sparql/functions.odin`** — the library. The dispatch has two
  halves: the five forms that must not evaluate all their arguments
  (BOUND, COALESCE, IF, CONCAT, and the nullary ones) come first, then
  the strict path.
- **`sparql/expr_eval.odin`** — the query-scoped state the impure
  functions need: NOW's single instant, a splitmix64 seed for RAND and
  UUID, BNODE's per-solution memo, a per-evaluation string scratch, and
  a compiled-regex cache (held behind a pointer so the dynamic array's
  growth cannot dangle a caller's `^Regex`).
- **`sparql/value.odin`** — `text_compare` (the empty-string bug above),
  the value constructors, and `number_text`.
- **Base IRI plumbing** — `parser_base`, a `base` parameter on both
  `query_init`s, `exec_set_base`. IRI() resolves a reference the query
  computes at runtime, so the base has to reach evaluation; `resolve.odin`
  grew `iri_resolve_build`, which is `iri_resolve` without interning
  (a runtime value must not enter the parser's table).

Two decisions worth keeping:

- **`value_to_term` now renders a value's own term when it has one**,
  instead of canonicalizing. STRDT("1", xsd:byte) must not come back as
  `"1"^^xsd:integer`, and a date or an uninterpreted datatype has no
  canonical form to write.
- **A literal's canonical lexical form and its rendering *as a string*
  are different functions.** `value_to_term` needs `"0.0"^^xsd:decimal`
  to be a well-formed decimal; `xsd:string(0.0)` is pinned by
  `sparql11-cast/cast-string` as `"0"`, and `xsd:string(0E1)` as `"0"`.
  Hence `number_text` alongside `numeric_lexical`. Also fixed: STR of a
  *computed* number returned "" — a computed value has no lexical form
  until STR gives it one.

### Results

| Directory | Before | After |
| --- | --- | --- |
| `sparql11-functions` | 7/75 | **75/75** |
| `sparql10-regex` | 0/21 | **21/21** |
| `sparql10-cast` | 0/7 | **7/7** |
| `sparql11-cast` | 0/6 | **6/6** |
| `sparql10-expr-builtin` | 22/25 | 24/25 |

All four are enabled in `eval_test.odin` and green against both backends
at both widths — 312 evaluation tests across 23 directories, up from
203. 41 new unit tests: 11 in `regex_test.odin` (every DAWG pattern
plus the flavour constructs no suite reaches), 14 in `functions_test.odin`
(written from §17's own worked examples — every row of STRBEFORE's and
STRAFTER's tables, the hash vectors, the cast table). One of them,
`test_fn_coverage_is_declared`, asserts that every built-in the grammar
parses is either implemented or on the named pending list, so a function
added to the grammar and forgotten cannot silently become a type error.

`tests/guards` gained seven queries covering the new allocation
lifetimes (per-evaluation strings, the query-lifetime regex cache,
per-solution BNODE labels, and a compilation that fails halfway).

### Two fixes outside the function library

- `tests/w3c/harness/results.odin`: the solution key wrote language tags
  verbatim while `literals_equivalent` compared them case-insensitively,
  so `STRLANG(?s, "en-US")` and an expectation written `en-us` were
  pruned apart before they were ever compared. The key now folds, as its
  own comment already said it had to.
- The regex path allocated from `context.temp_allocator` once per
  solution. Nothing in this engine resets that arena, and the executor's
  contract is that a streaming operator allocates nothing per solution,
  so the working memory is now an explicit `Rx_Scratch` the caller owns.

### Left undone, deliberately

- **`sparql10-expr-builtin` stays disabled at 24/25.** `dawg-lang-3`
  needs `"string"@EN` to match `"string"@en`; neither the RDF parser nor
  the SPARQL parser normalizes language-tag case, so `find_term` misses.
  A query-side-only fix would be asymmetric (data written `@EN` would
  still miss), so the real change is in odin-rdf-parser, on both sides of
  the family. Recorded in `tests/w3c/README.md`.
- **LANGDIR, STRLANGDIR, hasLANG, hasLANGDIR** are parsed and listed as
  pending in `builtin_implemented`; they belong with the rest of the 1.2
  surface in SPARQL-T-0018. `test_fn_coverage_is_declared` pins that
  list, so they cannot be forgotten.
- **`sparql11-project-expression` is not enabled**: 6/7, with the
  seventh blocked on ORDER BY (SPARQL-T-0015), not on §17.
- `regex.odin`'s header records the two `core:text/regex` bugs as worth
  filing upstream, and says plainly that deleting the file later would
  be a good outcome.