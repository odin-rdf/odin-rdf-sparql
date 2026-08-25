---
id: bench-the-first-measurement-this
level: task
title: "bench/ rebuilt against record: the same workload, and whether the read counts held"
short_code: "SPARQL-T-0036"
created_at: 2026-08-24T20:42:43.053786+00:00
updated_at: 2026-08-25T14:20:00.000000+00:00
parent: SPARQL-I-0003
blocked_by: ["SPARQL-T-0033", "SPARQL-T-0040"]
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: SPARQL-I-0003
---
# bench/ rebuilt against record: the same workload, and whether the read counts held

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Rebuild SPARQL-T-0040's bench against record — same workload, same query
mix, same pinned counts — and answer the question the two-step exists
for: **did the read counts hold?**

odin-rdf-shacl's port found that its did, to the integer, across three
backends; its own acceptance criterion had predicted they would not and
the measurement reversed it. If sparql's hold too, the port moved cost
and not behaviour, which is the strongest statement this initiative can
make about its own correctness. If they do not, the engine's control
flow changed when it was supposed only to change store — the most
interesting result available here, and one that sends work back to
SPARQL-T-0031 rather than forward.

It also produces the record-side half of the initiative's §12 evidence:
`RECORD-A-0004`'s G-residual permutations turn `GRAPH <g> { … }` from a
prefix range into a scan, and T-0040 measured what that cost on the
store.

## Acceptance Criteria

- [x] **The same workload, ported.** SPARQL-T-0040's query mix, fixture
      generator shape, reporting and pinned counts carry over unchanged;
      only the store setup is rewritten — `open_ephemeral` + `load_*`
      becomes `Mem_FS` + `store_open` + `ingest` + `apply`. A workload
      that drifts in the rebuild answers a different question and makes
      the comparison meaningless.
- [x] **The read counts are compared against T-0040's pins, and the
      result is reported either way.** This is the task's headline.
      Equal counts mean the engine asks record exactly the questions it
      asked LMDB — the port moved cost, not behaviour. Unequal counts
      mean the control flow changed when only the store was supposed to,
      and the finding goes back to SPARQL-T-0031 rather than forward.
      **Do not write the verdict before the run**: shacl's equivalent
      criterion predicted the counts would be incomparable, and its
      Status records the author taking that prose back out after the
      first run.
- [x] **Read counting rehomed.** With the parapoly seam collapsed there
      is no adapter struct to wrap, so the counter goes around the
      engine's calls to `snapshot_match` / `range_iter` / `scan_next` /
      `snapshot_resolve` / `snapshot_term`. `make bench` stays two
      builds — timed and instrumented — because counting inside the
      timed build measures the counter.
- [x] **The `GRAPH` case re-measured at the same ratios**, giving the
      record-side half of the initiative's §12 evidence. T-0040 measured
      what a graph-first index cost; this measures what
      `RECORD-A-0004`'s G-residual permutations cost, and the pair is
      what SPARQL-T-0039 files with record. **Neither number alone is
      evidence.**
- [x] **Timings reported as context, not as a target.** LMDB against a
      resident projection is not a like-for-like comparison and the task
      says so. shacl's moved roughly fourfold on validate; expect
      movement here and do not read it as a result.
- [x] **New baselines recorded in this task's Status**, stating machine,
      record version and fixture size — and noting that the width matrix
      is gone, so unlike T-0040's these are single-configuration.
- [x] **`bench/` stays in `SRC_DIRS`** and `make check` vets both builds.

## Implementation Notes

### Technical Approach

**Setup goes through the same door as everything else**: `Mem_FS` +
`ingest` + `apply`. A generated corpus as one epoch is the bulk-load
shape record measures at 222–267 ms for 4×10⁵ facts, so fixture
construction will not dominate the run.

**Where to hook the read counter.** With the parapoly seam collapsed
(SPARQL-T-0031) there is no seam struct to wrap, so the counter goes
around record's read calls in the engine. **Funnelling those calls
through one place is worth arranging during SPARQL-T-0031**, while that
file is open anyway — it is much cheaper than retrofitting a counter into
scattered direct calls afterwards. odin-rdf-shacl hit this exact
consequence of the one-package layout; steal the answer rather than
rediscovering it.

**Read SPARQL-T-0040's Status before starting.** It carries the pins this
task is measured against, the fixture parameters, and whatever its own
run taught about the workload.

**Report shape**: one line per case, name + time + reads, stable enough
to diff between runs. Not a framework.

### Dependencies

Blocked by SPARQL-T-0033 — the engine must be correct before it is worth
timing — and by SPARQL-T-0040, whose pins are the thing being compared
against. Deliberately *before* SPARQL-T-0037 and -T-0038, so those two
have a measured baseline to move rather than a claim to assert.

### Risk Considerations

**The workload drifting during the rebuild is this task's specific
risk.** Every criterion above rests on the two runs asking the same
question; a fixture generated slightly differently, or a query quietly
adjusted to suit record, turns the comparison into two unrelated numbers
that happen to sit in one table. If something genuinely cannot be
reproduced, say so per case rather than adjusting the whole workload.

**Scope discipline.** This task exists to make three specific claims
checkable — the GRAPH regression, the "no result changes" of T-0037/38,
and the port's overall cost. It is not a performance-optimization task
and nothing it measures obliges a fix inside this initiative; a finding
becomes a backlog item.

## Status Updates

*To be added during implementation*


## Status Updates

### 2026-08-25 — handed forward from SPARQL-T-0031: bench already builds and runs, and two pins already moved

**`bench/` was ported at SPARQL-T-0031, not here.** `bench` is vetted by
`make check`, and that task's green boundary is "check vets every
surviving package", so it could not be left naming the deleted
instantiation. `bench/store.odin` is `Mem_FS` + `store_open` + `ingest` +
`apply`, `Bench_Store` is heap-allocated and passed by pointer (record's
writer holds a pointer to the `Mem_FS` inside it), `run_once` acquires
and releases a snapshot per query, and `counting.odin` moved to
`sparql/` with its verbs and meanings unchanged. **This task's job is
what its title says: run it and compare.**

**What SPARQL-T-0031's own run already found**, so that it is not
rediscovered: every solution count is identical to SPARQL-T-0040's
baseline (all sixteen, both configurations), and **fourteen of the
sixteen read-count pins hold to the integer**. Two moved, both `group`,
both by exactly the number of groups — `load` 4000 -> 4012 (small),
40000 -> 40012 (large), `store_ops` following.

The cause is understood and is a term-identity difference rather than a
control-flow regression. `bindable_id` resolves an aggregate's result
against the store so a computed term the data already holds gets the
store's own id. `COUNT(?s)` produces a small canonical integer, which
odin-rdf-store had never interned and which record **inlines** — it
resolves without ever having been stored. The id is therefore real
rather than synthetic, and reading it back in the projection is a load
where it used to be a lookup in the engine's own computed table.
`AVG(?r)` is a decimal, is not inlineable, and did not move; `find` is
26 in both.

**The pins were deliberately left at the odin-rdf-store baseline**, so
`make bench` fails its assertion step until this task re-pins them. That
is the comparison this task exists to make; re-pinning earlier would
have destroyed it. Timings were taken on the ported engine and are in
SPARQL-T-0031's run output but were not recorded as a measurement — the
machine was busy compiling, and a proper best-of-5 belongs here.


### 2026-08-25 — this is the only actionable task; the initiative Status has the session handoff

`main` at `72ccfa6`, clean. Everything before this task is complete
(`T-0030`…`T-0035`, `T-0040`). `SPARQL-I-0003`'s Status carries the full
handoff — what moved, the four owner decisions, the findings. What
matters here, restated so it is not missed:

**`make bench` fails today and is meant to.** It builds and runs both
binaries; the failure is `check_pin` on two of sixteen. Everything else
about the benchmark is ported and working, including all sixteen
solution counts, which are identical to `SPARQL-T-0040`'s odin-rdf-store
baseline.

**The two moved pins, with their cause, so this task can start from
analysis rather than from debugging:**

	small/group   load 4000  -> 4012   (+12 = the number of groups)
	large/group   load 40000 -> 40012  (+12)
	store_ops follows both; find is 26 in each, unchanged.

`bindable_id` (`sparql/exec.odin`) resolves an aggregate's result
against the store, so that a computed term the data already holds gets
the store's own id and a later pattern can match on it. `COUNT(?s)`
produces a small canonical integer. odin-rdf-store had never interned
one; **record inlines it** — a canonical `xsd:integer` in
`RECORD-A-0001`'s range *is* its own id and resolves without ever having
been stored. So the aggregate's id is real rather than synthetic, and
reading it back in the projection is a `load` where it used to be a
lookup in the engine's own computed table. `AVG(?r)` produces a decimal,
is not inlineable, and did not move.

That is a term-identity difference behaving correctly, not a control-flow
regression — and it is arguably an improvement, since
`BIND(?o+1 AS ?z) . ?s ?p ?z` now matches for inlined values. Re-pin
both with a comment saying so.

**Timings were taken but not recorded**, deliberately: T-0031's run was
on a machine that had just been compiling. A best-of-5 on a quiet
machine is this task's, and `config.odin`'s header should say when and
on what.

**The §12 GRAPH question is also this task's.** record has no
graph-first permutation (`RECORD-A-0004`), so a bound graph is always
residual where odin-rdf-store answered it from a prefix range — the
`graph` case's pinned `1 match / 4123 next`, identical in `small` and
`large` while the default graph around it grows tenfold, is the baseline
half of the experiment. It did **not** show as wall-clock anywhere in
the harness (`sparql10-graph` 17/17, the whole harness 1.7 s). Whether
it shows as reads is the measurement, and the answer belongs in
`SPARQL-I-0003` §12.

**One thing to check while measuring**, from the scan-boundary decision
in T-0031: `match_next` copies a `Fact`'s four components into the
engine's own `[4]Term_ID` per matched fact. It was decided as a trade,
not left open. `bgp3` (36.6 ms over 164,933 triples, 380,006 store ops)
and `path` (13.3 ms, 117,674) are where a per-fact 16-byte copy would
show first.

### 2026-08-25 — the counts held, fourteen of sixteen to the integer; and §12 has its other half

**The headline, and it was not written before the run.** Every one of the
sixteen solution counts is identical to `SPARQL-T-0040`'s odin-rdf-store
baseline, and **fourteen of the sixteen read-count pins reproduce to the
integer** — every `match`, every `next`, every `find`. The engine asks
odin-rdf-record exactly the questions it asked LMDB. The port moved cost,
not behaviour, which is the strongest statement `SPARQL-I-0003` can make
about its own correctness, and it is now a measurement rather than a
claim. odin-rdf-shacl's port found the same thing; this is the second
independent instance, on a much larger read surface.

**The two that moved are `small/group` and `large/group`, both `load`,
both by exactly the number of groups** (4000 -> 4012, 40000 -> 40012;
`store_ops` follows, `find` is 26 in both). `SPARQL-T-0031` had already
found and diagnosed them and this run reproduces its analysis exactly:
`bindable_id` resolves an aggregate's result against the store so a
computed term the data already holds gets the store's own id;
`COUNT(?s)` is a small canonical integer, which odin-rdf-store had never
interned and which record **inlines**, so it resolves without ever having
been stored and reading it back is a `load` where it used to be a lookup
in the engine's own computed table. `AVG(?r)` is a decimal, is not
inlineable, did not move. A term-identity difference behaving correctly,
arguably an improvement — `BIND(?o+1 AS ?z) . ?s ?p ?z` now matches for
inlined values. **Both re-pinned, with that reasoning in `config.odin`.**
It does not go back to `SPARQL-T-0031`.

### The counter was blind to §12, so it grew a sixth verb

Running the instrumented build first produced a result that looked like
good news and was not: `graph` reported **1 match / 4123 next in both
configurations** — bit-identical to odin-rdf-store's, which is where the
store's whole §12 finding lived. On record that flatness means nothing of
the kind, and reading it as "no regression" would have been this task's
worst available outcome.

`record.scan_next` filters the residual pattern **inside its own loop**;
a skipped candidate never reaches the engine and ticks nothing. And
`RECORD-A-0004` keeps G out of every prefix, so `snapshot_match` for
`GRAPH <g> { ?s ?p ?o }` (s, p, o all unbound) narrows to *nothing* and
hands back a window over the entire permutation. **The five verbs the
port was designed to preserve cannot, by construction, see the one thing
the port was expected to cost.** That is not a flaw in how they were
written — it is what changes when the store underneath stops answering
from a prefix.

So `candidates` was added: `record.range_len` — exact, O(1), no scan —
summed over every window opened. What the store was *handed*, where
`next` is what it gave back; the gap between them is the residual
filtering. Three lines in `match_open` behind the existing `when`
(the `Range` is named instead of passed through inline), a column, and a
pinned field. The plain build is untouched, and the timings below were
taken from a binary built before the verb existed as well as after.

### §12, both halves, finally comparable

| | odin-rdf-store (T-0040) | odin-rdf-record (here) |
|---|---|---|
| `graph` small | 0.100 ms | 0.078 ms |
| `graph` large | **0.101 ms** | **0.244 ms** |
| `graph` reads, both | 1 match / 4123 next | 1 match / 4123 next |
| `graph` candidates small | — | 20,617 |
| `graph` candidates large | — | **169,055** |

**169,055 candidates for 4,122 answers — a window 41x wider than the
result, and it is the whole store.** 20,617 in `small` is also the whole
store. The named graph is byte-identical in both configurations and the
default graph around it grows tenfold; odin-rdf-store did not look at it
and record looks at all of it. That is `RECORD-A-0004` priced, and it is
the record-side half `SPARQL-T-0039` files.

**The regression is invisible at `small` and the port's own speedup is
why.** 0.078 ms against the store's 0.100 — scanning 20,617 resident
facts still beats seeking 4,122 through LMDB. Only at `large` does the
scan overtake the win, and even there 0.244 ms is not a number anyone
would notice: `sparql10-graph` is 17/17 and the whole harness runs in
1.7 s. **Wall clock alone would have found nothing here at one
configuration and something ambiguous at two.** `candidates` is what
makes the statement exact, machine-independent and true at both sizes,
and it is why adding it was worth the drift it costs.

### Timings — context, not a target

Apple Silicon (darwin 25.2.0, macOS 26.2), Odin `dev-2026-08:8412dc37a`,
`-o:speed -no-bounds-check`, best of 5 in-process after a process-level
and a per-case warm-up, and **best of five separate process runs** on a
machine with nothing else running. `large/graph` was 0.244–0.251 across
all five; the spread everywhere is under 5%. Single configuration —
there is no `Term_ID` width matrix any more (`SPARQL-T-0031`).

| case | store small | record small | store large | record large | large ratio |
|---|---|---|---|---|---|
| bgp2 | 0.547 | 0.263 | 6.138 | 3.167 | 1.9x faster |
| bgp3 | 3.011 | 1.561 | 36.607 | 22.124 | 1.7x faster |
| **graph** | 0.100 | 0.078 | **0.101** | **0.244** | **2.4x slower** |
| optional | 0.606 | 0.341 | 6.738 | 3.967 | 1.7x faster |
| group | 1.648 | 0.476 | 17.683 | 5.221 | 3.4x faster |
| order | 0.952 | 0.535 | 10.940 | 7.167 | 1.5x faster |
| order-limit | 0.939 | 0.509 | 11.159 | 7.017 | 1.6x faster |
| path | 1.220 | 0.761 | 13.330 | 8.757 | 1.5x faster |
| *load* | 42.6 | 20.1 | 449.7 | 160.7 | 2.8x faster |

LMDB against a resident projection is not like-for-like and none of this
is a result. The one line worth reading as one is that **`graph` is the
only case in the table that got slower**, which is exactly the case §12
predicted and no other.

### Three things the run settled, and one it cannot

**The per-fact copy does not show.** `SPARQL-T-0031` decided as a trade
that `match_next` copies a `Fact`'s four ids into the engine's own
`[4]Term_ID`, and named `bgp3` (280,001 `next`) and `path` (98,060) as
where 16 bytes per matched fact would surface first. Both got
substantially faster and neither is an outlier: the speedups do not
correlate with `next` count at all — `group` has 60,001 and is the
largest at 3.4x, `order` has 20,001 and is among the smallest at 1.5x,
because sorting dominates it and sorting did not change. The copy is not
separable from everything else that moved, and **nothing here argues for
revisiting the trade.**

**`store_ops` says nothing in this workload, and the reason is worth
recording.** It is exactly `match + next + load + find + triple` in all
sixteen rows: `triple` is 0 everywhere because the generated corpus has
no triple terms, and `query.odin`'s answer-boundary tick never fires
because `run_once` drains rows without rendering their terms. So
**`SPARQL-T-0019`'s four-round-trips-to-one saving is real and this
benchmark does not measure it** — the evidence for it is the harness
(`sparql12-eval-triple-terms` 38/38) and the arithmetic, not this table.
A case that renders terms over a triple-term corpus would price it; it is
a backlog candidate, not this task's.

**`group` still reads twice per group.** `find` is 26 for two ground
terms, unchanged across the port, still `2 + 2*groups`. T-0040 found it,
declined to chase it, and it is now confirmed as a property of the
engine rather than of odin-rdf-store. Still a backlog candidate.

### What T-0037 and T-0038 inherit

Pinned before-numbers, which is what this task existed to give them.

- **T-0037** (`join_order` consumes `range_len`): `bgp3` opens 100,001
  windows totalling **180,500 candidates** for 80,000 solutions, written
  worst-first on purpose. `range_len` is already called at `match_open`
  in the instrumented build, so the planner's input is a proven, costed
  read — and `candidates` is the number the task is judged by.
- **T-0038** (MIN/MAX in one read, streaming ORDER BY, LIMIT that
  stops): `order-limit` is still `order` — 20,500 candidates, 20,001
  `next`, 7.017 ms against 7.167 — sorting all 20,000 solutions and
  discarding 19,990.
- **T-0039** (the record of the port): the §12 table above is the pair it
  files with odin-rdf-record. Neither half alone was evidence; both
  halves now exist.

### Verification

`make bench` green — both builds, all sixteen pins. `make check` green,
including both bench builds and the instrumented `sparql`. `make test`
green and unmoved: 280 tests, **537/537 W3C entries across 37
directories**, `sparql12-eval-triple-terms` 38/38.

**The pins reproduce against the CI-pinned tags**, repeating T-0040's
check because the local checkouts are again ahead of `ci.yml`
(odin-rdf-parser at `v0.1.1-1`, odin-rdf-record at `v0.4.0-1`). Rebuilt
the instrumented binary against git worktrees at exactly
`odin-rdf-parser@v0.1.0` and `odin-rdf-record@v0.4.0`: **all sixteen
identical**, `candidates` included. The counts are a property of the
engine's control flow, not of a sibling's version.
