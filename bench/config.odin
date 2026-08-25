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
// ~~**These pins are what SPARQL-T-0036 compares against**, and the
// comparison is the point of building this before the port rather than
// after (SPARQL-I-0003 §10). odin-rdf-shacl's read counts survived its
// port to the integer; if these do not, the engine's control flow moved
// when only its store was supposed to, and that is the most interesting
// result this initiative can produce.~~
//
// **Answered 2026-08-25 (SPARQL-T-0036): they survived, fourteen of
// sixteen to the integer.** The two that moved are both `group`/`load`
// and both by the number of groups, from a term-identity difference
// that is arguably an improvement — see the note above `PINS`, which is
// now a record-store table. The paragraph above stands as what was
// asked.

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
	//
	// **Both halves are now measured** (T-0040, then T-0036). The store
	// was flat: 0.100 and 0.101 ms, 1 match / 4123 next. The record
	// scans: 0.092 and 0.244 ms for the identical query and answer, and
	// `candidates` 20,617 against 169,055 — the whole store, both times.
	// The expectation is still not asserted anywhere; `candidates` is,
	// which is the same claim stated as an integer instead of a guess.
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
	config:     string,
	case_name:  string,
	solutions:  int,
	// The comparable half: one tick per adapter entry.
	match:      int,
	next:       int,
	load:       int,
	find:       int,
	triple:     int,
	// **Pinned, and it has no odin-rdf-store counterpart** (SPARQL-T-0036).
	// `candidates` is `range_len` summed over every window the engine
	// opened — what record was handed, where `next` is what it gave back.
	// It exists because the five verbs above cannot see a residual scan:
	// `scan_next` filters inside its own loop, so the window can grow
	// tenfold without moving a single one of them. There is nothing to
	// compare it against across the port, and it is pinned anyway,
	// because it is the number `SPARQL-T-0037` exists to reduce and an
	// unpinned before-number is the thing this whole file argues against.
	candidates: int,
	// Not pinned, and deliberately: `store_ops` is what the port is
	// expected to *change* (SPARQL-T-0019's triple-term round trips), so
	// asserting it here would encode odin-rdf-store's cost as a
	// requirement. It is reported and compared by hand.
}

// PINS is filled from a measured run (2026-08-25, odin-rdf-record
// v0.4.0, one configuration -- SPARQL-T-0036). An entry missing for a
// (config, case) pair fails the run, which is what keeps this table
// honest as cases are added.
//
// **Fourteen of the sixteen rows were not touched when the store under
// them changed.** They were measured against odin-rdf-store v0.6.0 at
// SPARQL-T-0040, before the port, and they are reproduced to the
// integer against odin-rdf-record -- every `match`, every `next`, every
// `find`, and all sixteen solution counts. The engine asks record
// exactly the questions it asked LMDB. That is SPARQL-I-0003's central
// claim, and this table is the evidence for it.
//
// **The two that moved are both `group`, both `load`, both by exactly
// the number of groups** (4000 -> 4012, 40000 -> 40012, with `store_ops`
// following). It is a term-identity difference and not a control-flow
// regression. `bindable_id` (`sparql/exec.odin`) resolves an aggregate's
// result against the store, so that a computed term the data already
// holds gets the store's own id and a later pattern can match on it.
// `COUNT(?s)` produces a small canonical integer; odin-rdf-store had
// never interned one, and record **inlines** it -- a canonical
// `xsd:integer` in RECORD-A-0001's range *is* its own id and resolves
// without ever having been stored. So the id is real rather than
// synthetic, and reading it back in the projection is a `load` where it
// used to be a lookup in the engine's own computed table. `AVG(?r)` is a
// decimal, is not inlineable, and did not move; `find` is 26 in both.
// Arguably an improvement, since `BIND(?o+1 AS ?z) . ?s ?p ?z` now
// matches for inlined values.
//
// **`bgp3-selective-last` is SPARQL-T-0037's row, and it is the only one
// in this table whose numbers a *plan* decides.** Written worst-first,
// it was 4001 match / 8181 next / 4680 candidates in `small` and 40001 /
// 81611 / 42110 in `large` under the identity ordering these pins were
// first taken with. Cost- and connectivity-ordered joins take it to 361
// / 901 / 589 and 3221 / 8051 / 4879 — **12x fewer scans opened for the
// same 1,610 solutions**, and 4.896 ms to 0.495 ms. Nothing else in the
// table moved a single pinned count, which is the finding as much as the
// case is: every other query here was already written in the order a
// planner would choose. See SPARQL-T-0037's Status.
//
// **The `graph` row is still the one to read first, and it now says the
// opposite of what it said.** Its `match` and `next` are unchanged and
// still identical in `small` and `large` -- 1 and 4123 -- and on
// odin-rdf-store that flatness *was* the finding: a bound graph answered
// from a prefix range, never looking at the rest. Here the same two
// numbers mean nothing of the kind. `candidates` is 20,617 in `small`
// and **169,055 in `large`**: the entire store, both times, because
// RECORD-A-0004 keeps G out of every prefix and `scan_next` filters it
// residually inside its own loop, where no verb the engine ticks can see
// it. Same 4,122 answers, a window 41x wider than they are. That is the
// record-side half of SPARQL-I-0003 par. 12, and it is the reason
// `candidates` was added.
PINS := []Pin {
	{config = "small", case_name = "bgp2", solutions = 2000, match = 2001, next = 6001, load = 0, find = 3, triple = 0, candidates = 4500},
	{config = "small", case_name = "bgp3", solutions = 8000, match = 10001, next = 28001, load = 0, find = 4, triple = 0, candidates = 18500},
	{config = "small", case_name = "graph", solutions = 4122, match = 1, next = 4123, load = 0, find = 1, triple = 0, candidates = 20617},
	{config = "small", case_name = "optional", solutions = 2000, match = 2001, next = 4496, load = 0, find = 3, triple = 0, candidates = 2995},
	{config = "small", case_name = "group", solutions = 12, match = 2001, next = 6001, load = 4012, find = 26, triple = 0, candidates = 4500},
	{config = "small", case_name = "order", solutions = 2000, match = 1, next = 2001, load = 2000, find = 1, triple = 0, candidates = 2500},
	{config = "small", case_name = "order-limit", solutions = 10, match = 1, next = 2001, load = 2000, find = 1, triple = 0, candidates = 2500},
	{config = "small", case_name = "bgp3-selective-last", solutions = 180, match = 361, next = 901, load = 0, find = 5, triple = 0, candidates = 589},
	{config = "small", case_name = "path", solutions = 1950, match = 1950, next = 9750, load = 0, find = 2, triple = 0, candidates = 7800},

	{config = "large", case_name = "bgp2", solutions = 20000, match = 20001, next = 60001, load = 0, find = 3, triple = 0, candidates = 40500},
	{config = "large", case_name = "bgp3", solutions = 80000, match = 100001, next = 280001, load = 0, find = 4, triple = 0, candidates = 180500},
	{config = "large", case_name = "graph", solutions = 4122, match = 1, next = 4123, load = 0, find = 1, triple = 0, candidates = 169055},
	{config = "large", case_name = "optional", solutions = 20000, match = 20001, next = 44934, load = 0, find = 3, triple = 0, candidates = 25433},
	{config = "large", case_name = "group", solutions = 12, match = 20001, next = 60001, load = 40012, find = 26, triple = 0, candidates = 40500},
	{config = "large", case_name = "order", solutions = 20000, match = 1, next = 20001, load = 20000, find = 1, triple = 0, candidates = 20500},
	{config = "large", case_name = "order-limit", solutions = 10, match = 1, next = 20001, load = 20000, find = 1, triple = 0, candidates = 20500},
	{config = "large", case_name = "bgp3-selective-last", solutions = 1610, match = 3221, next = 8051, load = 0, find = 5, triple = 0, candidates = 4879},
	{config = "large", case_name = "path", solutions = 19612, match = 19612, next = 98060, load = 0, find = 2, triple = 0, candidates = 78448},
}

pin_for :: proc(config, case_name: string) -> (Pin, bool) {
	for p in PINS {
		if p.config == config && p.case_name == case_name {
			return p, true
		}
	}
	return {}, false
}
