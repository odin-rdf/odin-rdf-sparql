package main

// Package main is odin-rdf-sparql's benchmark: what evaluating a query
// costs, measured rather than argued (SPARQL-T-0040). Run with:
//
//	make bench
//
// which builds with `-o:speed -no-bounds-check` **twice** and runs each:
// once plain, for timings; once with `-define:SPARQL_COUNT_READS=true`,
// for store reads and the assertions. See "Two modes" below.
//
//
// # Why this exists, and why before the port rather than after
//
// This repository is being ported off odin-rdf-store onto
// odin-rdf-record (SPARQL-I-0003), and had no benchmark at all. Without
// a *before*, the port's central claim — that it moved cost and not
// behaviour — would be an assertion with nothing behind it.
// odin-rdf-shacl's most valuable port finding was that its read counts
// survived to the integer, and that check was available to it only
// because its benchmark predated its port. `SPARQL-T-0036` rebuilds this
// one against the record store and compares; the pins in `config.odin`
// are what it compares against.
//
// A second reason it must run first: read counting is cheap today
// because every read goes through one of five adapters in
// `sparql/kvstore/eval.odin`. `SPARQL-T-0031` collapses that seam into
// direct calls, and the easy instrumentation point goes with it.
//
//
// # Two modes over one workload
//
// Every instrument here perturbs what it measures, so they are two
// builds rather than two code paths:
//
//   - *Timing* — the plain build. The real path through the engine, the
//     real allocator, nothing wrapped. Wall clock only.
//   - *Instrumented* — built with `SPARQL_COUNT_READS`, which compiles a
//     tally into the five adapters (`sparql/kvstore/counting.odin`).
//     Reports store reads and asserts the pins. **No timing is taken
//     here and none should ever be quoted from it.**
//
//
// # What the numbers are, and are not
//
// **The read counts are the half that survives the port.** They say how
// often the engine asks the store a question, which is a property of the
// plan and the executor rather than of the backend.
//
// **The timings are not comparable across the port** — LMDB against a
// memory-resident projection is not like-for-like — and are context
// rather than a target. Within one side they are comparable to
// themselves, which is what makes the `graph` case's two configurations
// mean something.
//
// **Nothing here is a claim about real-world cost.** It is a synthetic
// corpus and a regression instrument.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../sparql"
import "record:record"

// Best of REPS, after a discarded warm-up. Best rather than mean: the
// question is what the engine costs when nothing else is happening, and
// the distribution's tail is the machine, not the code.
REPS :: 5

failures := 0

// num renders an integer for a fixed-width column. `%10d` cannot do it:
// Odin's fmt reads the width as a zero-pad for integers (and `%-10d`
// pads on the *right* with zeros), so `1950` comes out `0000001950`.
// Padding a string is the form that behaves.
num :: proc(v: int) -> string {
	return fmt.tprintf("%d", v)
}

// ms is num's floating-point twin, and needed for the same reason:
// `%12.3f` pads with zeros too, so `5.916` prints as `00000005.916`.
ms :: proc(v: f64) -> string {
	return fmt.tprintf("%.3f", v)
}

fail :: proc(format: string, args: ..any) {
	fmt.eprintf("FAIL: ")
	fmt.eprintfln(format, ..args)
	failures += 1
}

main :: proc() {
	when sparql.SPARQL_COUNT_READS {
		fmt.println(
			"odin-rdf-sparql bench — instrumented: store reads and assertions. No timings.",
		)
	} else {
		fmt.println("odin-rdf-sparql bench — timing: nothing wrapped.")
	}
	fmt.println(
		"Synthetic corpus over odin-rdf-store (kvstore/LMDB); a regression instrument, not a claim about real-world cost.",
	)

	// A process-level warm-up, discarded entirely, before any
	// configuration is timed. Per-case warm-up is not enough on its own:
	// odin-rdf-shacl's benchmark found its figures drifting downward
	// across its configuration list, the first ones paying for a growing
	// allocator arena and cold pages that every later one then found
	// warm. A benchmark whose answer depends on the order of its own
	// list is worse than none.
	when !sparql.SPARQL_COUNT_READS {
		warm_up()
	}

	for c in CONFIGS {
		run_config(c)
	}

	fmt.println()
	if failures > 0 {
		fmt.eprintfln("%d assertion(s) failed", failures)
		os.exit(1)
	}
	fmt.println("all assertions passed")
}

@(private = "file")
warm_up :: proc() {
	if len(CONFIGS) == 0 {
		return
	}
	corpus := generate(CONFIGS[0])
	defer corpus_destroy(&corpus)
	s := store_load(corpus)
	defer store_close(s)
	for _ in 0 ..< 2 {
		for k in CASES {
			_, _ = run_once(s, k)
		}
	}
}

run_config :: proc(c: Config) {
	corpus := generate(c)
	defer corpus_destroy(&corpus)

	// Determinism first. Every assertion below is a statement about a
	// fixed corpus, and a generator that wandered would make all of them
	// look like engine regressions.
	{
		again := generate(c)
		defer corpus_destroy(&again)
		if again.default_ttl != corpus.default_ttl || again.named_trig != corpus.named_trig {
			fail("%s: the generator is not deterministic for seed %d", c.name, c.seed)
			return
		}
	}

	load_start := time.tick_now()
	s := store_load(corpus)
	defer store_close(s)
	load_ms := time.duration_milliseconds(time.tick_since(load_start))

	fmt.printfln("\n== %s ==", c.name)
	fmt.printfln(
		"   %d entities, fan-out %d, %d depts, %d%% optional | default %d triples, named %d triples | load %s ms",
		c.entities,
		c.fan_out,
		c.depts,
		c.optional_pct,
		corpus.default_triples,
		corpus.named_triples,
		ms(load_ms),
	)

	when sparql.SPARQL_COUNT_READS {
		fmt.printfln(
			"   %-12s %10s %9s %9s %9s %7s %7s %11s",
			"case",
			"solutions",
			"match",
			"next",
			"load",
			"find",
			"triple",
			"store_ops",
		)
	} else {
		fmt.printfln("   %-12s %10s %12s   %s", "case", "solutions", "best ms", "about")
	}

	for k in CASES {
		run_case(c, s, k)
		free_all(context.temp_allocator)
	}
}

run_case :: proc(c: Config, s: ^Bench_Store, k: Case) {
	when sparql.SPARQL_COUNT_READS {
		sparql.read_counts_reset()
		solutions, ok := run_once(s, k)
		counts := sparql.read_counts_get()
		if !ok {
			fail("%s/%s: the query did not run", c.name, k.name)
			return
		}
		fmt.printfln(
			"   %-12s %10s %9s %9s %9s %7s %7s %11s",
			k.name,
			num(solutions),
			num(counts.match),
			num(counts.next),
			num(counts.load),
			num(counts.find),
			num(counts.triple),
			num(counts.store_ops),
		)
		check_pin(c, k, solutions, counts)
	} else {
		// A per-case warm-up on top of the process-level one: the first
		// run of a case pays for its own plan, its own cursors and the
		// pages its patterns touch.
		if _, ok := run_once(s, k); !ok {
			fail("%s/%s: the query did not run", c.name, k.name)
			return
		}
		best := max(f64)
		solutions := 0
		for _ in 0 ..< REPS {
			start := time.tick_now()
			n, ok := run_once(s, k)
			ms := time.duration_milliseconds(time.tick_since(start))
			if !ok {
				fail("%s/%s: the query did not run", c.name, k.name)
				return
			}
			solutions = n
			best = min(best, ms)
		}
		fmt.printfln("   %-12s %10s %12s   %s", k.name, num(solutions), ms(best), k.about)
	}
}

// run_once parses, prepares and fully drains one query, returning how
// many solutions it produced. The whole round trip is inside the
// measurement because it is what a consumer pays: a prepared query is
// not something this engine lets you cache across datasets, since it
// holds the snapshot.
run_once :: proc(s: ^Bench_Store, k: Case) -> (solutions: int, ok: bool) {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)k.text)
	defer sparql.parser_destroy(&p) // owns the algebra

	if _, parsed := sparql.parse(&p); !parsed {
		fail(
			"%s: parse error at line %d, column %d: %s",
			k.name,
			p.err.line,
			p.err.column,
			sparql.error_message(p.err.kind),
		)
		return 0, false
	}
	algebra, translated := sparql.translate(&p)
	if !translated {
		fail("%s: the query did not translate", k.name)
		return 0, false
	}

	// One snapshot per query, acquired and released around it, where the
	// kvstore benchmark opened and ended a read transaction. Both say the
	// same thing: a query answers about one dataset.
	snap := store_snapshot(s)
	defer record.snapshot_release(&snap)

	q: sparql.Query
	defer sparql.query_destroy(&q)
	if !sparql.query_init(&q, algebra, snap, sparql.parser_base(&p)) {
		fail("%s: unsupported: %s", k.name, q.unsupported)
		return 0, false
	}

	for {
		_, more := sparql.query_next(&q)
		if !more {
			break
		}
		solutions += 1
	}
	return solutions, true
}

// check_pin asserts the measured counts against `config.odin`'s table,
// and prints a paste-ready line for a pin that is missing or has moved —
// so that re-pinning is a deliberate copy rather than a hand-transcribed
// integer.
check_pin :: proc(c: Config, k: Case, solutions: int, counts: sparql.Read_Counts) {
	// `{` and `}` are verbs to Odin's fmt and must be doubled; an
	// unescaped one is written into the output as
	// `%!(MISSING CLOSE BRACE)` rather than reported at the call.
	suggestion := fmt.tprintf(
		"\t{{config = %q, case_name = %q, solutions = %d, match = %d, next = %d, load = %d, find = %d, triple = %d}},",
		c.name,
		k.name,
		solutions,
		counts.match,
		counts.next,
		counts.load,
		counts.find,
		counts.triple,
	)

	p, found := pin_for(c.name, k.name)
	if !found {
		fail("%s/%s: no pin. Add:\n%s", c.name, k.name, suggestion)
		return
	}

	b := strings.builder_make(context.temp_allocator)
	if p.solutions != solutions {
		fmt.sbprintf(&b, " solutions %d->%d", p.solutions, solutions)
	}
	if p.match != counts.match {
		fmt.sbprintf(&b, " match %d->%d", p.match, counts.match)
	}
	if p.next != counts.next {
		fmt.sbprintf(&b, " next %d->%d", p.next, counts.next)
	}
	if p.load != counts.load {
		fmt.sbprintf(&b, " load %d->%d", p.load, counts.load)
	}
	if p.find != counts.find {
		fmt.sbprintf(&b, " find %d->%d", p.find, counts.find)
	}
	if p.triple != counts.triple {
		fmt.sbprintf(&b, " triple %d->%d", p.triple, counts.triple)
	}
	if moved := strings.to_string(b); moved != "" {
		fail("%s/%s: pin moved:%s\n   replace with:\n%s", c.name, k.name, moved, suggestion)
	}
}
