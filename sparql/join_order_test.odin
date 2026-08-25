// Cost-based join ordering: that it happens, and that it is connected
// before it is cheap (SPARQL-T-0037).
//
// **These assertions cannot be made by a result comparison**, which is
// why they are here and not in `tests/w3c`. Reordering a BGP is required
// to be answer-preserving — the corpus is the proof that it is — so a
// suite that only checks solutions cannot tell a planner that reorders
// from one that does not. What is asserted below is `plan.order` itself:
// the permutation, against a fixture built so that the written order is
// the wrong one.
package sparql

import "core:testing"

// A store whose three predicates have deliberately lopsided extents, so
// that "cheapest first" and "as written" disagree and the disagreement
// is visible in the permutation.
//
//	:t     — 6 subjects are a :T                    (6 candidates)
//	:mid   — the same 6, each to one of 3 mids      (6)
//	:tag   — one subject only                       (1)
@(private = "file")
JOIN_ORDER_FIXTURE :: `
@prefix : <http://example/> .
:a a :T ; :mid :m1 .
:b a :T ; :mid :m1 .
:c a :T ; :mid :m2 .
:d a :T ; :mid :m2 .
:e a :T ; :mid :m3 .
:f a :T ; :mid :m3 .
:a :tag "only" .
`

// plan_order returns the BGP permutation a query's plan was built with,
// for a query whose whole pattern is one BGP.
@(private = "file")
plan_order :: proc(t: ^testing.T, d: ^Test_DB, query: string, loc := #caller_location) -> (order: []int, ok: bool) {
	snap, pinned := test_db_snap(t, d, loc)
	if !pinned {
		return nil, false
	}
	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return nil, false
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return nil, false
	}
	q: Query
	defer query_destroy(&q)
	if !query_init(&q, algebra, snap, parser_base(&p)) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		return nil, false
	}
	bgp, is_bgp := q.plan.(^Plan_BGP)
	if !testing.expect(t, is_bgp, "the query's plan is not a single BGP", loc = loc) {
		return nil, false
	}
	// Copied out: the plan dies with the query at the deferred destroy.
	out := make([]int, len(bgp.order))
	copy(out, bgp.order[:])
	return out, true
}

@(test)
test_join_order_puts_the_selective_pattern_first :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "join-order") {return}
	if !test_db_load(t, &d, JOIN_ORDER_FIXTURE) {return}

	// Written worst-first: `?s a :T` matches six, `?s :tag ?g` matches
	// one. Both bind ?s, so both are connected the moment either is
	// chosen and cost alone decides — which is the case this task is
	// named for.
	order, ok := plan_order(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s a :T . ?s :tag ?g }`)
	defer delete(order)
	if !ok {return}
	testing.expect_value(t, len(order), 2)
	testing.expectf(t, order[0] == 1, "the one-candidate pattern must be probed first, got %v", order)
}

@(test)
test_join_order_is_stable_on_equal_counts :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "join-order-stable") {return}
	if !test_db_load(t, &d, JOIN_ORDER_FIXTURE) {return}

	// `a :T` and `:mid` have six candidates each. Equal cost must keep
	// the written order: the query's text still decides what the data
	// does not, and an unstable sort here would make a failing plan
	// depend on the sort implementation rather than on the query.
	order, ok := plan_order(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s a :T . ?s :mid ?m }`)
	defer delete(order)
	if !ok {return}
	testing.expect_value(t, len(order), 2)
	testing.expectf(t, order[0] == 0 && order[1] == 1, "equal counts must keep the written order, got %v", order)

	// And the same two patterns written the other way round stay the
	// other way round -- otherwise "stable" would be indistinguishable
	// from "happens to agree with the query here".
	swapped, ok2 := plan_order(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :mid ?m . ?s a :T }`)
	defer delete(swapped)
	if !ok2 {return}
	testing.expectf(t, swapped[0] == 0 && swapped[1] == 1, "equal counts must keep the written order, got %v", swapped)
}

@(test)
test_join_order_prefers_connected_over_cheap :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "join-order-connected") {return}
	if !test_db_load(t, &d, JOIN_ORDER_FIXTURE) {return}

	// **The case that cost alone gets wrong**, and the reason
	// `join_order` is two-level rather than a sort.
	//
	// Written: `?x :tag ?g` (1 candidate), `?s a :T` (6), `?s :mid ?x`
	// (6). Ascending cost alone is 0, 1, 2 — and pattern 1 shares no
	// variable with pattern 0, so probing it second substitutes nothing
	// and repeats the same six-candidate scan for every row pattern 0
	// produced. That is a cross product, which pattern 2 then filters.
	// Connected-first must take 0, then 2 (the only remaining pattern
	// touching ?x), then 1 — which costs more by the static numbers and
	// is the right plan.
	order, ok := plan_order(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?x :tag ?g . ?s a :T . ?s :mid ?x }`)
	defer delete(order)
	if !ok {return}
	testing.expect_value(t, len(order), 3)
	testing.expectf(
		t,
		order[0] == 0 && order[1] == 2 && order[2] == 1,
		"a connected pattern must beat a cheaper disconnected one, got %v",
		order,
	)
}

@(test)
test_join_order_puts_an_unsatisfiable_pattern_first :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "join-order-empty") {return}
	if !test_db_load(t, &d, JOIN_ORDER_FIXTURE) {return}

	// A pattern whose terms all exist but whose *combination* does not.
	// It has to be written this way to reach `join_order` at all: a
	// pattern naming a term the store has never seen collapses to
	// `Plan_Nothing` in `ground_ref` long before ordering sees it. Both
	// `:tag` and `:m1` are in the dictionary here; no fact joins them.
	order, ok := plan_order(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s a :T . ?s :tag :m1 }`)
	defer delete(order)
	if !ok {return}
	testing.expect_value(t, len(order), 2)
	// Zero candidates sorts first, which is free and correct: the
	// cheapest pattern to probe is the one that cannot match.
	testing.expectf(t, order[0] == 1, "a zero-candidate pattern must be probed first, got %v", order)
}
