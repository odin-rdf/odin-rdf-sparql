---
id: var-slot-lookup-is-a-linear
level: task
title: "var_slot_lookup is a linear scan on the per-solution path — measure it before replacing it"
short_code: "SPARQL-T-0050"
created_at: 2026-09-05T00:00:00.000000+00:00
updated_at: 2026-09-05T00:00:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/backlog"
  - "#tech-debt"


exit_criteria_met: false
initiative_id: NULL
---

# var_slot_lookup is a linear scan on the per-solution path — measure it before replacing it

## Objective

Decide, on a measurement rather than on inspection, whether
`var_slot_lookup` (`sparql/plan.odin:102`) should stop being a linear scan.
**The measurement is the first half of this task and it gates the second**: if
a filter-heavy benchmark case does not show the scan, this closes as evidence
with the case kept, exactly as `SPARQL-T-0038` did.

## Context

`var_slot_lookup` walks the whole slot table on every call:

```odin
for candidate, i in vs.names {
	if !vs.internal[i] && candidate == name {
		return i, true
	}
}
```

Its own doc comment states the frequency — *"called per variable occurrence
per solution during expression evaluation"* — and the two hot call sites bear
that out: `var_value` (`sparql/expr_eval.odin:566`), which every `Var` node in
an evaluated expression reaches, and `eval_bound` (`sparql/functions.odin:209`).
The other three call sites are plan-time and do not matter: `expr_within`
(`expr_eval.odin:797`, `probe_safe`), `template_build` (`construct.odin:240`,
CONSTRUCT compilation) and the DESCRIBE setup (`construct.odin:512`).

**`Var_Slots` already holds a `map[string]int`** and this procedure
deliberately bypasses it. `vs.index` is keyed by a sigil-prefixed key — `"?x"`
against `"_:x"`, so a query variable and a pattern blank node of the same name
stay distinct — and building that key in `slot_for` (`plan.odin:134`) calls
`strings.concatenate`. The scan is the documented workaround for what would
otherwise be a per-solution allocation, which is a real constraint and not an
oversight. Any fix has to keep both properties: the two namespaces separate,
and nothing allocated per row.

The cost is bounded by the solution row width, so a query with a handful of
variables pays a handful of comparisons per variable occurrence per row. That
is why this is a measurement and not a defect. What makes it worth measuring
at all, rather than filing beside the engine's other iterate-in-order tables,
is that it is **the only array-as-lookup in this package that scales with
result count** — a survey on 2026-09-05 found no static lookup table here that
wants to be a map (dispatch is `#partial switch` on `Builtin`/`Op`/`Keyword`,
which lowers to a jump table; the string switches are 3–8 cases or
`lookup_keyword_word`, which is once per token at parse time).

**`bench/` cannot see this today, and that is the first thing to fix.** None
of the twenty pinned cases in `bench/config.odin` issues a `FILTER`, a `BIND`
or a `BOUND`, so the per-solution expression path is unmeasured. The corpus
was built expecting one — `generate.odin:83` describes `bench:name` as "a
literal, for FILTER and ORDER BY" — so the data is already there and only the
case is missing.

## Acceptance Criteria

**Gate — do this first, and stop here if it does not fire.**

- [ ] A filter-heavy case is added to `bench/config.odin` and pinned like
      every other: a `FILTER` over `bench:name` with several variable
      occurrences per solution, at both `small` and `large`, with its
      `solutions`/`match`/`next`/`load`/`find`/`candidates` row recorded.
      This case is kept whatever the outcome — the expression path being
      unmeasured is itself a gap.
- [ ] The timing build is run against it and the wall-clock share attributable
      to `var_slot_lookup` is established — a profile, or an A/B against a
      scratch branch that hard-codes the slot. State the figure and the row
      width it was taken at.
- [ ] **Gate:** proceed only if the scan is **≥ 5% of `validate`-equivalent
      query wall clock** on that case at `large`. Below that, close this task
      as evidence, record the measured figure in the Notes, and leave
      `var_slot_lookup` as written — a linear scan over a handful of names is
      not worth an allocation or a second index.

**Implementation — only if the gate fires.**

- [ ] The lookup is O(1) without allocating per row, and without collapsing
      the `?x` / `_:x` namespaces. Two shapes are worth costing before
      picking: a second `map[string]int` holding only the non-internal slots
      keyed by bare name, or a stack buffer for the key in `slot_for` so the
      concatenate stops allocating and `vs.index` can serve both callers.
- [ ] `make test` green; the W3C survey byte-identical at 546/546.
- [ ] `make bench`: every existing read count and solution count in
      `bench/config.odin` unmoved at both sizes — this changes lookup cost, so
      nothing it touches should change what is read — and the new case's
      timing improvement recorded.
- [ ] The doc comments on `var_slot_lookup` and `slot_for` are rewritten
      rather than left describing a workaround that is gone.

## Notes

Filed from a survey of static lookup tables across `sparql/` on 2026-09-05.
The survey's own answer was that there is nothing to convert — this engine
dispatches with `switch`, not with tables — and this is the one finding that
came out of it, in the opposite direction from the question that prompted it:
not a static table, and not something a map *literal* fixes.

The same survey was run against `odin-rdf-shacl` first and closed with no
change. Its two candidates — `IMPLEMENTED_PARAMETERS` and `INERT_PARAMETERS`,
scanned linearly by `parameter_is_ignored` — turned out to be compile-time
only, once per process, inside a `compile` that costs ~35 µs, so a map would
have bought a sliver of a cold startup number and nothing else. The contrast
is the reason this one is worth a measurement: **shacl's scan does not scale
with anything, and this one scales with result count.** It is also the reason
the gate exists — the shacl survey's lesson is that "a linear scan on a path
that sounds hot" is not by itself a finding.

Odin also rejects a package-level map literal unless the file carries
`#+feature dynamic-literals` above its `package` line, which switches dynamic
literals on for the whole file and leaves a global allocation nobody frees.
Not directly relevant here — `Var_Slots` is per-query and allocator-aware —
but it is the mechanical fact that ended the shacl half, and worth knowing
before reaching for a map anywhere in this family.
