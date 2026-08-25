package sparql_kvstore

// Read counting for the benchmark (SPARQL-T-0040) — and nothing else.
//
// `bench/` reports how many times evaluating a query asks the store a
// question. The tally lives here rather than in `bench/` because the
// adapters it counts are `@(private)` to this package: they are the seam
// the core reads through, and a benchmark outside the package cannot
// wrap them without re-implementing the instantiation.
//
//	-define:SPARQL_COUNT_READS=true
//
// **Off, it does not exist.** `when SPARQL_COUNT_READS` is a
// compile-time branch, so a normal build carries no counter, no branch
// and no global — not a disabled one, none. `make test` and every
// consumer build it off, and `make bench` builds twice so that no timing
// is ever taken from a binary that is counting.
//
// **On, it is a process-wide tally**, not a per-Query one: the benchmark
// runs queries serially, resets before a measured run and reads after,
// and that is the only caller this is for. It is not an API.
//
// # Why the two halves of the tally are different questions
//
// `match`/`next`/`load`/`find`/`triple` count **how often the engine
// asks** — one tick per adapter entry. That is the number
// `SPARQL-T-0036` compares across the port, and the one expected to hold
// to the integer: the adapters are one-for-one with the direct calls
// that replace them, so a changed count means the engine's control flow
// moved when only its store was supposed to.
//
// `store_ops` counts **what the store was actually made to do** — one
// tick per round trip into kvstore, wherever it happens, including the
// ones inside `triple_adapter` and at the answer boundary that no
// adapter tick covers. It is *not* expected to hold: taking a triple
// term apart is four round trips here (one `lookup_term_txn`, three
// `find_term_txn`) against one `snapshot_triple_parts` after the port,
// which is the `SPARQL-T-0019` evidence stated as a measurement rather
// than as arithmetic. Netting the two into one number would hide exactly
// the difference the port is trying to make.
SPARQL_COUNT_READS :: #config(SPARQL_COUNT_READS, false)

// Read_Counts is the tally, kept per verb because a change that trades
// one kind of read for another is worth seeing rather than netting out
// to zero.
Read_Counts :: struct {
	// One tick per adapter entry — the questions the engine asks.
	match:     int, // a match iterator opened for one pattern at one depth
	next:      int, // one step of one iterator
	load:      int, // a result id materialized during expression evaluation
	find:      int, // a ground term of the query bound to an id
	triple:    int, // a stored triple term taken apart
	// Every round trip into kvstore, wherever it is made.
	store_ops: int,
}

when SPARQL_COUNT_READS {
	@(private)
	read_counts: Read_Counts

	// read_counts_reset zeroes the tally. Call it immediately before the
	// run to be counted — preparing a query binds its ground terms
	// through the same adapters, so a reset after `query_init` and a
	// reset before it are answering different questions.
	read_counts_reset :: proc() {
		read_counts = {}
	}

	// read_counts_get is the tally since the last reset.
	read_counts_get :: proc() -> Read_Counts {
		return read_counts
	}
}
