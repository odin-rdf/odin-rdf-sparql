package sparql

// An exhausted query stays exhausted (SPARQL-T-0055).
//
// `query_next` answering `false` is the end of the answer, and pulling
// again must not restart the plan. Before this was true, `bgp_next`
// resumed from `node.started` -- a run that had walked back to depth −1
// left every iterator closed and nothing to say the run was over, so the
// next call re-opened the deepest scan against whatever the working row
// still held and produced solutions the caller had already been given.
//
// **The property is asserted per source kind and not once**, because
// what makes it true is a state on the node rather than a guard at the
// driver's boundary: a BGP, a path, a `VALUES` block, a materialized
// subquery and a blocking operator each end their run in their own
// procedure, and a fix that only refused the top-level pull would leave
// the same state machine underneath. Each case below therefore names the
// `Exec_Kind` it exists to cover and fails if the plan does not hold one
// -- an assertion about the plan, so that a planner change cannot quietly
// turn a case into a duplicate of the first.
//
// The second half of every case is that exhaustion still does not look
// like truncation: `query_stopped` stays `.None` across the pulls past
// the end, which is the distinction SPARQL-T-0053 exists to keep.

import "core:testing"

import rdf "rdf:rdf"

// PAST_THE_END is how many times each case pulls after the end. The
// item's measurement took five, and five is enough here for a different
// reason: a resuming BGP produces a fresh solution on *every* extra
// pull, so one would catch it, and five catches an operator that
// resumes once and then settles.
@(private = "file")
PAST_THE_END :: 5

// The item's fixture: four instances of one class over two graphs, with
// a `ex:next` chain among them. Four instances joined against themselves
// is the sixteen solutions the measurement reports.
@(private = "file")
GRAPH_A :: `
@prefix ex: <http://example/> .
ex:a a ex:Thing ; ex:next ex:b .
ex:b a ex:Thing ; ex:next ex:c .
ex:c a ex:Thing ; ex:next ex:d .
`

@(private = "file")
GRAPH_B :: `
@prefix ex: <http://example/> .
ex:d a ex:Thing .
`

@(private = "file")
exhausted_fixture :: proc(t: ^testing.T, d: ^Test_DB, loc := #caller_location) -> bool {
	if !test_db_open(t, d, "exhausted", loc = loc) {
		return false
	}
	if !test_db_load(t, d, GRAPH_A, rdf.IRI("http://example/ga"), loc = loc) {
		return false
	}
	return test_db_load(t, d, GRAPH_B, rdf.IRI("http://example/gb"), loc = loc)
}

// drain_and_pull_past_the_end is the whole assertion. It prepares the
// query, checks that its plan holds the source kind the case is about,
// drains it, and then pulls PAST_THE_END times more -- each of which
// must answer `false` and leave `query_stopped` at `.None`.
@(private = "file")
drain_and_pull_past_the_end :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	query: string,
	kind: Exec_Kind,
	want_rows: int,
	loc := #caller_location,
) {
	snap, pinned := test_db_snap(t, d, loc)
	if !pinned {
		return
	}
	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return
	}
	q: Query
	defer query_destroy(&q)
	if !query_init(&q, algebra, snap, parser_base(&p)) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		return
	}
	testing.expectf(t, plan_holds_kind(&q, kind), "the plan holds no %v node, so this case is not about one", kind, loc = loc)

	rows := 0
	for {
		_, more := query_next(&q)
		if !more {
			break
		}
		rows += 1
	}
	testing.expectf(t, rows == want_rows, "drained %d solutions, want %d", rows, want_rows, loc = loc)

	for i in 0 ..< PAST_THE_END {
		_, again := query_next(&q)
		testing.expectf(t, !again, "pull %d past the end yielded a solution", i + 1, loc = loc)
		testing.expectf(
			t,
			query_stopped(&q) == .None,
			"pull %d past the end reported %v; an exhausted query is not a cut one",
			i + 1,
			query_stopped(&q),
			loc = loc,
		)
	}
}

@(private = "file")
plan_holds_kind :: proc(q: ^Query, kind: Exec_Kind) -> bool {
	for node in q.exec.nodes {
		if node.kind == kind {
			return true
		}
	}
	return false
}

// The item's own reproduction, to the row: a two-pattern join over the
// four-instance two-graph fixture drains sixteen solutions and then
// answered `true` on each of the next five pulls.
@(test)
test_an_exhausted_basic_graph_pattern_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?a ?b WHERE { GRAPH ?g1 { ?a a ex:Thing } GRAPH ?g2 { ?b a ex:Thing } }`,
		.BGP,
		16,
	)
}

// A path is its own source: `path_next` walks a frontier rather than a
// chain of iterators, so its end is a different procedure's business.
@(test)
test_an_exhausted_path_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?a ?b WHERE { GRAPH ?g { ?a ex:next+ ?b } }`,
		.Path,
		6,
	)
}

// A `VALUES` block answers from memory and never reaches the store, so
// nothing about its end goes through `match_next`.
@(test)
test_an_exhausted_inline_table_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?v WHERE { VALUES ?v { ex:a ex:b ex:c } }`,
		.Table,
		3,
	)
}

// A subquery on the right of a join is materialized: collected once and
// replayed per left solution. Its end is `stored_next`'s, and the replay
// is exactly the re-run that must go on working -- which is why the
// exhausted state is cleared by `node_reset` and not only at the top.
@(test)
test_an_exhausted_materialized_subquery_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?a ?b WHERE {
		   GRAPH ?g { ?a a ex:Thing }
		   { SELECT ?b WHERE { GRAPH ?h { ?b a ex:Thing } } }
		 }`,
		.Materialized,
		16,
	)
}

// A blocking operator is input-driven until its input runs out and a
// source afterwards, so it has two ends and only the second one is the
// query's.
@(test)
test_an_exhausted_blocking_operator_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?a WHERE { GRAPH ?g { ?a a ex:Thing } } ORDER BY ?a`,
		.Order,
		4,
	)
}

// A query whose answer is empty is exhausted from the first pull, and
// the state has to be reached by a walk that produced nothing at all --
// the case where "it answered `false` once" and "it never answered"
// coincide.
@(test)
test_a_query_with_no_answer_stays_exhausted :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !exhausted_fixture(t, &d) {
		return
	}
	drain_and_pull_past_the_end(
		t,
		&d,
		`PREFIX ex: <http://example/>
		 SELECT ?a WHERE { GRAPH ?g { ?a a ex:Thing ; ex:next ex:a } }`,
		.BGP,
		0,
	)
}
