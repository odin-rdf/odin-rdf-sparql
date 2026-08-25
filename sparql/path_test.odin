package sparql

// Property-path semantics (SPARQL-T-0016), asserted directly rather than
// only through the W3C suite.
//
// §18.4 is a short section with an unusual number of ways to be subtly
// wrong, and the suite is a poor place to *learn* which sentence a failure
// belongs to: that a zero-length path over a ground endpoint applies even
// when the data has never mentioned the term, but a zero-length path
// between two variables ranges over the graph's nodes and so cannot
// resurrect a term the query invented; that `*` and `+` and `?` are sets
// while the alternation and the sequence around them are bags. Each of
// those gets a case here that says which rule it is.
//
// Solutions are compared as a multiset — the store promises nothing about
// the order it yields quads in, so an assertion that depended on it would
// break for reasons that are not about SPARQL.
//
// *(Moved into this package by SPARQL-T-0032, from `sparql/kvstore`.
// The store became a `Test_DB` over record's memory seam; not one
// assertion changed.)*

import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

// A diamond with a self-loop on one arm: two routes from :a to :z, and a
// cycle to prove termination is not an accident of acyclic data.
@(private = "file")
DIAMOND :: `@prefix : <http://example/> .
:a :p :b .
:b :p :z .
:a :p :c .
:c :p :z .
:c :p :c .
`

// §18.4's ALP starts at the node it is given, whatever the data holds.
// `:s :p* ?o` over a graph that never mentions :s still answers ?o = :s:
// the zero-length path is a property of the endpoint, not of the graph.
@(test)
test_path_zero_length_over_a_ground_endpoint :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> . :other :p :thing .`,
		`PREFIX : <http://example/> SELECT ?o WHERE { :s :p* ?o }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?o=<http://example/s>`})
}

// The same rule from the other end: nothing fixes the subject, so the
// traversal runs backwards from the object, and the zero-length path
// answers for it.
@(test)
test_path_zero_length_reaches_backwards :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> . :other :p :thing .`,
		`PREFIX : <http://example/> SELECT ?s WHERE { ?s :p* :o }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?s=<http://example/o>`})
}

// Between two *variables* the zero-length path ranges over nodes(G) — the
// subjects and objects of the active graph — so a term the query supplied
// and the data does not hold contributes nothing. This is the rule that
// makes `VALUES ?v { 1 } . ?v :p? ?v` answer nothing, and it is why the
// case is chosen by the pattern rather than by what happens to be bound
// when the operator runs.
@(test)
test_path_zero_length_between_variables_is_the_graphs_nodes :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> . :other :p :thing .`,
		`PREFIX : <http://example/> SELECT * WHERE { VALUES ?v { :s } ?v :p? ?v }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {})
}

// nodes(G) is subjects *and* objects, literals included: a literal is a
// node of the graph and `?x :p* ?y` has to answer for it.
@(test)
test_path_zero_length_counts_literal_objects :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> . :s :name "Alice" .`,
		`PREFIX : <http://example/> SELECT * WHERE { ?x :knows* ?y }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{`?x=<http://example/s> ?y=<http://example/s>`, `?x="Alice"^^xsd:string ?y="Alice"^^xsd:string`},
	)
}

// `+` does not include its start — and includes it anyway when a cycle
// leads back, because then the start really is reached in one or more
// steps. :c loops onto itself; :a does not.
@(test)
test_path_one_or_more_excludes_the_start_unless_a_cycle_returns :: proc(t: ^testing.T) {
	rows, ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?z WHERE { :a :p+ ?z }`)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{`?z=<http://example/b>`, `?z=<http://example/c>`, `?z=<http://example/z>`},
	)

	looped, looped_ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?z WHERE { :c :p+ ?z }`)
	defer destroy_rows(&looped)
	if !looped_ok {
		return
	}
	expect_solutions(t, looped, {`?z=<http://example/c>`, `?z=<http://example/z>`})
}

// The repeats are sets: :z is reached from :a by two distinct routes
// through the diamond and answers once. The `?` case is the same rule one
// step short of a closure — `(:p/:p)?` reaches :z twice and :c once, and
// :a comes from the zero-length path.
@(test)
test_path_repeats_are_sets :: proc(t: ^testing.T) {
	star, star_ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?z WHERE { :a :p* ?z }`)
	defer destroy_rows(&star)
	if !star_ok {
		return
	}
	expect_solutions(
		t,
		star,
		{
			`?z=<http://example/a>`,
			`?z=<http://example/b>`,
			`?z=<http://example/c>`,
			`?z=<http://example/z>`,
		},
	)

	optional, optional_ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?t WHERE { :a (:p/:p)? ?t }`)
	defer destroy_rows(&optional)
	if !optional_ok {
		return
	}
	expect_solutions(
		t,
		optional,
		{`?t=<http://example/a>`, `?t=<http://example/c>`, `?t=<http://example/z>`},
	)
}

// Everything around the repeats stays a bag. `(:p1|:p2)/:q` reaches the
// same node down both alternatives and answers twice — the difference from
// the case above is the whole reason the repeats need a visited set and
// the rest of the path forms must not have one.
@(test)
test_path_alternation_and_sequence_are_bags :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> .
		 :a :p1 :m1 . :a :p2 :m2 . :m1 :q :end . :m2 :q :end .`,
		`PREFIX : <http://example/> SELECT ?t WHERE { :a (:p1|:p2)/:q ?t }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(t, rows, {`?t=<http://example/end>`, `?t=<http://example/end>`})
}

// A repeat whose step is itself a path: the step sub-plan is an ordinary
// operator tree, so a sequence, an inverse, or another repeat inside one
// costs no case of its own. `((:p)*)*` over a clique answers every node
// once, which is also the flattest possible test that the inner repeat's
// own zero-length rule composes with the outer's.
@(test)
test_path_repeats_nest :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> . :a :p :b, :c . :b :p :a, :c . :c :p :a, :b .`,
		`PREFIX : <http://example/> SELECT ?x WHERE { :a ((:p)*)* ?x }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{`?x=<http://example/a>`, `?x=<http://example/b>`, `?x=<http://example/c>`},
	)

	sequence, sequence_ok := solutions(
		t,
		`@prefix : <http://example/> . :a :p1 :m . :m :p2 :b . :b :p1 :n . :n :p2 :c .`,
		`PREFIX : <http://example/> SELECT ?x WHERE { :a (:p1/:p2)+ ?x }`,
	)
	defer destroy_rows(&sequence)
	if !sequence_ok {
		return
	}
	expect_solutions(t, sequence, {`?x=<http://example/b>`, `?x=<http://example/c>`})
}

// An inverse step is the same traversal with the ends swapped, and a
// fixed object is answered by running it backwards rather than by
// enumerating the graph.
@(test)
test_path_inverse_and_backward_traversal :: proc(t: ^testing.T) {
	rows, ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :p+ :z }`)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{`?s=<http://example/a>`, `?s=<http://example/b>`, `?s=<http://example/c>`},
	)

	inverse, inverse_ok := solutions(t, DIAMOND, `PREFIX : <http://example/> SELECT ?s WHERE { :z ^:p+ ?s }`)
	defer destroy_rows(&inverse)
	if !inverse_ok {
		return
	}
	expect_solutions(
		t,
		inverse,
		{`?s=<http://example/a>`, `?s=<http://example/b>`, `?s=<http://example/c>`},
	)
}

// A negated property set with both forward and inverse members is the
// *union* of two one-directional sets, not one set applied in both
// directions: `!(:pd|^:pr)` keeps the :pr triple read forwards and the :pd
// triple read backwards.
@(test)
test_path_negated_property_set_splits_by_direction :: proc(t: ^testing.T) {
	NPS :: `@prefix : <http://example/> . :sd :pd :od . :sr :pr :or .`

	forward, forward_ok := solutions(t, NPS, `PREFIX : <http://example/> SELECT * WHERE { ?s !:pd ?o }`)
	defer destroy_rows(&forward)
	if !forward_ok {
		return
	}
	expect_solutions(t, forward, {`?o=<http://example/or> ?s=<http://example/sr>`})

	inverse, inverse_ok := solutions(t, NPS, `PREFIX : <http://example/> SELECT * WHERE { ?s !^:pr ?o }`)
	defer destroy_rows(&inverse)
	if !inverse_ok {
		return
	}
	expect_solutions(t, inverse, {`?o=<http://example/sd> ?s=<http://example/od>`})

	both, both_ok := solutions(t, NPS, `PREFIX : <http://example/> SELECT * WHERE { ?s !(:pd|^:pr) ?o }`)
	defer destroy_rows(&both)
	if !both_ok {
		return
	}
	expect_solutions(
		t,
		both,
		{
			`?o=<http://example/or> ?s=<http://example/sr>`,
			`?o=<http://example/sd> ?s=<http://example/od>`,
		},
	)
}

// The traversal is a queue and not a recursion, so a chain deeper than any
// stack could carry is an ordinary walk. Ten thousand links: a recursive
// ALP would have overflowed long before this returns.
@(test)
test_path_deep_chain_does_not_overflow :: proc(t: ^testing.T) {
	LINKS :: 10_000
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "@prefix : <http://example/> .\n")
	for i in 0 ..< LINKS {
		write_link(&b, i)
	}

	rows, ok := solutions(
		t,
		strings.to_string(b),
		`PREFIX : <http://example/> ASK { :n0 :p+ :n10000 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	// One solution binding nothing: both ends are ground, so the answer is
	// whether the end is reachable at all.
	testing.expectf(t, len(rows) == 1, "expected the far end to be reachable, got %v", rows)
}

@(private = "file")
write_link :: proc(b: ^strings.Builder, i: int) {
	strings.write_string(b, ":n")
	strings.write_int(b, i)
	strings.write_string(b, " :p :n")
	strings.write_int(b, i + 1)
	strings.write_string(b, " .\n")
}

// A path under GRAPH ?g runs once per graph and reports the graph it ran
// in — the path reads the active graph rather than binding it, so plan
// building has to enumerate the graphs above it.
@(test)
test_path_under_a_graph_variable :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "path-graph-var") {
		return
	}
	for source, i in ([2]string{`@prefix : <http://example/> . :a :p :b .`, `@prefix : <http://example/> . :a :p :c .`}) {
		label := rdf.IRI("http://example/g1") if i == 0 else rdf.IRI("http://example/g2")
		if !test_db_load(t, &d, source, label) {
			return
		}
	}

	rows, ok := solve_against(
		t,
		&d,
		`PREFIX : <http://example/> SELECT ?g ?t WHERE { GRAPH ?g { :a :p+ ?t } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_solutions(
		t,
		rows,
		{
			`?g=<http://example/g1> ?t=<http://example/b>`,
			`?g=<http://example/g2> ?t=<http://example/c>`,
		},
	)
}

// --- helpers --------------------------------------------------------

@(private = "file")
solutions :: proc(
	t: ^testing.T,
	source: string,
	query: string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	return test_solve_source(t, source, query, render_path_solution, loc)
}

@(private = "file")
solve_against :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	query: string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	return test_solve(t, d, query, render_path_solution, loc)
}

// render_path_solution writes one solution's bindings in variable-name
// order, so a slot number — an artefact of plan building — never reaches
// an assertion.
@(private = "file")
render_path_solution :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
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
		write_path_term(&b, query_term(q, row[slot]))
	}
	return strings.to_string(b)
}

@(private = "file")
write_path_term :: proc(b: ^strings.Builder, term: rdf.Term) {
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
		if v.language != "" {
			strings.write_byte(b, '@')
			strings.write_string(b, v.language)
			return
		}
		strings.write_string(b, "^^")
		XSD :: "http://www.w3.org/2001/XMLSchema#"
		if strings.has_prefix(string(v.datatype), XSD) {
			strings.write_string(b, "xsd:")
			strings.write_string(b, string(v.datatype)[len(XSD):])
			return
		}
		strings.write_byte(b, '<')
		strings.write_string(b, string(v.datatype))
		strings.write_byte(b, '>')
	case ^rdf.Triple:
		strings.write_string(b, "<<triple>>")
	case nil:
		strings.write_string(b, "UNBOUND")
	}
}

// expect_solutions compares as a multiset: the store guarantees nothing
// about the order it yields quads in, and a property path's answer order
// follows it.
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
