---
id: built-in-function-library-the-full
level: task
title: "Built-in function library: the full §17 set"
short_code: "SPARQL-T-0014"
created_at: 2026-08-05T15:15:38.105123+00:00
updated_at: 2026-08-05T15:15:38.105123+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Built-in function library: the full §17 set

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

The complete §17 built-in function library on top of the T-0012 value model: term accessors/tests (STR, LANG, DATATYPE, isIRI/isBlank/isLiteral/isNumeric, langMatches), constructors (IRI, BNODE, STRDT, STRLANG, UUID, STRUUID), strings (STRLEN, SUBSTR, UCASE, LCASE, STRSTARTS, STRENDS, CONTAINS, STRBEFORE, STRAFTER, CONCAT, ENCODE_FOR_URI, REGEX, REPLACE), numerics (ABS, ROUND, CEIL, FLOOR, RAND), dateTime (NOW, YEAR…SECONDS, TIMEZONE, TZ), hashes (MD5, SHA1, SHA256, SHA384, SHA512), COALESCE/IF, the XSD casts (§17.5), and the RDF-star accessors (TRIPLE, SUBJECT, PREDICATE, OBJECT, isTRIPLE) matching what the 1.2 grammar already parses.

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

*To be added during implementation*