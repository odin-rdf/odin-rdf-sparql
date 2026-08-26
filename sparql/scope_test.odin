package sparql

// The application's ceiling on what a query may read (SPARQL-T-0044):
// `query_init`'s scope and graph set, asserted directly.
//
// The set is not a dataset clause and not a view. It is what the query
// may read *at all*, decided above the query text by whoever computed
// it — a workspace and its ancestors, say — and enforced per fact by
// record inside `scan_next`, below every operator here. So the cases
// below are about what a scoped query cannot be made to see: a plain
// pattern (the default graph) under a set that omits the default graph
// sees nothing; `GRAPH <x>` for an x outside the set yields nothing
// rather than erroring; `GRAPH ?g` ranges over the set's named graphs;
// and an empty set is empty, however its slice was built.
//
// Solutions are compared as a set: the store promises nothing about
// the order it yields quads in.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

@(private = "file")
GA :: "http://example/ga"
@(private = "file")
GB :: "http://example/gb"

// scoped opens the three-graph fixture — one triple in each named graph
// and one in the default graph — resolves the labels it is given to
// this snapshot's ids ("" for the default graph), and answers the query
// under that scope. `graphs == nil` with `.Set` is the empty set.
@(private = "file")
scoped :: proc(
	t: ^testing.T,
	query: string,
	scope: record.Graph_Scope,
	labels: []string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "scope", loc = loc) {
		return nil, false
	}
	if !test_db_load(t, &d, `@prefix : <http://example/> . :s0 :p :o0 .`, nil, loc = loc) ||
	   !test_db_load(t, &d, `@prefix : <http://example/> . :s1 :p :o1 .`, rdf.IRI(GA), loc = loc) ||
	   !test_db_load(t, &d, `@prefix : <http://example/> . :s2 :p :o2 .`, rdf.IRI(GB), loc = loc) {
		return nil, false
	}
	snap, pinned := test_db_snap(t, &d, loc)
	if !pinned {
		return nil, false
	}
	ids := make([dynamic]record.Term_ID, context.temp_allocator)
	for label in labels {
		if label == "" {
			append(&ids, record.MATCH_DEFAULT_GRAPH)
			continue
		}
		// A label the store has never seen is a miss and is dropped —
		// never 0, which in a set is the default graph.
		if id, found := record.snapshot_resolve(snap, rdf.IRI(label)); found {
			append(&ids, id)
		}
	}
	rows, ok = test_solve(t, &d, query, render_subjects, loc, scope, ids[:])
	if ok {
		slice.sort(rows[:])
	}
	return
}

// render_subjects writes the bound IRIs of a row in variable-name
// order — every variable in these queries binds an IRI.
@(private = "file")
render_subjects :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
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
		iri, _ := query_term(q, row[slot]).(rdf.IRI)
		fmt.sbprintf(&b, "?%s=<%s>", names[slot], string(iri))
	}
	return strings.to_string(b)
}

@(private = "file")
NAMED :: `PREFIX : <http://example/> SELECT ?g ?s WHERE { GRAPH ?g { ?s :p ?o } }`
@(private = "file")
DEFAULT :: `PREFIX : <http://example/> SELECT ?s WHERE { ?s :p ?o }`
@(private = "file")
IN_GB :: `PREFIX : <http://example/> SELECT ?s WHERE { GRAPH <http://example/gb> { ?s :p ?o } }`

@(test)
test_scope_all_is_todays_answer :: proc(t: ^testing.T) {
	rows, ok := scoped(t, NAMED, .All, nil)
	defer destroy_rows(&rows)
	if ok {
		expect_rows(t, rows, {`?g=<http://example/ga> ?s=<http://example/s1>`, `?g=<http://example/gb> ?s=<http://example/s2>`})
	}
	rows2, ok2 := scoped(t, DEFAULT, .All, nil)
	defer destroy_rows(&rows2)
	if ok2 {
		expect_rows(t, rows2, {`?s=<http://example/s0>`})
	}
}

@(test)
test_scope_graph_variable_ranges_over_the_set :: proc(t: ^testing.T) {
	rows, ok := scoped(t, NAMED, .Set, {GA})
	defer destroy_rows(&rows)
	if ok {
		expect_rows(t, rows, {`?g=<http://example/ga> ?s=<http://example/s1>`})
	}
	// The default graph in the set adds nothing to GRAPH ?g, which
	// ranges over named graphs alone.
	rows2, ok2 := scoped(t, NAMED, .Set, {"", GB})
	defer destroy_rows(&rows2)
	if ok2 {
		expect_rows(t, rows2, {`?g=<http://example/gb> ?s=<http://example/s2>`})
	}
}

@(test)
test_scope_named_graph_outside_the_set_yields_nothing :: proc(t: ^testing.T) {
	rows, ok := scoped(t, IN_GB, .Set, {GA})
	defer destroy_rows(&rows)
	if ok {
		expect_rows(t, rows, {})
	}
	rows2, ok2 := scoped(t, IN_GB, .Set, {GA, GB})
	defer destroy_rows(&rows2)
	if ok2 {
		expect_rows(t, rows2, {`?s=<http://example/s2>`})
	}
}

@(test)
test_scope_default_graph_must_be_in_the_set :: proc(t: ^testing.T) {
	rows, ok := scoped(t, DEFAULT, .Set, {GA})
	defer destroy_rows(&rows)
	if ok {
		expect_rows(t, rows, {})
	}
	rows2, ok2 := scoped(t, DEFAULT, .Set, {"", GA})
	defer destroy_rows(&rows2)
	if ok2 {
		expect_rows(t, rows2, {`?s=<http://example/s0>`})
	}
}

@(test)
test_scope_empty_set_is_empty :: proc(t: ^testing.T) {
	// nil under .Set, and a label the store has never seen — which
	// resolves to nothing and leaves the set empty with a non-nil
	// buffer behind it. Both are "scoped to nothing", and record's
	// Graph_Scope (RECORD-T-0029) is what makes the two the same.
	rows, ok := scoped(t, NAMED, .Set, nil)
	defer destroy_rows(&rows)
	if ok {
		expect_rows(t, rows, {})
	}
	rows2, ok2 := scoped(t, DEFAULT, .Set, {"http://example/never-loaded"})
	defer destroy_rows(&rows2)
	if ok2 {
		expect_rows(t, rows2, {})
	}
}

@(test)
test_scope_set_is_copied :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "scope-copy") {
		return
	}
	if !test_db_load(t, &d, `@prefix : <http://example/> . :s1 :p :o1 .`, rdf.IRI(GA)) ||
	   !test_db_load(t, &d, `@prefix : <http://example/> . :s2 :p :o2 .`, rdf.IRI(GB)) {
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		return
	}
	ga, _ := record.snapshot_resolve(snap, rdf.IRI(GA))
	gb, _ := record.snapshot_resolve(snap, rdf.IRI(GB))

	p: Parser
	parser_init(&p, transmute([]byte)string(NAMED), TEST_BASE)
	defer parser_destroy(&p)
	_, parsed := parse(&p)
	algebra, translated := translate(&p)
	if !testing.expect(t, parsed && translated) {
		return
	}
	set := [1]record.Term_ID{ga}
	q: Query
	if !testing.expect(t, query_init(&q, algebra, snap, parser_base(&p), .Set, set[:])) {
		return
	}
	defer query_destroy(&q)
	// The caller's slice is theirs to reuse: the query holds a copy.
	set[0] = gb
	g_slot := -1
	for name, slot in query_var_names(&q) {
		if name == "g" {
			g_slot = slot
		}
	}
	if !testing.expect(t, g_slot >= 0, "?g has a slot") {
		return
	}
	n := 0
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		n += 1
		testing.expect_value(t, row[g_slot], ga)
	}
	testing.expect_value(t, n, 1)
}
