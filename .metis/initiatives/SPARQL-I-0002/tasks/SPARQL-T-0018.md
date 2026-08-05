---
id: sparql-1-2-evaluation-suites-and
level: task
title: "SPARQL 1.2 evaluation suites and triple-term evaluation"
short_code: "SPARQL-T-0018"
created_at: 2026-08-05T15:15:43.995264+00:00
updated_at: 2026-08-05T15:15:43.995264+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# SPARQL 1.2 evaluation suites and triple-term evaluation

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Complete the SPARQL-T-0008 handover: vendor the sparql12 *evaluation* suite directories (deliberately left unvendored by the parser initiative) from the pinned rdf-tests commit, and make triple-term evaluation fully conformant — triple terms as subjects/objects in BGP matching (the store encodes them as first-class Term_IDs), in expressions (the T-0014 accessors), in CONSTRUCT templates, and in results (SRX/SRJ 1.2 triple-term encoding in the readers and comparison).

## Acceptance Criteria **[REQUIRED]**

- [ ] sparql12 evaluation directories vendored from the pinned commit with provenance README updated (or, if upstream has not published them at that commit in runnable form, the gap documented with the upstream state and this criterion re-scoped with human sign-off).
- [ ] Triple-term BGP matching green: patterns with quoted-triple terms probe via the dictionary's triple-term IDs (component find via `find_term`; absent components short-circuit to empty).
- [ ] Expression-level triple-term semantics green: TRIPLE/SUBJECT/PREDICATE/OBJECT/isTRIPLE over stored and computed triple terms; equality/sameTerm on triple terms.
- [ ] SRX/SRJ readers and result comparison handle 1.2 triple-term result encoding.
- [ ] All enabled sparql12 evaluation directories fully green at both widths against enabled backends.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
Mostly integration: the machinery exists after T-0010…T-0017; this task closes the 1.2-specific gaps found by the suites. Check upstream `w3c/rdf-tests` sparql12 state at the pinned commit first — if the eval suites landed after the pin, propose either a second pinned commit for the sparql12 tree (documented in the provenance README, as the family convention allows per-directory pinning) or defer with evidence.

### Dependencies
SPARQL-T-0010 (readers), T-0011 (BGP), T-0012/T-0014 (expressions/accessors), T-0017 (CONSTRUCT) — effectively last-but-one.

### Risk Considerations
Spec/suite instability is the known risk (the initiative scopes this "to the extent published and stable"); the acceptance criteria carry an explicit documented-gap escape hatch requiring human sign-off, mirroring how T-0008 handled the syntax side.

## Status Updates **[REQUIRED]**

*To be added during implementation*