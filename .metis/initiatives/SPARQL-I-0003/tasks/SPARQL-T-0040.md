---
id: bench-against-the-engine-as-it
level: task
title: "bench/ against the engine as it stands: the baseline the port is judged against"
short_code: "SPARQL-T-0040"
created_at: 2026-08-24T21:28:14.026521+00:00
updated_at: 2026-08-25T09:54:53.445242+00:00
parent: SPARQL-I-0003
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"


exit_criteria_met: false
initiative_id: SPARQL-I-0003
---

# bench/ against the engine as it stands: the baseline the port is judged against

## Parent Initiative

[[SPARQL-I-0003]]

## Objective

Measure this engine **before** it is ported, so the port has something to
be judged against. This task runs first, against odin-rdf-store, and
changes no engine source.

**Why it exists at all, and why here rather than after the port.**
odin-rdf-shacl's single most valuable port finding was that its **read
counts survived to the integer** — 7503 and seven other pins, identical
over memstore, kvstore and record. `SHACL-T-0036`'s Status records that
its own acceptance criterion had predicted the opposite and asked for the
two to be "stated to be incomparable"; the author had written that into
the prose before the first run and took it out after. That check proved
the engine asked the new store exactly the questions it asked LMDB — that
the port moved cost and not behaviour — and it was **only possible
because `SHACL-I-0003` built bench before the port**.

This repository has no bench at all. Without this task the same check is
structurally impossible here: there would be nothing to compare against,
and "the port changed only cost" would be an assertion. Two further
reasons it belongs before SPARQL-T-0031 rather than after: read counting
is easy today, wrapped around the parapoly seam's adapters, and
materially harder once that seam collapses into direct calls; and
SPARQL-T-0037 and -T-0038 deliberately change *what the engine decides*,
which is the one kind of change a green suite cannot detect.

## Acceptance Criteria

- [x] **A `bench/` package** building and running under the existing
      `make bench` / `make build-bench` targets, which are already
      written and guard on the directory existing. Release flags
      (`-o:speed -no-bounds-check`), as those targets already specify.
      Both targets became **two builds** — see the read-counting
      criterion — and two latent bugs in them were fixed on the way; see
      the Status.
- [x] **A generated fixture corpus**, larger than the W3C suites — they
      measure correctness and are far too small to show cost, which is
      part of why nothing here has ever been measured. Scaled to the
      vision's deployment shape (~200 processes per machine, each
      embedding a store), not to a server. 16,495 and 164,933 triples in
      the default graph, 4,122 in the named one.
- [x] **A query mix covering the operator classes the port touches**:
      two- and three-pattern BGP joins, `GRAPH`, `OPTIONAL`, aggregation
      with `GROUP BY`, `ORDER BY` with and without `LIMIT`, and a
      property path. Each named, each reported as a line. Eight cases in
      `bench/queries.odin`, each carrying the reason it is shaped the way
      it is.
- [x] **The `GRAPH` case measured at more than one ratio** of
      default-graph size to named-graph size. This is the baseline half
      of the initiative's §12 regression: odin-rdf-store answers a bound
      graph as a prefix range because every index is graph-first, and
      record cannot (`RECORD-A-0004`). Without a number from *this* side,
      the record-side evidence is arithmetic rather than measurement.
      **Shaped as a controlled experiment rather than as two ratios**:
      the named graph is held at 4,122 triples while the default graph
      grows tenfold, so "does naming a graph cost anything for the data
      you did not name?" is answered by one comparison. It does not —
      0.100 ms against 0.101 ms. See the Status.
- [x] **Read counting behind a build-time switch**, wrapped around the
      seam adapters in `sparql/kvstore/eval.odin` — `match_adapter`,
      `next_adapter`, `load_adapter`, `find_adapter`, `triple_adapter`.
      Follow odin-rdf-shacl's `SHACL_COUNT_READS` precedent: `make bench`
      becomes two builds, one timed and one instrumented, because
      counting inside the timed build measures the counter.
      `-define:SPARQL_COUNT_READS`, `sparql/kvstore/counting.odin`.
- [x] **The counts are pinned per case**, as assertions rather than as
      log lines. A pin is what makes SPARQL-T-0036's comparison a test
      instead of a reading; shacl's eight pins are the model. Sixteen
      pins, `bench/config.odin`, and a missing one fails rather than
      reporting — stricter than shacl's `UNPINNED`, and free here since
      every case was measured before it was committed.
- [x] **Baselines recorded in this task's Status**, stating the machine,
      the odin-rdf-store version, the `Term_ID` width and the fixture
      size. Run at both widths, since that matrix still exists at this
      point in the initiative. **And re-run against the CI-pinned tags**,
      which the Status explains was not the same thing.
- [x] **`bench/` is in `SRC_DIRS`** so `make check` vets it — both of its
      builds, and the instantiation's instrumented build too.
- [x] **No engine source changes** — with a distinction that has to be
      stated rather than glossed, because this criterion and the
      Technical Approach below it do not say the same thing. **The core
      package `sparql/` is untouched**, which is what "no core change"
      asks for and what the seam exists to make possible. The
      *instantiation* took 36 lines, every one inside
      `when SPARQL_COUNT_READS`, plus one new file. It could not have
      been zero: the five adapters are `@(private)` to
      `sparql/kvstore`, so a benchmark outside the package cannot wrap
      them without re-implementing the instantiation. Recorded as the
      finding this criterion asked for.

## Implementation Notes

### Technical Approach

**The five adapters are the whole instrumentation surface**, and they are
the reason this is cheap today: every read the engine performs against
the backend goes through one of them. A counter struct on `Session`,
incremented in each adapter under `when` on the build flag, costs nothing
in the timed build and needs no core change.

**Design the workload deliberately, and read the numbers rather than
reporting them.** `SHACL-I-0003`'s Status is worth reading before
starting: its design phase named "the workload is the risk, not the
harness" in advance, and was right twice — at 100 focus nodes its figures
were confidently wrong (a `dense` configuration timing faster than
`clean` on an identical walk), and per-configuration warm-up alone let
the answer depend on the order of the configuration list. Both were
caught because the failure mode had been named first.

**What survives the port and what does not.** The query mix, the fixture
generator's *shape*, the reporting and the pinned counts survive into
SPARQL-T-0036; the store setup (`open_ephemeral` + `load_*`) is rewritten
there against `Mem_FS` + `ingest` + `apply`. That two-step is exactly
what shacl paid, and it judged the cost worth it.

### Dependencies

None — it measures the engine as it stands. Runs first, in parallel with
SPARQL-T-0030 if convenient. **SPARQL-T-0031 is blocked on it**, because
once the seam collapses the easy instrumentation point is gone and the
"before" numbers can no longer be taken.

### Risk Considerations

**A bench that measures the wrong thing is worse than none**, because it
launders a guess into a number. The specific traps: a corpus small enough
to fit in cache makes the `GRAPH` prefix advantage invisible, and one
enormous named graph exaggerates it. Vary the ratio and report the shape.

**Do not tune anything.** This task establishes a baseline; it is not a
performance-optimization task, and a finding here becomes a backlog item
rather than a fix. Changing the engine now would destroy the very
comparison the task exists to enable.

**The timing half will not be comparable across the port** — LMDB
against a resident projection — and should be reported as context, not as
a target. **The read counts are the comparable half**, and shacl's
experience says to expect them to hold exactly. If they do not, that is
the most interesting result this initiative can produce, and it means the
engine's control flow changed when it was supposed only to change store.

## Status Updates

### 2026-08-25 — the baseline exists, and the §12 experiment already has its answer

`bench/` is five files (`main`, `config`, `queries`, `generate`,
`store`), `make bench` is two builds, `make check` vets three of them,
and `make test` is still green at both widths — **512/512 across 37
directories**, unchanged, because every line of instrumentation is
behind a `when` that the plain build compiles to nothing.

**Machine and versions.** Apple Silicon dev machine (darwin 25.5.0),
Odin `dev-2026-08:8412dc37a`, `-o:speed -no-bounds-check`, best of 5
after a process-level warm-up and a per-case one. Read counts are
**identical at both `Term_ID` widths** — every number in both tables —
so only one set is given.

### The §12 case, answered

| | small | large |
|---|---|---|
| default graph | 16,495 triples | 164,933 triples |
| named graph `b:g1` | 4,122 triples | **4,122 triples** |
| `graph` — `GRAPH b:g1 { ?s ?p ?o }` | **0.100 ms** | **0.101 ms** |
| `graph` reads | 1 match, 4,123 next | **1 match, 4,123 next** |
| `bgp2`, for scale | 0.547 ms | 6.138 ms |

**Naming a graph costs nothing for the data you did not name.** The
default graph grows tenfold and the bound-graph query does not move — not
in time, not in a single read. `bgp2` over the same two stores moves by
11×, which is what says the corpus is big enough for the flatness to
mean something rather than being two numbers under the noise floor. That
is odin-rdf-store answering from a prefix range because every one of its
indexes is graph-first, and it is the baseline half of the regression
`RECORD-A-0004` implies. The other half is `SPARQL-T-0036`'s to measure;
this task deliberately does not predict it.

The experiment is shaped as *hold the named graph, grow the rest* rather
than as "more than one ratio", which is what the criterion literally
asked for. Two ratios would have varied both sides at once and made the
comparison unreadable.

### Timings, 64-bit (context, not a target)

| case | small | large | |
|---|---|---|---|
| bgp2 | 0.547 | 6.138 | |
| bgp3 | 3.011 | 36.607 | selective pattern written last |
| graph | 0.100 | 0.101 | |
| optional | 0.606 | 6.738 | |
| group | 1.648 | 17.683 | |
| order | 0.952 | 10.940 | |
| order-limit | 0.939 | 11.159 | **the same as `order`** |
| path | 1.220 | 13.330 | |
| *load* | 42.6 | 449.7 | |

At 32 bits every case is faster and the shape is identical (bgp3 2.451 /
28.783, graph 0.086 / 0.096, path 1.006 / 10.570). Smaller keys, fewer
pages; not this task's question, and not pursued.

**`order-limit` is `order`.** Identical read counts and times within
noise: `ORDER BY ?name LIMIT 10` materializes and sorts all 20,000
solutions and then discards 19,990 of them. That is `SPARQL-T-0038`'s
before-number and it is about as clean as a before-number gets.

**`bgp3` is `SPARQL-T-0037`'s.** Written worst-first on purpose
(`?s a b:Entity` matches everything and is first), it opens 100,001
match iterators for 80,000 solutions.

### Three findings from building it

**1. `group` reads the store twice per group, and it is not the ground
terms.** `find` is 26 for a query with two ground terms. Probed rather
than guessed — dropping `depts` from 12 to 4 moved it from 26 to 10, so
it is exactly `2 + 2×groups`. Something in the aggregation path resolves
two terms per group through `find_adapter`. **Not investigated further
and not touched**: this task establishes a baseline and tuning it would
destroy the comparison it exists to enable. It is a candidate backlog
item, and it is now pinned, so it cannot move unnoticed.

**2. The generator had to be taught not to repeat itself.** The first
run refused to start: the store took 16,501 triples where the generator
had emitted 16,509. A repeated `b:knows` edge is two statements in a
document and one triple in a store. Fixed by rejection-sampling distinct
targets — but the reason it was caught at all is an equality check in
`store_load` comparing emitted against stored, which is worth keeping:
without it this surfaces months later as an unexplained pin movement.

**3. Two silent traps in Odin's `fmt`, both of which produced wrong
output rather than an error.** `{` is a verb, so
`sbprintfln("GRAPH <%s> {", label)` wrote
`GRAPH <http://bench/g1> %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)`
into the generated TriG — surfacing four thousand lines later as
"unexpected character", which is a long way from the cause. And `%10d`
zero-pads integers (`0000001950`) while `%-10d` pads on the *right* with
zeros; the fix is to render the number and pad the string. Both are
noted at their call sites.

### The pins reproduce against the CI-pinned tags, which was not free

The local sibling checkouts are **ahead of what `ci.yml` pins**:
odin-rdf-store at `v0.6.0-6-gc6cb0ba` (including `STORE-T-0057`'s
`lookup_term_borrow_txn`) and odin-rdf-parser at `v0.1.1-1`. Baselines
taken against those are not baselines against what CI builds, so the
instrumented run was repeated against git worktrees at exactly
`odin-rdf-parser@v0.1.0` and `odin-rdf-store@v0.6.0`: **every one of the
sixteen pins is identical.** The counts are a property of the engine's
control flow rather than of the store's version — expected, and now
measured rather than assumed.

### What SPARQL-T-0036 inherits

`queries.odin`, `generate.odin`, `config.odin` and the reporting survive
the port unchanged. **`store.odin` is the file that gets rewritten** —
`open_ephemeral` + `load_turtle` + `load_trig` become `Mem_FS` +
`store_open` + `ingest` + `apply` — and it is one file for exactly that
reason. The counting moves too: `sparql/kvstore/counting.odin` goes with
`sparql/kvstore` at `SPARQL-T-0031`, and its replacement lands in
`sparql/` itself at the direct call sites, which is the shape
odin-rdf-shacl ended up with for the same reason.

One thing for that task to keep: `store_ops` is reported and **not
pinned**, deliberately. It is the number the port is expected to
*change* — four round trips per triple term here against one
`snapshot_triple_parts` — so pinning it would encode odin-rdf-store's
cost as a requirement.