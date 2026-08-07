package sparql_kvstore

// The blocking operators' semantics (SPARQL-T-0015), asserted directly
// rather than only through the W3C suites.
//
// The suites are the verdict, but they are a poor place to *learn* that
// SUM is poisoned by an unbound value while COUNT is not, or that a
// decimal total is exact while a double one is not. Each of those is a
// sentence of §18.5.1 or §15.1, and each gets a case here that says
// which sentence it is.
//
// Solutions are rendered in variable-name order, not slot order — a
// slot's number is an artefact of plan building, and a test that
// depended on it would break for reasons that are not about SPARQL.

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

@(private = "file")
GROUPS :: `@prefix : <http://example/> .
:x :p 1, 2, 3, 4 .
:y :p 1, "a", 3 .
:x :q 10 .
`

// §18.5.1.2 Count counts the values that were there; §18.5.1.4's Sum and
// §18.5.1.7's Avg are errors as soon as one was not. The two rules live
// in one query so the difference cannot be read as a coincidence.
@(test)
test_agg_count_survives_what_sum_does_not :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		GROUPS,
		`PREFIX : <http://example/>
		 SELECT (COUNT(?m) AS ?n) (SUM(?m) AS ?total) (COUNT(*) AS ?rows)
		 WHERE { ?s :p ?o OPTIONAL { ?s :q ?m } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	// Seven solutions reach the group; ?m is bound in the four that came
	// from :x. COUNT sees four, COUNT(*) sees seven, SUM sees an unbound
	// value and answers with nothing at all.
	expect_rows(t, rows, {`?n="4"^^xsd:integer ?rows="7"^^xsd:integer`})
}

// A non-numeric value is the other way an aggregate errors, and it is
// the one the DAWG's agg-err-01 is built on.
@(test)
test_agg_sum_of_a_non_number_is_unbound :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		GROUPS,
		`PREFIX : <http://example/>
		 SELECT ?s (COUNT(?o) AS ?n) (SUM(?o) AS ?total)
		 WHERE { ?s :p ?o } GROUP BY ?s ORDER BY ?s`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(
		t,
		rows,
		{
			`?n="4"^^xsd:integer ?s=<http://example/x> ?total="10"^^xsd:integer`,
			`?n="3"^^xsd:integer ?s=<http://example/y>`,
		},
	)
}

// §18.2.4.1's implicit grouping: an aggregate without GROUP BY has one
// group, and that group exists even when nothing reached it. COUNT and
// SUM answer for an empty group (0, and 0 as an integer whatever the
// values would have been); MIN and MAX have nothing to answer with.
@(test)
test_agg_implicit_group_answers_for_no_solutions :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		GROUPS,
		`PREFIX : <http://example/>
		 SELECT (COUNT(*) AS ?rows) (COUNT(?o) AS ?n) (SUM(?o) AS ?total) (AVG(?o) AS ?mean) (MAX(?o) AS ?high)
		 WHERE { ?s :absent ?o }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(
		t,
		rows,
		{`?mean="0"^^xsd:integer ?n="0"^^xsd:integer ?rows="0"^^xsd:integer ?total="0"^^xsd:integer`},
	)
}

// An *explicit* GROUP BY over no solutions has no groups, and so no
// answers — the difference from the implicit case is the whole of
// agg-empty-group-count-1 against agg-empty-group-count-2.
@(test)
test_agg_explicit_group_answers_nothing_for_no_solutions :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		GROUPS,
		`PREFIX : <http://example/>
		 SELECT (COUNT(*) AS ?rows) WHERE { ?s :absent ?o } GROUP BY ?s`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {})
}

// The exact-decimal accumulator, and the reason it exists: no order of
// f64 additions gives the double nearest 11.1 for these five values, so
// an engine that summed them as doubles would answer 11.100000000000001.
// The average divides exactly too, which is why it is 2.22 and not the
// f64 quotient.
@(test)
test_agg_decimal_total_is_exact :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		"",
		`SELECT (SUM(?o) AS ?total) (AVG(?o) AS ?mean)
		 WHERE { VALUES ?o { 1.0 2.2 3.5 2.2 2.2 } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?mean="2.22"^^xsd:decimal ?total="11.1"^^xsd:decimal`})
}

// A double anywhere in the group drops the total to floating point, and
// §17.3's tower says the answer is a double. AVG divides on the same
// rung.
@(test)
test_agg_double_total_promotes :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		"",
		`SELECT (SUM(?o) AS ?total) (AVG(?o) AS ?mean) WHERE { VALUES ?o { 1 2.5 5.0E-1 } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?mean="1.3333333333333333E+00"^^xsd:double ?total="4E+00"^^xsd:double`})
}

// §18.5.1.6's GroupConcat: a simple literal, whatever the parts were —
// including language-tagged ones, which contribute their lexical forms
// and not their tags. DISTINCT applies before the joining.
@(test)
test_agg_group_concat :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{`SELECT (GROUP_CONCAT(?o) AS ?g) WHERE { VALUES ?o { "a" "b" "c" } }`, `?g="a b c"^^xsd:string`},
		{
			`SELECT (GROUP_CONCAT(?o ; SEPARATOR = "-") AS ?g) WHERE { VALUES ?o { "a" "b" } }`,
			`?g="a-b"^^xsd:string`,
		},
		{
			`SELECT (GROUP_CONCAT(DISTINCT ?o) AS ?g) WHERE { VALUES ?o { "a" "b" "a" } }`,
			`?g="a b"^^xsd:string`,
		},
		{`SELECT (GROUP_CONCAT(?o) AS ?g) WHERE { VALUES ?o { "1"@en "2"@fr } }`, `?g="1 2"^^xsd:string`},
		{`SELECT (GROUP_CONCAT(?o) AS ?g) WHERE { VALUES ?o { } }`, `?g=""^^xsd:string`},
	}
	for one in cases {
		rows, ok := solutions(t, "", one[0])
		defer destroy_rows(&rows)
		if !ok {
			continue
		}
		expect_rows(t, rows, {one[1]})
	}
}

// DISTINCT over one expression counts values; DISTINCT over COUNT(*)
// counts whole solutions.
@(test)
test_agg_distinct_variants :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		"",
		`SELECT (COUNT(?a) AS ?n) (COUNT(DISTINCT ?a) AS ?values) (COUNT(DISTINCT *) AS ?rows)
		 WHERE { VALUES (?a ?b) { (1 "x") (1 "y") (1 "x") } }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	// Three solutions, one distinct value of ?a, two distinct solutions —
	// the third repeats the first exactly.
	expect_rows(t, rows, {`?n="3"^^xsd:integer ?rows="2"^^xsd:integer ?values="1"^^xsd:integer`})
}

// §18.5.1's Group partitions on the *terms* the key expressions evaluate
// to, not on their values. "1"^^xsd:integer and "1.0"^^xsd:decimal are
// the same number and two different groups, and an engine that used
// value equality here would answer with one.
@(test)
test_group_keys_are_terms_not_values :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		"",
		`SELECT ?o (COUNT(*) AS ?n) WHERE { VALUES ?o { 1 1.0 1 } } GROUP BY ?o ORDER BY STR(?o)`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(
		t,
		rows,
		{`?n="2"^^xsd:integer ?o="1"^^xsd:integer`, `?n="1"^^xsd:integer ?o="1.0"^^xsd:decimal`},
	)
}

// A grouping condition with AS binds its key; HAVING filters the groups
// that result.
@(test)
test_group_by_expression_and_having :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		GROUPS,
		`PREFIX : <http://example/>
		 SELECT ?kind (COUNT(*) AS ?n)
		 WHERE { ?s :p ?o }
		 GROUP BY (DATATYPE(?o) AS ?kind)
		 HAVING (COUNT(*) > 1)`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	// Six integers and one string; the string's group is filtered out.
	expect_rows(t, rows, {`?kind=<http://www.w3.org/2001/XMLSchema#integer> ?n="6"^^xsd:integer`})
}

// §15.1's ordering, extended to a total one: unbound lowest, then blank
// nodes, then IRIs, then literals. See order.odin for the whole of the
// extension and why it has to be stated.
@(test)
test_order_across_term_kinds :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> .
		 :t :p _:anon, :iri, "text" .`,
		`PREFIX : <http://example/>
		 SELECT ?o WHERE { { VALUES ?o { UNDEF } } UNION { :t :p ?o } } ORDER BY ?o`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {``, `?o=_:`, `?o=<http://example/iri>`, `?o="text"^^xsd:string`})
}

// Numbers order by value across the whole tower, and two spellings of
// the same number tie — at which point the sort's stability decides, and
// the input order survives.
@(test)
test_order_numbers_by_value :: proc(t: ^testing.T) {
	rows, ok := solutions(t, "", `SELECT ?o WHERE { VALUES ?o { 10 2.0 1.0E1 3 } } ORDER BY ?o`)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(
		t,
		rows,
		{`?o="2.0"^^xsd:decimal`, `?o="3"^^xsd:integer`, `?o="10"^^xsd:integer`, `?o="1.0E1"^^xsd:double`},
	)
}

// A sort key that raises a type error is not a filter: the solution
// stays, sorted with the unbound, in the order it arrived.
@(test)
test_order_key_error_sorts_with_the_unbound :: proc(t: ^testing.T) {
	rows, ok := solutions(t, "", `SELECT ?o WHERE { VALUES ?o { "b" 1 "a" } } ORDER BY (?o + 1)`)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?o="b"^^xsd:string`, `?o="a"^^xsd:string`, `?o="1"^^xsd:integer`})
}

// Multiple keys, each with its own direction, and the slice that §18.2.5
// layers on top of the sort rather than under it.
@(test)
test_order_multiple_keys_then_slice :: proc(t: ^testing.T) {
	source := `SELECT ?a ?b WHERE { VALUES (?a ?b) { (1 "y") (2 "x") (1 "x") (2 "y") } } ORDER BY DESC(?a) ?b`
	rows, ok := solutions(t, "", source)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(
		t,
		rows,
		{
			`?a="2"^^xsd:integer ?b="x"^^xsd:string`,
			`?a="2"^^xsd:integer ?b="y"^^xsd:string`,
			`?a="1"^^xsd:integer ?b="x"^^xsd:string`,
			`?a="1"^^xsd:integer ?b="y"^^xsd:string`,
		},
	)

	sliced, sliced_ok := solutions(t, "", strings.concatenate({source, " LIMIT 2 OFFSET 1"}, context.temp_allocator))
	defer destroy_rows(&sliced)
	if !sliced_ok {
		return
	}
	expect_rows(
		t,
		sliced,
		{`?a="2"^^xsd:integer ?b="y"^^xsd:string`, `?a="1"^^xsd:integer ?b="x"^^xsd:string`},
	)
}

// A sort may order by something the query does not project — the
// ordering happens under the projection, exactly as §18.2.5 stacks them.
@(test)
test_order_by_an_unprojected_variable :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> .
		 :s1 :p 3 . :s2 :p 1 . :s3 :p 2 .`,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :p ?o } ORDER BY ?o`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?s=<http://example/s2>`, `?s=<http://example/s3>`, `?s=<http://example/s1>`})
}

// A blocking operator hands out a whole row at a time, and a LIMIT above
// it can stop asking before it is finished. Neither is visible on its
// own; put them under a UNION and they are, because the right branch
// then starts on whatever the left one happened to leave in the row.
//
// Both branches here bind the same variable, so a left-over ?v would
// narrow the right branch's pattern to the value the left branch
// produced and the second solution would go missing. Found through
// sparql12-eval-triple-terms' `order-by`, which is twenty of these in a
// row; it is not a 1.2 question at all.
@(test)
test_union_branches_start_from_the_same_bindings :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> .
		 :s :p 1, 2 .`,
		`PREFIX : <http://example/>
		 SELECT ?v WHERE {
		   { SELECT ?v { ?s :p ?v } ORDER BY ?v LIMIT 1 }
		   UNION
		   { SELECT ?v { ?s :p ?v } ORDER BY ?v OFFSET 1 LIMIT 1 }
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?v="1"^^xsd:integer`, `?v="2"^^xsd:integer`})
}

// A subquery hands its consumer a *projected copy* of the row rather than
// the row itself, so a BIND above one has to write the binding into that
// copy as well — otherwise the value is computed, is visible to
// everything that probes, and is missing from the answer.
@(test)
test_bind_over_a_subquery_reaches_the_answer :: proc(t: ^testing.T) {
	rows, ok := solutions(
		t,
		`@prefix : <http://example/> .
		 :s :p 1 .`,
		`PREFIX : <http://example/>
		 SELECT * WHERE {
		   { SELECT ?v { ?s :p ?v } }
		   BIND("tag" AS ?label)
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_rows(t, rows, {`?label="tag"^^xsd:string ?v="1"^^xsd:integer`})
}

// --- helpers --------------------------------------------------------

// solutions evaluates a query against a freshly loaded store and renders
// each solution. An empty source is a query that needs no data, which
// the VALUES-driven cases above are.
@(private = "file")
solutions :: proc(t: ^testing.T, source: string, query: string, loc := #caller_location) -> (rows: [dynamic]string, ok: bool) {
	path := scratch_path("blocking")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err, loc = loc) {
		return nil, false
	}
	defer kvstore.close(s)
	if source != "" {
		_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)source, "http://example/")
		if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load: %s %v", parse_err.message, load_err, loc = loc) {
			return nil, false
		}
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)query, "http://example/")
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return nil, false
	}
	algebra, translated := sparql.translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return nil, false
	}

	q: Query
	if !query_init(&q, algebra, s, sparql.parser_base(&p)) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		query_destroy(&q)
		return nil, false
	}
	defer query_destroy(&q)

	names := query_var_names(&q)
	internal := query_var_internal(&q)
	rows = make([dynamic]string)
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		append(&rows, render_solution(&q, row, names, internal))
	}
	return rows, true
}

// render_solution writes one solution's bindings in variable-name order.
@(private = "file")
render_solution :: proc(q: ^Query, row: []store.Term_ID, names: []string, internal: []bool) -> string {
	order := make([dynamic]int, context.temp_allocator)
	for id, slot in row {
		if id == store.UNBOUND || internal[slot] {
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

// write_term spells a term the way the assertions above read: a blank
// node as its kind alone, because the label a store hands out is not
// something a test may pin.
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

@(private = "file")
expect_rows :: proc(t: ^testing.T, rows: [dynamic]string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(rows) == len(want), "got %d solutions, want %d: %v", len(rows), len(want), rows, loc = loc) {
		return
	}
	for expected, i in want {
		testing.expectf(t, rows[i] == expected, "solution %d: got %q, want %q", i, rows[i], expected, loc = loc)
	}
}

@(private = "file")
destroy_rows :: proc(rows: ^[dynamic]string) {
	for row in rows {
		delete(row)
	}
	delete(rows^)
}
