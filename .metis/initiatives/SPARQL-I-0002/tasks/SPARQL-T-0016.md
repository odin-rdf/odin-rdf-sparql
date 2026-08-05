---
id: property-path-evaluation-per-18-4
level: task
title: "Property-path evaluation per §18.4"
short_code: "SPARQL-T-0016"
created_at: 2026-08-05T15:15:40.931668+00:00
updated_at: 2026-08-05T15:15:40.931668+00:00
parent: SPARQL-I-0002
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/todo"


exit_criteria_met: false
initiative_id: SPARQL-I-0002
---

# Property-path evaluation per §18.4

## Parent Initiative **[CONDITIONAL: Assigned Task]**

[[SPARQL-I-0002]]

## Objective **[REQUIRED]**

Property-path evaluation per §18.4, over the path expressions the algebra translation produced (link-only paths were already simplified to triple patterns in SPARQL-I-0001): inverse (`^`), sequence (`/`), alternative (`|`), negated property sets (including inverse members), zero-or-one (`?`), and the reachability forms zero-or-more (`*`) and one-or-more (`+`) with cycle-safe traversal and the spec's set (not bag) semantics for those forms.

## Acceptance Criteria **[REQUIRED]**

- [ ] Sequence/alternative/inverse compose with the existing operator machinery (sequence introduces a fresh internal join variable; inverse swaps probe direction).
- [ ] Negated property sets: forward and inverse member partitions evaluated per spec (match any predicate not in the set, in the respective direction).
- [ ] `*`/`+`: BFS reachability over Term_IDs with a visited set; all four binding cases correct (both ends bound, either end bound, both free — both free iterates all subject/object nodes per spec); `*` includes zero-length paths for every relevant node including literals-as-objects cases the suites encode.
- [ ] Set semantics for `?`/`*`/`+` results (no duplicate solutions from multiple routes); bag semantics preserved elsewhere.
- [ ] Cycles terminate; deep chains do not overflow (iterative BFS frontier, not recursion).
- [ ] Property-path evaluation directories enabled and fully green; dual-width matrix green; visited-set/frontier allocations through the query allocator, guard-checked.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach
A path-evaluation iterator family beside the BGP probe: evaluates one path step as match() probes, with reachability driven by an explicit frontier queue. Both-ends-free reachability enumerates candidate start nodes from the graph's terms — note in the store-evidence log that a term-enumeration/ordered-iteration capability would serve this better than MATCH_ALL scans.

### Dependencies
SPARQL-T-0011 (BGP probe machinery, GRAPH interaction comes via T-0013 but path suites gate on both).

### Risk Considerations
Zero-length-path semantics (which nodes count, graph vs dataset scope) is the classic error well — encode the spec's definition as unit cases first. Visited-set growth on dense graphs is bounded by node count, acceptable for suite scale; note real-world bounds in the evidence log rather than engineering around them now.

## Status Updates **[REQUIRED]**

*To be added during implementation*