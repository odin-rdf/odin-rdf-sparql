package sparql

// What a GRAPH clause does to what is inside it (SPARQL-T-0020),
// asserted directly rather than only through the W3C suites.
//
// One sentence of §18.5 decides every case here: **the variable a GRAPH
// clause binds is not in scope inside the clause.**
//
//     eval(D(G), Graph(var, P)) =
//         for each IRI i in D:  Union(R, Join(eval(D(D[i]), P), Ω(var→i)))
//
// P is evaluated against one graph at a time, as a plain graph, and the
// variable is joined on afterwards. So an occurrence of `?g` inside the
// clause is an ordinary variable bound by a subject, predicate or object
// position, and it reaches the graph the solution was found in only
// through that final join.
//
// The suites pin the two entries this cost the engine — `graph-optional`
// in sparql10-graph and `graph-minus` in sparql11-negation — but they
// pin them in a form built out of document IRIs and relative references,
// where the coincidence that makes the answer come out is hard to see.
// The first two cases below are the same two rules written so that it is
// visible. The rest are the paths the suites do not reach.
//
// Solutions are compared as a multiset: the store promises nothing about
// the order it yields quads in.
//
// *(Moved into this package by SPARQL-T-0032, from `sparql/kvstore`.
// Each fixture is now one `apply` into one graph of a `Test_DB` over
// record's memory seam; not one assertion changed.)*

import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

// `GRAPH ?g { ?s ?p ?o OPTIONAL { ?s ?p ?g } }` — the DAWG's
// graph-optional, whose comment is "the variable bound by the GRAPH
// operator is not used when evaluating a nested OPTIONAL".
//
// Inside the clause `?g` is bound by the OPTIONAL's *object*, not by the
// graph. It matches for every subject, so the join with Ω(?g→i) then
// keeps only the solution whose object happens to be the graph's own
// name — here `:s2`, whose object is `:ga`. Every other solution is
// dropped, including both of `:gb`'s.
//
// Pushing ?g into the graph position instead, which is the cheap reading,
// makes the OPTIONAL demand that a triple's object equal its own graph.
// That practically never holds, so the OPTIONAL never matches, and *all
// four* solutions survive with ?g bound. Four against one is the whole of
// the difference.
@(test)
test_graph_variable_is_not_in_scope_in_an_optional :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"http://example/ga", `@prefix : <http://example/> . :s1 :p :o . :s2 :p :ga .`},
			{"http://example/gb", `@prefix : <http://example/> . :s3 :p :o . :s4 :p :o .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?s WHERE { GRAPH ?g { ?s ?p ?o OPTIONAL { ?s ?p ?g } } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?g=<http://example/ga> ?s=<http://example/s2>`})
}

// `GRAPH ?g { ?a :p :o MINUS { ?b :p :o } }` — the SPARQL 1.1 suite's
// graph-minus, whose comment is "outer GRAPH operator does not affect
// MINUS disjointness".
//
// §18.5's Minus removes a left solution only when a right solution is
// compatible with it *and shares a variable*. `?a` and `?b` share
// nothing, so nothing is removed however identical the two patterns look.
// An enclosing GRAPH does not change that, because ?g is not in either
// side's domain — it is not in scope in there at all.
//
// Pushing ?g into the graph position puts it in both domains, they stop
// being disjoint, and MINUS removes everything. The engine answered
// nothing here for as long as it did that.
@(test)
test_graph_clause_does_not_make_minus_domains_overlap :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{{"http://example/ga", `@prefix : <http://example/> . :a :p :o .`}},
		`PREFIX : <http://example/>
		 SELECT ?a WHERE { GRAPH ?g { ?a :p :o MINUS { ?b :p :o } } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?a=<http://example/a>`})
}

// The same MINUS with a variable genuinely in common still removes, and
// still only within one graph: `:a` is subtracted where the right side
// found it and left alone where it did not. It is the case that would
// pass just as well if the graph slot were ignored altogether, which is
// why it is here — the graph is what confines MINUS's right side to the
// graph its left side ran in, and only the *shared-variable* test may
// disregard it.
@(test)
test_minus_under_a_graph_clause_still_subtracts_within_the_graph :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"http://example/ga", `@prefix : <http://example/> . :a :p :o . :a :q :o .`},
			{"http://example/gb", `@prefix : <http://example/> . :a :p :o .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?a WHERE { GRAPH ?g { ?a :p :o MINUS { ?a :q :o } } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	// :a is removed in ga, where the right side found `:a :q :o`, and
	// survives in gb, where it did not.
	expect_solutions(t, rows, {`?a=<http://example/a> ?g=<http://example/gb>`})
}

// A GRAPH variable the enclosing pattern already bound. §18.5 joins
// Ω(?g→i) on after the fact, and every solution of every other graph is
// then discarded by that join — so the binding may just as well be handed
// down to the graph position before the scan starts, which is what the
// engine does. The observable answer is the same either way; what changes
// is whether the graph position is an index probe or a scan of the whole
// dataset followed by a filter.
@(test)
test_graph_variable_bound_by_an_enclosing_pattern :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"", `@prefix : <http://example/> . :d :graph :gb .`},
			{"http://example/ga", `@prefix : <http://example/> . :x :p :one .`},
			{"http://example/gb", `@prefix : <http://example/> . :x :p :two .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?o WHERE { ?d :graph ?g GRAPH ?g { :x :p ?o } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?g=<http://example/gb> ?o=<http://example/two>`})
}

// Each solution reports the graph it was found in, and not the one before
// it. The operator writes the GRAPH variable itself, so it also has to
// take the write back before the body runs again — a slot left bound
// would make the second graph's solutions look like they disagreed with
// the join and be dropped.
@(test)
test_graph_variable_is_released_between_solutions :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"http://example/ga", `@prefix : <http://example/> . :x :p :one .`},
			{"http://example/gb", `@prefix : <http://example/> . :x :p :two .`},
			{"http://example/gc", `@prefix : <http://example/> . :x :p :three .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?o WHERE { GRAPH ?g { :x :p ?o } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{
			`?g=<http://example/ga> ?o=<http://example/one>`,
			`?g=<http://example/gb> ?o=<http://example/two>`,
			`?g=<http://example/gc> ?o=<http://example/three>`,
		},
	)
}

// Nested GRAPH clauses bind both variables, and the inner one ranges over
// the whole dataset rather than over the outer one's graph: §18.5's
// `for each IRI i in D` reads the dataset, and an enclosing clause
// changes the active graph, not D. So the answer is every outer graph
// paired with every inner graph the pattern matches in — two solutions
// here, from one matching triple.
//
// The engine used to answer one, with ?g unbound: the inner clause took
// the graph position over, and nothing was left to bind the outer
// variable. A GRAPH clause's triple patterns match in *its* graph, which
// is why its subtree reports carrying no graph position at all
// (plan_matches_triples) and the outer clause enumerates instead.
@(test)
test_nested_graph_clauses_each_bind_their_own_variable :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"http://example/ga", `@prefix : <http://example/> . :x :p :one .`},
			{"http://example/gb", `@prefix : <http://example/> . :y :q :two .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?h ?o WHERE { GRAPH ?g { GRAPH ?h { :x :p ?o } } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{
			`?g=<http://example/ga> ?h=<http://example/ga> ?o=<http://example/one>`,
			`?g=<http://example/gb> ?h=<http://example/ga> ?o=<http://example/one>`,
		},
	)
}

// `GRAPH ?g { ?g :p ?o }` — the DAWG's graph-variable-join. Inside the
// clause ?g is bound by the *subject*, and the join then keeps only the
// graph whose name is that subject. Both readings answer this one the
// same way, which is exactly why it is not the test that settles the
// question — it is here so the pair with graph-optional is on the record.
@(test)
test_graph_variable_used_inside_the_clause_joins_on_the_way_out :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		{
			{"http://example/ga", `@prefix : <http://example/> . <http://example/ga> :p :one .`},
			{"http://example/gb", `@prefix : <http://example/> . :x :p :two .`},
		},
		`PREFIX : <http://example/>
		 SELECT ?g ?o WHERE { GRAPH ?g { ?g :p ?o } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?g=<http://example/ga> ?o=<http://example/one>`})
}

// --- helpers --------------------------------------------------------

// Fixture is one Turtle document and the graph it loads into; an empty
// name is the default graph.
@(private = "file")
Fixture :: struct {
	graph:  string,
	source: string,
}

@(private = "file")
solutions :: proc(
	t: ^testing.T,
	fixtures: []Fixture,
	query: string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "graph-scope", loc = loc) {
		return nil, false
	}
	// One apply per graph, so a fixture's document lands whole in the
	// graph it names. Each gets its own blank-node scope by ordinal —
	// two graphs sharing a label would be a fixture nobody wrote on
	// purpose.
	for fixture in fixtures {
		label: rdf.Graph_Label = nil
		if fixture.graph != "" {
			label = rdf.IRI(fixture.graph)
		}
		if !test_db_load(t, &d, fixture.source, label, loc = loc) {
			return nil, false
		}
	}
	return test_solve(t, &d, query, render_solution, loc)
}

// render_solution writes one solution's bindings in variable-name order,
// so a slot number — an artefact of plan building — never reaches an
// assertion.
@(private = "file")
render_solution :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
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
		write_term(&b, query_term(q, row[slot]))
	}
	return strings.to_string(b)
}

// Every binding these cases assert on is an IRI, so the rendering stops
// at "enough to tell one apart from another".
@(private = "file")
write_term :: proc(b: ^strings.Builder, term: rdf.Term) {
	switch v in term {
	case rdf.IRI:
		strings.write_byte(b, '<')
		strings.write_string(b, string(v))
		strings.write_byte(b, '>')
	case rdf.Blank_Node:
		strings.write_string(b, "_:")
	case rdf.Literal:
		strings.write_byte(b, '"')
		strings.write_string(b, v.lexical)
		strings.write_byte(b, '"')
	case ^rdf.Triple:
		strings.write_string(b, "<<triple>>")
	case nil:
		strings.write_string(b, "UNBOUND")
	}
}

@(private = "file")
expect_solutions :: proc(t: ^testing.T, rows: [dynamic]string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(rows) == len(want), "got %d solutions, want %d: %v", len(rows), len(want), rows, loc = loc) {
		return
	}
	got := slice.clone(rows[:], context.temp_allocator)
	expected := slice.clone(want, context.temp_allocator)
	slice.sort(got)
	slice.sort(expected)
	for candidate, i in expected {
		testing.expectf(t, got[i] == candidate, "solution %d: got %q, want %q", i, got[i], candidate, loc = loc)
	}
}
