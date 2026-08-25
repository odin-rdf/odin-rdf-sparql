package main

// The standing configurations, and their pinned read counts.
//
// **A pin, not a threshold.** The expected read count for each (config,
// case) pair is a constant here, asserted on every instrumented run, and
// it moves only by a deliberate edit with a diff behind it. That is this
// family's most characteristic mechanism — `TOTAL_ENTRIES`,
// `ENABLED_ENTRIES`, odin-rdf-shacl's eight bench pins — applied to the
// one metric in this package that can carry it. A timing threshold would
// either flap or be set so loose it caught nothing; an exact integer does
// neither.
//
// **Re-pinning is not an admission of a bug.** A change that reads more
// may be entirely right. The pin does not say the number must never move;
// it says the number must never move *unnoticed*. If you change one, say
// in the commit message what made the engine ask the store more or fewer
// questions.
//
// **These pins are what SPARQL-T-0036 compares against**, and the
// comparison is the point of building this before the port rather than
// after (SPARQL-I-0003 §10). odin-rdf-shacl's read counts survived its
// port to the integer; if these do not, the engine's control flow moved
// when only its store was supposed to, and that is the most interesting
// result this initiative can produce.

// There is no "unpinned" value: a (config, case) pair with no row in
// PINS fails the run outright (`check_pin`), which is stricter than
// odin-rdf-shacl's `UNPINNED` sentinel and costs nothing here, since
// every case was measured before it was committed. A pin that cannot
// fail is decoration.
Config :: struct {
	name:           string,
	seed:           u64,
	// Default-graph entities. Roughly `4 + fan_out + optional_pct/100`
	// triples each — the report prints the exact count.
	entities:       int,
	fan_out:        int,
	depts:          int,
	optional_pct:   int,
	// Named-graph entities, in `b:g1`. **Held constant across the
	// configurations while `entities` varies** — see the `graph` case.
	named_entities: int,
}

// Sizes are deliberately modest: the deployment this family is designed
// around is ~200 processes per machine each embedding a store, not one
// server with a warehouse in it. They are not *too* modest either, and
// the floor was found by measurement — see this task's Status for the
// run that set it. A corpus small enough to sit in cache would make the
// graph-first advantage invisible, which is the one thing these
// configurations exist to expose.
CONFIGS := []Config {
	// The reference configuration, and the one to quote.
	{
		name = "small",
		seed = 0x5EED_2040,
		entities = 2_000,
		fan_out = 4,
		depts = 12,
		optional_pct = 25,
		named_entities = 500,
	},

	// Ten times the default graph, **the same named graph**. The pair is
	// the whole §12 experiment: if `graph` costs the same in both, the
	// store answered it from a prefix and never looked at the rest; if it
	// grows with the total, it scanned. odin-rdf-store should be flat
	// here, and odin-rdf-record should not be — but neither half is
	// asserted, because the point is to measure it rather than to encode
	// the expectation.
	{
		name = "large",
		seed = 0x5EED_2040,
		entities = 20_000,
		fan_out = 4,
		depts = 12,
		optional_pct = 25,
		named_entities = 500,
	},
}

// A pin is per (configuration, case). The zero value is UNPINNED for
// every field, so a case added without a measurement reports instead of
// silently passing.
Pin :: struct {
	config:    string,
	case_name: string,
	solutions: int,
	// The comparable half: one tick per adapter entry.
	match:     int,
	next:      int,
	load:      int,
	find:      int,
	triple:    int,
	// Not pinned, and deliberately: `store_ops` is what the port is
	// expected to *change* (SPARQL-T-0019's triple-term round trips), so
	// asserting it here would encode odin-rdf-store's cost as a
	// requirement. It is reported and compared by hand.
}

// PINS is filled from a measured run (2026-08-25, odin-rdf-store v0.6.0,
// identical at both Term_ID widths). An entry missing for a (config,
// case) pair fails the run, which is what keeps this table honest as
// cases are added.
//
// **The `graph` row is the one to read first.** Its counts are identical
// in `small` and `large` — 1 match, 4123 next — while the default graph
// around it grows tenfold. That is odin-rdf-store answering a bound
// graph from a prefix range and never looking at the rest, and it is the
// baseline half of SPARQL-I-0003 §12.
PINS := []Pin {
	{config = "small", case_name = "bgp2", solutions = 2000, match = 2001, next = 6001, load = 0, find = 3, triple = 0},
	{config = "small", case_name = "bgp3", solutions = 8000, match = 10001, next = 28001, load = 0, find = 4, triple = 0},
	{config = "small", case_name = "graph", solutions = 4122, match = 1, next = 4123, load = 0, find = 1, triple = 0},
	{config = "small", case_name = "optional", solutions = 2000, match = 2001, next = 4496, load = 0, find = 3, triple = 0},
	{config = "small", case_name = "group", solutions = 12, match = 2001, next = 6001, load = 4000, find = 26, triple = 0},
	{config = "small", case_name = "order", solutions = 2000, match = 1, next = 2001, load = 2000, find = 1, triple = 0},
	{config = "small", case_name = "order-limit", solutions = 10, match = 1, next = 2001, load = 2000, find = 1, triple = 0},
	{config = "small", case_name = "path", solutions = 1950, match = 1950, next = 9750, load = 0, find = 2, triple = 0},

	{config = "large", case_name = "bgp2", solutions = 20000, match = 20001, next = 60001, load = 0, find = 3, triple = 0},
	{config = "large", case_name = "bgp3", solutions = 80000, match = 100001, next = 280001, load = 0, find = 4, triple = 0},
	{config = "large", case_name = "graph", solutions = 4122, match = 1, next = 4123, load = 0, find = 1, triple = 0},
	{config = "large", case_name = "optional", solutions = 20000, match = 20001, next = 44934, load = 0, find = 3, triple = 0},
	{config = "large", case_name = "group", solutions = 12, match = 20001, next = 60001, load = 40000, find = 26, triple = 0},
	{config = "large", case_name = "order", solutions = 20000, match = 1, next = 20001, load = 20000, find = 1, triple = 0},
	{config = "large", case_name = "order-limit", solutions = 10, match = 1, next = 20001, load = 20000, find = 1, triple = 0},
	{config = "large", case_name = "path", solutions = 19612, match = 19612, next = 98060, load = 0, find = 2, triple = 0},
}

pin_for :: proc(config, case_name: string) -> (Pin, bool) {
	for p in PINS {
		if p.config == config && p.case_name == case_name {
			return p, true
		}
	}
	return {}, false
}
