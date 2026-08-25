// The merge join: that it is taken, that it is declined, and that it
// finds what the nested loop finds (SPARQL-T-0029).
//
// **The first two cannot be asserted by a result comparison**, and that
// is the whole reason this file exists. A join strategy is required to
// be answer-preserving — the W3C corpus is the proof that this one is —
// so a suite that only checks solutions cannot tell a merge from a
// nested loop. What the planning cases below assert is `Plan_BGP.merge`
// itself: whether the plan took it, and with which permutations. It is
// the same argument that gave `join_order_test.odin` its `plan_order`,
// and this file is written against it as the pattern.
//
// The evaluation cases are the other half, and they are aimed rather
// than broad: the corpus exercises the merge heavily but incidentally,
// so the fixtures here are built for the two shapes most likely to be
// got wrong — a join value repeated on *both* sides, which is the only
// place the group has to be replayed, and a correlated re-run, which is
// the only place the cursors have to be thrown away.
package sparql

import "rdf:rdf"
import "record:record"
import "core:slice"
import "core:strings"
import "core:testing"

// Two predicates of equal extent over the same three subjects, so the
// pricing is a ratio of 1 and the merge is taken on the shape it is
// meant for.
@(private = "file")
MERGE_EVEN_FIXTURE :: `
@prefix : <http://example/> .
:a :p "1" ; :q "a" .
:b :p "2" ; :q "b" .
:c :p "3" ; :q "c" .
`

// One `:rare` fact against twenty `:common` ones. join_order puts the
// selective pattern first, so the merge would read a window twenty times
// the rows it can serve — over MERGE_SCAN_PRICE, and declined.
@(private = "file")
MERGE_LOPSIDED_FIXTURE :: `
@prefix : <http://example/> .
:only :rare "r" .
:e0 :common "0" . :e1 :common "1" . :e2 :common "2" . :e3 :common "3" .
:e4 :common "4" . :e5 :common "5" . :e6 :common "6" . :e7 :common "7" .
:e8 :common "8" . :e9 :common "9" . :e10 :common "10" . :e11 :common "11" .
:e12 :common "12" . :e13 :common "13" . :e14 :common "14" . :e15 :common "15" .
:e16 :common "16" . :e17 :common "17" . :e18 :common "18" . :e19 :common "19" .
`

// A join value carried by two facts on each side, beside the three
// shapes that surround it: one-to-one, a left value with no right group
// at all, and a right value the left side never asks for.
@(private = "file")
MERGE_DUPLICATE_FIXTURE :: `
@prefix : <http://example/> .
:s1 :p "p1" , "p2" ; :q "q1" , "q2" .
:s2 :p "p3" ; :q "q3" .
:s3 :p "p4" .
:s4 :q "q4" .
`

// Three subjects for the outer pattern, two of which the merged inner
// BGP can answer for.
@(private = "file")
MERGE_CORRELATED_FIXTURE :: `
@prefix : <http://example/> .
:s1 :k "k1" ; :p "p1" ; :q "q1" .
:s2 :k "k2" ; :p "p2" ; :q "q2" .
:s3 :k "k3" .
`

// plan_merge_of returns the merge decision a query's plan was built
// with, for a query whose whole pattern is one BGP.
@(private = "file")
plan_merge_of :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	query: string,
	loc := #caller_location,
) -> (
	merge: Plan_Merge,
	ok: bool,
) {
	snap, pinned := test_db_snap(t, d, loc)
	if !pinned {
		return {}, false
	}
	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return {}, false
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return {}, false
	}
	q: Query
	defer query_destroy(&q)
	if !query_init(&q, algebra, snap, parser_base(&p)) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		return {}, false
	}
	bgp, is_bgp := q.plan.(^Plan_BGP)
	if !testing.expect(t, is_bgp, "the query's plan is not a single BGP", loc = loc) {
		return {}, false
	}
	// A value, so it outlives the deferred destroy without a copy.
	return bgp.merge, true
}

@(test)
test_merge_join_is_taken_on_a_two_pattern_join :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-even") {return}
	if !test_db_load(t, &d, MERGE_EVEN_FIXTURE) {return}

	merge, ok := plan_merge_of(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :p ?x . ?s :q ?y }`)
	if !ok {return}

	testing.expect(t, merge.active, "a two-pattern join of equal extents was not merged")
	// Both patterns share ?s in the subject position, and the order that
	// leads with it after the pattern's one ground component is PSOG in
	// each. Asserting the permutation and not only the flag is what makes
	// this a test of *the* merge rather than of some merge: read the
	// right side as SPOG and the windows would still be windows, but
	// they would not ascend together and the join would silently drop
	// solutions.
	testing.expect_value(t, merge.left_order, record.Order.PSOG)
	testing.expect_value(t, merge.right_order, record.Order.PSOG)
	testing.expect_value(t, merge.left_pos, QUAD_S)
	testing.expect_value(t, merge.right_pos, QUAD_S)
}

@(test)
test_merge_join_is_declined_when_the_right_side_dwarfs_the_left :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-lopsided") {return}
	if !test_db_load(t, &d, MERGE_LOPSIDED_FIXTURE) {return}

	// One `:rare` row against a twenty-fact `:common` window: a merge
	// would read all twenty to serve one, where the loop opens one narrow
	// probe. This is the pricing rule's declining branch, and the only
	// thing in the repository that fails if MERGE_SCAN_PRICE is raised
	// without an argument.
	merge, ok := plan_merge_of(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :rare ?r . ?s :common ?c }`)
	if !ok {return}

	testing.expect(t, !merge.active, "a 20:1 window ratio was merged; the pricing rule did not decline")
}

@(test)
test_merge_join_is_declined_for_two_shared_variables :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-two-vars") {return}
	if !test_db_load(t, &d, `@prefix : <http://example/> .
		:a :p :b . :a :q :b .`) {return}

	// ?s and ?o are both shared, so there is no single join value to
	// advance two cursors on. The nested loop handles it by substituting
	// both; a merge has no such move.
	merge, ok := plan_merge_of(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :p ?o . ?s :q ?o }`)
	if !ok {return}

	testing.expect(t, !merge.active, "a two-variable join was merged")
}

@(test)
test_merge_join_replays_a_repeated_join_value :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-duplicates") {return}
	if !test_db_load(t, &d, MERGE_DUPLICATE_FIXTURE) {return}

	merge, planned := plan_merge_of(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :p ?x . ?s :q ?y }`)
	if !planned {return}
	// The evaluation below would pass on the nested loop too, so the
	// fixture has to be one the merge actually runs on.
	if !testing.expect(t, merge.active, "fixture no longer plans a merge; the case below proves nothing") {
		return
	}

	rows, ok := test_solve(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :p ?x . ?s :q ?y }`, render_merge_row)
	defer destroy_rows(&rows)
	if !ok {return}

	// :s1 carries two facts on each side, so its group is replayed once
	// per left row and the four combinations must all appear. :s2 is the
	// one-to-one case, :s3 a left value with no group to find, and :s4 a
	// right value the left side never asks for -- the cursor has to walk
	// past it without binding it.
	expect_merge_rows(
		t,
		rows,
		[]string {
			`?s=:s1 ?x="p1" ?y="q1"`,
			`?s=:s1 ?x="p1" ?y="q2"`,
			`?s=:s1 ?x="p2" ?y="q1"`,
			`?s=:s1 ?x="p2" ?y="q2"`,
			`?s=:s2 ?x="p3" ?y="q3"`,
		},
	)
}

@(test)
test_merge_join_is_reopened_for_a_correlated_rerun :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-correlated") {return}
	if !test_db_load(t, &d, MERGE_CORRELATED_FIXTURE) {return}

	// The merged BGP is the right side of a left join, so it is run once
	// per row of the left -- three times, under a different binding of ?s
	// each time. The cursors are per-run state, and a merge that kept
	// them across runs would answer the second subject with the first
	// one's window. `merge_begin` is what makes this right, and this is
	// the case that fails if it stops being called from `!started`.
	rows, ok := test_solve(t, &d, `PREFIX : <http://example/>
		SELECT * WHERE { ?s :k ?v . OPTIONAL { ?s :p ?x . ?s :q ?y } }`, render_merge_row)
	defer destroy_rows(&rows)
	if !ok {return}

	expect_merge_rows(
		t,
		rows,
		[]string {
			`?s=:s1 ?v="k1" ?x="p1" ?y="q1"`,
			`?s=:s2 ?v="k2" ?x="p2" ?y="q2"`,
			`?s=:s3 ?v="k3"`,
		},
	)
}

@(test)
test_merge_order_does_not_widen_the_window :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "merge-window") {return}
	if !test_db_load(t, &d, MERGE_EVEN_FIXTURE) {return}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {return}

	// `match_open_as` claims that naming a permutation cannot cost
	// anything, because the order the merge picks prefixes on the same
	// ground components `choose_order` would have. That is what makes the
	// pricing legitimate -- `plan_merge` reuses `join_order`'s candidate
	// counts, which were taken with `snapshot_match`, to price windows
	// the merge will open with `snapshot_match_as`. If the two ever
	// disagreed, the planner would be pricing a window it does not read.
	//
	// Asserted over every position a join variable can take, against the
	// three ground shapes a triple pattern can have.
	id :: proc(t: ^testing.T, snap: record.Snapshot, iri: string) -> record.Term_ID {
		v, ok := record.snapshot_resolve(snap, rdf.IRI(iri))
		testing.expectf(t, ok, "%s did not resolve", iri)
		return v
	}
	p := id(t, snap, "http://example/p")
	a := id(t, snap, "http://example/a")
	patterns := []record.Pattern{{p = p}, {s = a}, {s = a, p = p}, {}}
	for pattern in patterns {
		chosen := record.range_len(record.snapshot_match(snap, pattern))
		for order in record.Order {
			named := record.range_len(record.snapshot_match_as(snap, pattern, order))
			// Only the orders a merge could pick are claimed to match --
			// one whose key leads with a component the pattern leaves
			// unbound is legitimately wider, which is why merge_order_for
			// maximises the prefix instead of taking the first fit.
			if named != chosen {
				testing.expectf(
					t,
					named > chosen,
					"order %v narrowed a window below choose_order's: %d vs %d",
					order,
					named,
					chosen,
				)
			}
		}
	}
}

// render_merge_row writes a solution's bindings in variable-name order.
// Slot numbers are an artefact of plan building and never reach an
// assertion.
@(private = "file")
render_merge_row :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
	order := make([dynamic]int, context.temp_allocator)
	for id, slot in row {
		if id == UNBOUND || internal[slot] {
			continue
		}
		at := len(order)
		for at > 0 && names[order[at - 1]] > names[slot] {
			at -= 1
		}
		inject_at(&order, at, slot)
	}
	b := strings.builder_make()
	for slot, i in order {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, '?')
		strings.write_string(&b, names[slot])
		strings.write_byte(&b, '=')
		write_merge_term(&b, query_term(q, row[slot]))
	}
	return strings.to_string(b)
}

@(private = "file")
write_merge_term :: proc(b: ^strings.Builder, term: rdf.Term) {
	switch v in term {
	case rdf.IRI:
		// Enough to tell one subject from another: the last path segment,
		// written the way the fixture's prefix does.
		text := string(v)
		at := strings.last_index_byte(text, '/')
		strings.write_byte(b, ':')
		strings.write_string(b, text[at + 1:] if at >= 0 else text)
	case rdf.Literal:
		strings.write_quoted_string(b, v.lexical)
	case rdf.Blank_Node:
		strings.write_string(b, "_:")
		strings.write_string(b, string(v))
	case ^rdf.Triple:
		// No fixture here holds one; rendered rather than skipped so the
		// switch stays exhaustive when a term kind is added.
		strings.write_string(b, "<<...>>")
	}
}

// expect_merge_rows compares solutions as a multiset. A join strategy
// may reorder what it finds and must not change it, so asserting a
// sequence here would be asserting the implementation.
@(private = "file")
expect_merge_rows :: proc(t: ^testing.T, rows: [dynamic]string, want: []string, loc := #caller_location) {
	got := make([]string, len(rows), context.temp_allocator)
	copy(got, rows[:])
	slice.sort(got)
	sorted := make([]string, len(want), context.temp_allocator)
	copy(sorted, want)
	slice.sort(sorted)
	if !testing.expectf(t, len(got) == len(sorted), "got %d solutions, want %d: %v", len(got), len(sorted), got, loc = loc) {
		return
	}
	for expected, i in sorted {
		testing.expectf(t, got[i] == expected, "solution %d: got %q, want %q", i, got[i], expected, loc = loc)
	}
}
