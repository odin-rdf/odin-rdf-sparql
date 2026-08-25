package main

// The fixture generator: one deterministic synthetic corpus per
// configuration, emitted as RDF text and loaded through the store's own
// loaders — the same path a consumer's data takes.
//
// **Why synthetic rather than the W3C suites.** The vendored suites
// measure correctness and are far too small to show cost: the largest
// evaluation dataset in `tests/w3c/` is a few dozen triples, which fits
// in L1 and would make every configuration here report the same number.
// That is part of why nothing in this repository has ever been measured.
//
// **The shape is one entity graph, not a random one.** Random edges make
// joins and paths behave unlike anything a consumer has; a modest fan-out
// over a contiguous id space gives selective patterns, a real join
// ordering problem, and a property path with a frontier that grows and
// then saturates. Everything is derived from the seed, so two runs of the
// same configuration produce byte-identical documents — asserted in
// `main.odin` before anything is measured, because a generator that
// wandered would make every number here look like an engine change.

import "core:fmt"
import "core:strings"

// The vocabulary. One namespace, short local names — the corpus is large
// and every byte of it is parsed on load.
NS :: "http://bench/"

// The fan-out ceiling, so an entity's distinct-target set is a fixed
// array rather than an allocation per entity. Raising it is free; a
// configuration above it is a compile-time-visible mistake rather than a
// silently truncated corpus, which is why generate asserts on it.
MAX_FAN_OUT :: 16

// splitmix64: a deterministic, seedable, dependency-free generator.
// `core:math/rand` would do, but it is a moving target across Odin
// releases and this package's whole value is that its numbers are
// reproducible.
Rng :: struct {
	state: u64,
}

rng_init :: proc(seed: u64) -> Rng {
	return Rng{state = seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// rng_below returns a value in [0, n). Modulo bias is irrelevant here —
// the corpus needs to be reproducible, not uniform.
rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

// Corpus is one generated fixture: the two documents, and the counts a
// report line needs to be readable.
Corpus :: struct {
	default_ttl:     string,
	named_trig:      string,
	default_triples: int,
	named_triples:   int,
}

corpus_destroy :: proc(c: ^Corpus) {
	delete(c.default_ttl)
	delete(c.named_trig)
	c^ = {}
}

// generate builds a configuration's corpus. Every entity carries:
//
//   - `a bench:Entity` — the type pattern, the least selective triple in
//     the corpus and the one a join order has to put last;
//   - `bench:name` — a literal, for FILTER and ORDER BY;
//   - `bench:rank` — a small integer, for aggregation and for an
//     ORDER BY whose key is not the subject;
//   - `bench:dept` — one of `depts` IRIs, the GROUP BY key;
//   - `fan_out` × `bench:knows` — the edges joins and the property path
//     walk;
//   - `bench:nickname` on `optional_pct` of entities — the OPTIONAL's
//     right side, present for some and absent for the rest, which is the
//     only shape that exercises the operator rather than a join.
generate :: proc(c: Config) -> Corpus {
	assert(c.fan_out <= MAX_FAN_OUT, "fan_out exceeds MAX_FAN_OUT")
	corpus: Corpus
	corpus.default_ttl, corpus.default_triples = emit_graph(c, c.entities, c.seed, "e", nil)
	if c.named_entities > 0 {
		corpus.named_trig, corpus.named_triples = emit_graph(
			c,
			c.named_entities,
			c.seed ~ 0xA5A5_A5A5,
			"n",
			NS + "g1",
		)
	}
	return corpus
}

// emit_graph writes one graph's worth of entities. `graph` nil emits
// Turtle for the default graph; a label emits TriG wrapping the whole
// document in one GRAPH block.
@(private = "file")
emit_graph :: proc(
	c: Config,
	entities: int,
	seed: u64,
	prefix: string,
	graph: Maybe(string),
) -> (
	doc: string,
	triples: int,
) {
	b := strings.builder_make()
	r := rng_init(seed)

	fmt.sbprintfln(&b, "@prefix b: <%s> .", NS)
	label, named := graph.?
	if named {
		// `{` is a verb to Odin's fmt, so the brace is written by
		// sbprintln rather than escaped inside a format string — the
		// mangling is silent and produces `%!(MISSING CLOSE BRACE)` in
		// the document rather than an error at the call.
		fmt.sbprintf(&b, "GRAPH <%s> ", label)
		fmt.sbprintln(&b, "{")
	}

	for i in 0 ..< entities {
		fmt.sbprintfln(&b, "b:%s%d a b:Entity ;", prefix, i)
		fmt.sbprintfln(&b, "  b:name %q ;", entity_name(prefix, i))
		fmt.sbprintfln(&b, "  b:rank %d ;", rng_below(&r, 100))
		fmt.sbprintfln(&b, "  b:dept b:d%d ;", rng_below(&r, max(1, c.depts)))
		triples += 4

		// Distinct targets. A repeated `knows` edge is one triple in the
		// store and two in the document, and the store silently taking
		// fewer than the generator emitted is exactly the kind of
		// discrepancy that turns into an unexplained pin movement later.
		// Rejection-sampled with a bounded retry rather than shuffled:
		// fan_out is small and entities is not.
		targets: [MAX_FAN_OUT]int
		n_targets := 0
		for attempt := 0; n_targets < c.fan_out && attempt < c.fan_out * 8; attempt += 1 {
			candidate := rng_below(&r, entities)
			seen := false
			for k in 0 ..< n_targets {
				if targets[k] == candidate {
					seen = true
					break
				}
			}
			if seen {
				continue
			}
			targets[n_targets] = candidate
			n_targets += 1
		}
		for k in 0 ..< n_targets {
			fmt.sbprintfln(&b, "  b:knows b:%s%d ;", prefix, targets[k])
			triples += 1
		}

		if rng_below(&r, 100) < c.optional_pct {
			fmt.sbprintfln(&b, "  b:nickname %q ;", entity_nick(prefix, i))
			triples += 1
		}

		// The trailing `;` above is legal Turtle before a `.`, which
		// keeps every branch here a single unconditional line.
		fmt.sbprintln(&b, "  .")

		// entity_name and entity_nick return temporary strings, and the
		// large configuration emits twenty thousand of each. Released
		// per entity, since the builder has already copied them.
		free_all(context.temp_allocator)
	}

	if named {
		fmt.sbprintln(&b, "}")
	}
	return strings.to_string(b), triples
}

// The name is deliberately not a zero-padded id: ORDER BY ?name must
// produce an order that differs from the subject order, or the sort is
// measuring an already-sorted input.
@(private = "file")
entity_name :: proc(prefix: string, i: int) -> string {
	return fmt.tprintf("%s-%03d-%s", NAME_SYLLABLES[i % len(NAME_SYLLABLES)], i % 997, prefix)
}

@(private = "file")
entity_nick :: proc(prefix: string, i: int) -> string {
	return fmt.tprintf("nick-%s-%d", prefix, i)
}

@(private = "file")
NAME_SYLLABLES := [?]string {
	"zeta",
	"alpha",
	"omicron",
	"beta",
	"upsilon",
	"gamma",
	"tau",
	"delta",
	"sigma",
	"epsilon",
	"rho",
	"phi",
	"chi",
}
