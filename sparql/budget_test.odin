package sparql

// The per-query budget (SPARQL-T-0053), asserted over the shape that
// filed it.
//
// The reproduction is a three-way join over instances of one class in
// named graphs with a FILTER nothing satisfies. Against a few hundred
// instances it is one `query_next` call that returns `false` after 24
// seconds, having produced nothing — which is why a caller checking a
// deadline between pulls never gets a turn, and why the check has to be
// the executor's. **The fixture here is scaled down to twenty-four
// instances**, so the same shape costs milliseconds: what a test can
// assert is that the budget bites, not that a machine is slow.
//
// Two things every case below has to establish and not merely assume.
// First, that the query the budget cut would otherwise have *finished*
// — a budget that stops a query which was about to stop anyway proves
// nothing, so each cut run is paired with an uncut one over the same
// fixture. Second, that being cut is distinguishable from being
// exhausted: `query_next` answers `false` either way, and
// `query_stopped` is the whole difference.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import rdf "rdf:rdf"

// GRAPH_COUNT × PER_GRAPH instances of ex:Thing, one graph per group.
// Twenty-four instances is 13,824 candidate solutions for the three-way
// join below — comfortably more than one BUDGET_CADENCE of work, and a
// few milliseconds of it.
@(private = "file")
GRAPH_COUNT :: 4
@(private = "file")
PER_GRAPH :: 6

// The item's reproduction: a three-way join whose FILTER nothing
// satisfies. It answers nothing, and it answers nothing slowly.
@(private = "file")
REPRO :: `
PREFIX ex: <http://example/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?a ?b ?c WHERE {
	GRAPH ?g1 { ?a a ex:Thing }
	GRAPH ?g2 { ?b a ex:Thing }
	GRAPH ?g3 { ?c a ex:Thing ; rdfs:label ?l }
	FILTER(?l = "no such label")
}
`

// The same join without the FILTER: it answers 13,824 solutions and
// answers the first one immediately. It is here because a budget that
// only ever cut queries with no answers would be untested on the case a
// consumer actually meets — a truncated answer that must not look
// complete.
@(private = "file")
CROSS :: `
PREFIX ex: <http://example/>
SELECT ?a ?b ?c WHERE {
	GRAPH ?g1 { ?a a ex:Thing }
	GRAPH ?g2 { ?b a ex:Thing }
	GRAPH ?g3 { ?c a ex:Thing }
}
`

// budget_fixture loads GRAPH_COUNT named graphs of PER_GRAPH instances,
// each with a label no FILTER in this file matches.
@(private = "file")
budget_fixture :: proc(t: ^testing.T, d: ^Test_DB, loc := #caller_location) -> bool {
	if !test_db_open(t, d, "budget", loc = loc) {
		return false
	}
	for g in 0 ..< GRAPH_COUNT {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "@prefix ex: <http://example/> .\n")
		strings.write_string(&b, "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n")
		for i in 0 ..< PER_GRAPH {
			n := g * PER_GRAPH + i
			fmt.sbprintf(&b, "ex:t%d a ex:Thing ; rdfs:label \"label %d\" .\n", n, n)
		}
		label := fmt.aprintf("http://example/g%d", g)
		defer delete(label)
		if !test_db_load(t, d, strings.to_string(b), rdf.IRI(label), loc = loc) {
			return false
		}
	}
	return true
}

// budget_run drains a query under a budget and reports what came out and
// why it stopped.
@(private = "file")
budget_run :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	query: string,
	budget: Budget,
	loc := #caller_location,
) -> (
	rows: int,
	stop: Budget_Stop,
	ok: bool,
) {
	snap, pinned := test_db_snap(t, d, loc)
	if !pinned {
		return 0, .None, false
	}
	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return 0, .None, false
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return 0, .None, false
	}
	q: Query
	if !query_init(&q, algebra, snap, parser_base(&p), budget = budget) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		query_destroy(&q)
		return 0, .None, false
	}
	defer query_destroy(&q)
	for {
		_, more := query_next(&q)
		if !more {
			break
		}
		rows += 1
	}
	stop = query_stopped(&q)
	// **A query that has stopped stays stopped**, asserted on every run
	// rather than in one case, because every case would otherwise have to
	// trust it: the loop above has already met the end, so this pull is
	// the one past it.
	//
	// It was asserted only of a *cut* query when this file was written,
	// and finding out why was that task's one surprise: pulling an
	// exhausted query again re-entered its plan and yielded solutions it
	// had already given, on any query and without a budget in sight. That
	// is SPARQL-T-0055, fixed since — the exhausted state is on the node
	// now, beside `started` — so the two halves are one assertion again
	// and `query_stopped` goes on being the whole difference between
	// them.
	_, again := query_next(&q)
	testing.expect(t, !again, "a query that has stopped yields nothing more", loc = loc)
	testing.expect_value(t, query_stopped(&q), stop, loc = loc)
	return rows, stop, true
}

// The item's case, and the reason the whole thing exists: a query that
// produces no solution for a long time stops at its budget and says so.
//
// The pairing is the assertion. Unbudgeted the query answers nothing and
// reports `.None` — exhaustion, a complete (empty) answer. Budgeted it
// answers nothing and reports `.Operations` — a truncated answer that a
// caller must not read as complete. `query_next` said `false` both
// times.
@(test)
test_a_query_that_answers_nothing_stops_at_its_operation_budget :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !budget_fixture(t, &d) {
		return
	}

	rows, stop, ok := budget_run(t, &d, REPRO, Budget{})
	if !ok {
		return
	}
	testing.expect_value(t, rows, 0)
	testing.expect_value(t, stop, Budget_Stop.None)

	// One cadence's worth. The join needs far more than this and the
	// fixture is what makes that true: 13,824 candidate solutions, each
	// of them several operations.
	rows, stop, ok = budget_run(t, &d, REPRO, Budget{ops = BUDGET_CADENCE})
	if !ok {
		return
	}
	testing.expect_value(t, rows, 0)
	testing.expect_value(t, stop, Budget_Stop.Operations)
}

// The same query under a deadline already past. It is expressed as one
// nanosecond rather than as a millisecond the machine might beat,
// because a timing test that races the machine it runs on is a flake
// waiting for a slow CI runner: the first check happens after one
// cadence of work, by which time a one-nanosecond deadline is certainly
// gone, on any machine, under any load.
@(test)
test_a_wall_clock_budget_stops_the_same_query :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !budget_fixture(t, &d) {
		return
	}
	rows, stop, ok := budget_run(t, &d, REPRO, Budget{wall = 1 * time.Nanosecond})
	if !ok {
		return
	}
	testing.expect_value(t, rows, 0)
	testing.expect_value(t, stop, Budget_Stop.Wall_Clock)
}

// A truncated answer must not look like a complete one. This is the case
// a consumer meets rather than the case that filed the item: the query
// is answering, the budget cuts it mid-stream, and what the caller holds
// is a prefix.
@(test)
test_a_budget_truncates_a_query_that_is_answering :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !budget_fixture(t, &d) {
		return
	}
	instances := GRAPH_COUNT * PER_GRAPH
	whole := instances * instances * instances

	full, stop, ok := budget_run(t, &d, CROSS, Budget{})
	if !ok {
		return
	}
	testing.expect_value(t, full, whole)
	testing.expect_value(t, stop, Budget_Stop.None)

	cut, cut_stop, cut_ok := budget_run(t, &d, CROSS, Budget{ops = BUDGET_CADENCE})
	if !cut_ok {
		return
	}
	testing.expect_value(t, cut_stop, Budget_Stop.Operations)
	testing.expectf(t, cut > 0, "the cut answer is a prefix, not nothing: %d rows", cut)
	testing.expectf(t, cut < full, "the cut answer is shorter than the whole: %d of %d", cut, full)
}

// A budget nothing reaches changes nothing, which is the promise every
// existing caller is owed. The number is large enough that the join
// cannot approach it and small enough to stay an honest bound rather
// than `max(int)` by another name.
@(test)
test_a_budget_the_query_does_not_reach_is_not_a_budget :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !budget_fixture(t, &d) {
		return
	}
	instances := GRAPH_COUNT * PER_GRAPH
	rows, stop, ok := budget_run(t, &d, CROSS, Budget{ops = 100_000_000, wall = time.Minute})
	if !ok {
		return
	}
	testing.expect_value(t, rows, instances * instances * instances)
	testing.expect_value(t, stop, Budget_Stop.None)
}

// **The budget is the query's, not the process's** — the difference
// between this and the read tally in `counting.odin`, which is a
// benchmark instrument and says so. Two queries over one snapshot: the
// first is cut, and the second, prepared after it, answers in full.
@(test)
test_a_budget_belongs_to_one_query :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !budget_fixture(t, &d) {
		return
	}
	if _, stop, ok := budget_run(t, &d, REPRO, Budget{ops = BUDGET_CADENCE}); !ok {
		return
	} else {
		testing.expect_value(t, stop, Budget_Stop.Operations)
	}
	instances := GRAPH_COUNT * PER_GRAPH
	rows, stop, ok := budget_run(t, &d, CROSS, Budget{})
	if !ok {
		return
	}
	testing.expect_value(t, rows, instances * instances * instances)
	testing.expect_value(t, stop, Budget_Stop.None)
}
