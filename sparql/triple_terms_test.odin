package sparql

// SPARQL 1.2 triple terms in evaluation (SPARQL-T-0018), asserted
// directly rather than only through the W3C suites.
//
// The suite is thorough and it is the verdict, but almost every one of
// its entries is written in the *reified triple* surface syntax, which
// desugars to a reifier blank node and an `rdf:reifies` triple. Reading
// it therefore teaches how the sugar unfolds rather than what a triple
// term does when it is matched, and the cases that decide the
// implementation — a ground term resolving to one dictionary ID, a
// non-ground one having to be taken apart again, a variable that occurs
// both inside a triple term and outside it — are never stated on their
// own. They are here.
//
// A triple term is rendered `<<( s p o )>>` so that a mismatch says
// which component is wrong; blank nodes print as their kind alone,
// because the label a store hands out is not something a test may pin.
//
// *(Moved into this package by SPARQL-T-0035, from `sparql/kvstore`.
// **Not one assertion changed**, which is the finding: odin-rdf-record
// stores a triple term as `0x07 | sID | pID | oID` where odin-rdf-store
// held it in a dictionary entry, and the engine takes one apart through
// `snapshot_triple_parts` — three ids out of the encoding — where it used
// to materialize the whole term and re-resolve each component. The cost
// moved and the behaviour did not.)*

import "core:strings"
import "core:testing"

import "rdf:rdf"
import "record:record"

// Triple terms in the object position, one of each shape the matching
// has to tell apart: ground, ground-with-a-nested-term, and terms that
// differ only in a component's datatype.
@(private = "file")
TERMS :: `@prefix : <http://example/> .
:s1 :p <<( :a :b :c )>> .
:s2 :p <<( :a :b "c" )>> .
:s3 :p <<( :a :b <<( :x :y :z )>> )>> .
:s4 :p <<( :a :b 1 )>> .
:s5 :p <<( :a :b 1.0 )>> .
:plain :p :c .
`

// A triple term written out in full is a term like any other: it
// resolves to one dictionary ID before the query runs, and the store
// probes for it. Nothing is decomposed, and a term the data does not
// contain matches nothing rather than erroring.
@(test)
test_tt_ground_pattern_is_one_term :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :p <<( :a :b :c )>> }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {`?s=<http://example/s1>`})

	absent, absent_ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :p <<( :a :b :nowhere )>> }`,
	)
	defer destroy_rows(&absent)
	if !absent_ok {
		return
	}
	expect_triple_rows(t, absent, {})
}

// A triple term with a variable in it cannot be one ID, so the position
// matches any triple term and the components are unified afterwards. A
// position holding something that is not a triple term at all — the
// `:plain :p :c` statement — is simply not a match.
@(test)
test_tt_variable_components_unify :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s ?o WHERE { ?s :p <<( :a :b ?o )>> } ORDER BY ?s`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(
		t,
		rows,
		{
			`?o=<http://example/c> ?s=<http://example/s1>`,
			`?o="c"^^xsd:string ?s=<http://example/s2>`,
			`?o=<<( <http://example/x> <http://example/y> <http://example/z> )>> ?s=<http://example/s3>`,
			`?o="1"^^xsd:integer ?s=<http://example/s4>`,
			`?o="1.0"^^xsd:decimal ?s=<http://example/s5>`,
		},
	)
}

// Nesting is the case the flat decomposition list exists for: the outer
// term's object is the inner term's own match, and a variable inside the
// inner one binds through both.
@(test)
test_tt_nested_pattern :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s ?z WHERE { ?s :p <<( :a :b <<( :x :y ?z )>> )>> }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {`?s=<http://example/s3> ?z=<http://example/z>`})
}

// **A ground *nested* term is still one term**, and resolving it is one
// probe: record's `snapshot_resolve` recurses into a triple term's
// components, so a component the store has never seen makes the whole
// term a miss one level down rather than a scan.
//
// This is the case that would find a recursion bug in `RECORD-I-0004`'s
// encoding: the inner term has to encode to the same bytes when it is
// written as data and when it is written in a query, at every depth.
@(test)
test_tt_ground_nested_pattern_is_one_term :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :p <<( :a :b <<( :x :y :z )>> )>> }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {`?s=<http://example/s3>`})

	// One component of the inner term changed, and the outer term is a
	// different term. Not an error, not a partial match: no solutions.
	absent, absent_ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :p <<( :a :b <<( :x :y :nowhere )>> )>> }`,
	)
	defer destroy_rows(&absent)
	if !absent_ok {
		return
	}
	expect_triple_rows(t, absent, {})
}

// **A triple term in the subject position evaluates, and evaluates to
// nothing.** RDF 1.2 admits one as an object and nowhere else, so no
// fact this store can hold carries one in S — but a *query* may still
// write the pattern, and the engine must answer it rather than refuse
// it.
//
// The initiative named this as a second-order risk against
// `RECORD-I-0004` §4, which weighed restricting triple terms to the
// object position: if record had taken that route, the refusal had to be
// on the write path only. It did not restrict them — `0x07` is permitted
// in every position — so this holds for the simpler reason that the
// pattern is well-formed and matches no fact. Either way the engine's
// obligation is the same and it is asserted here.
@(test)
test_tt_in_the_subject_position_matches_nothing :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?p ?o WHERE { <<( :a :b :c )>> ?p ?o }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {})

	// And with a variable in it, so the pattern cannot collapse to a
	// single resolved term and the executor has to run the shape.
	shaped, shaped_ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?x ?p ?o WHERE { <<( :a :b ?x )>> ?p ?o }`,
	)
	defer destroy_rows(&shaped)
	if !shaped_ok {
		return
	}
	expect_triple_rows(t, shaped, {})
}

// A variable that occurs inside a triple term and outside it is one
// variable: the second occurrence sees what the first bound, whichever
// order the unification reaches them in.
@(test)
test_tt_variable_shared_with_the_enclosing_pattern :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		`@prefix : <http://example/> .
		 :a :self <<( :a :b :c )>> .
		 :d :self <<( :a :b :c )>> .`,
		`PREFIX : <http://example/>
		 SELECT ?s WHERE { ?s :self <<( ?s :b :c )>> }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {`?s=<http://example/a>`})
}

// The two equalities §17.4.1 keeps apart, over triple terms: sameTerm is
// the terms, `=` is the values, and a triple term's value is its
// components' values. `<<( :a :b 1 )>>` and `<<( :a :b 1.0 )>>` are one
// number written twice, so they are equal and not the same term.
@(test)
test_tt_equality_is_component_wise :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?a ?b WHERE {
		   :s4 :p ?a . :s5 :p ?b .
		   FILTER(?a = ?b)
		   FILTER(!sameTerm(?a, ?b))
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(
		t,
		rows,
		{
			`?a=<<( <http://example/a> <http://example/b> "1"^^xsd:integer )>> ` +
			`?b=<<( <http://example/a> <http://example/b> "1.0"^^xsd:decimal )>>`,
		},
	)
}

// A triple term in a VALUES block is data: ground by the grammar, bound
// as written, and — like any other cell — perfectly good even when the
// store has never seen it, in which case it joins with nothing.
@(test)
test_tt_in_a_values_block :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?s ?o WHERE {
		   VALUES ?o { <<( :a :b :c )>> <<( :a :b :nowhere )>> }
		   ?s :p ?o
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(t, rows, {`?o=<<( <http://example/a> <http://example/b> <http://example/c> )>> ?s=<http://example/s1>`})
}

// `<<( … )>>` written as an expression is TRIPLE(s, p, o) in surface
// syntax: it builds a term out of what its components evaluate to, and
// refuses the same things — RDF 1.2 admits a triple term as an object
// and nowhere else, so one in the subject position is an error and the
// BIND binds nothing.
@(test)
test_tt_as_an_expression :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?built WHERE {
		   :s1 :p ?o
		   BIND(<<( :a :b ?o )>> AS ?built)
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(
		t,
		rows,
		{`?built=<<( <http://example/a> <http://example/b> <<( <http://example/a> <http://example/b> <http://example/c> )>> )>>`},
	)

	refused, refused_ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?built WHERE {
		   :s1 :p ?o
		   BIND(<<( ?o :b :c )>> AS ?built)
		 }`,
	)
	defer destroy_rows(&refused)
	if !refused_ok {
		return
	}
	expect_triple_rows(t, refused, {``})
}

// The accessors of §18.5's 1.2 additions, over a term read from the
// store rather than one the query built.
@(test)
test_tt_accessors_over_a_stored_term :: proc(t: ^testing.T) {
	rows, ok := triple_solutions(
		t,
		TERMS,
		`PREFIX : <http://example/>
		 SELECT ?is ?sub ?pred ?obj WHERE {
		   :s1 :p ?o
		   BIND(isTRIPLE(?o) AS ?is)
		   BIND(SUBJECT(?o) AS ?sub)
		   BIND(PREDICATE(?o) AS ?pred)
		   BIND(OBJECT(?o) AS ?obj)
		 }`,
	)
	defer destroy_rows(&rows)
	if !ok {
		return
	}
	expect_triple_rows(
		t,
		rows,
		{
			`?is="true"^^xsd:boolean ?obj=<http://example/c> ` +
			`?pred=<http://example/b> ?sub=<http://example/a>`,
		},
	)
}

// --- helpers --------------------------------------------------------

@(private = "file")
triple_solutions :: proc(
	t: ^testing.T,
	source: string,
	query: string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	return test_solve_source(t, source, query, render_triple_solution, loc)
}

// render_triple_solution spells a solution in variable-name order — a
// slot's number is an artefact of plan building, and a test that
// depended on it would break for reasons that are not about SPARQL.
@(private = "file")
render_triple_solution :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
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
		write_triple_term(&b, query_term(q, row[slot]))
	}
	return strings.to_string(b)
}

@(private = "file")
write_triple_term :: proc(b: ^strings.Builder, term: rdf.Term) {
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
		strings.write_string(b, "<<( ")
		write_triple_term(b, v.subject)
		strings.write_byte(b, ' ')
		write_triple_term(b, v.predicate)
		strings.write_byte(b, ' ')
		write_triple_term(b, v.object)
		strings.write_string(b, " )>>")
	case nil:
		strings.write_string(b, "UNBOUND")
	}
}

@(private = "file")
expect_triple_rows :: proc(t: ^testing.T, rows: [dynamic]string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(rows) == len(want), "got %d solutions, want %d: %v", len(rows), len(want), rows, loc = loc) {
		return
	}
	for expected, i in want {
		testing.expectf(t, rows[i] == expected, "solution %d:\n got  %q\n want %q", i, rows[i], expected, loc = loc)
	}
}
