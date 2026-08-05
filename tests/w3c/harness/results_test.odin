package w3c

import "core:testing"

import rdf "rdf:rdf"

// Comparison is the harness's verdict machine: every evaluation test in
// this initiative passes or fails on it, so its own behaviour is pinned
// here rather than inferred from suites passing. The properties that
// matter are that it is insensitive to what the spec says is
// insensitive (solution order, blank-node identity, unbound variables in
// the header) and strict about everything else (multiplicity, blank-node
// structure, order where a query asked for one).

@(private = "file")
bindings :: proc(vars: []string, rows: [][]rdf.Term) -> (rs: Result_Set) {
	rs.kind = .Bindings
	for v in vars {
		result_set_var(&rs, v)
	}
	for row in rows {
		at := result_set_add_row(&rs)
		for term, i in row {
			if term == nil {
				continue
			}
			result_set_bind(&rs, at, vars[i], term)
		}
	}
	return rs
}

@(test)
test_comparison_ignores_solution_order :: proc(t: ^testing.T) {
	a := bindings({"x"}, {{rdf.IRI("http://example/1")}, {rdf.IRI("http://example/2")}})
	defer result_set_destroy(&a)
	b := bindings({"x"}, {{rdf.IRI("http://example/2")}, {rdf.IRI("http://example/1")}})
	defer result_set_destroy(&b)

	equal, reason := results_equal(&a, &b)
	testing.expectf(t, equal, "reordered solutions should compare equal: %s", reason)

	// …unless the query asked for an order, in which case position is
	// part of the answer.
	ordered_equal, _ := results_equal(&a, &b, Compare_Options{ordered = true})
	testing.expect(t, !ordered_equal, "reordered solutions must differ under an ordered comparison")
}

@(test)
test_comparison_rejects_wrong_multiplicity :: proc(t: ^testing.T) {
	one := bindings({"x"}, {{rdf.IRI("http://example/1")}})
	defer result_set_destroy(&one)
	twice := bindings({"x"}, {{rdf.IRI("http://example/1")}, {rdf.IRI("http://example/1")}})
	defer result_set_destroy(&twice)

	equal, _ := results_equal(&one, &twice)
	testing.expect(t, !equal, "a duplicated solution is a different multiset")

	// mf:LaxCardinality — the REDUCED tests — is exactly the exemption.
	lax_equal, reason := results_equal(&one, &twice, Compare_Options{lax_cardinality = true})
	testing.expectf(t, lax_equal, "lax cardinality should ignore multiplicity: %s", reason)
}

@(test)
test_comparison_accepts_blank_node_renaming :: proc(t: ^testing.T) {
	a := bindings(
		{"x", "y"},
		{{rdf.Blank_Node("a1"), rdf.Blank_Node("a2")}, {rdf.Blank_Node("a2"), rdf.Blank_Node("a1")}},
	)
	defer result_set_destroy(&a)
	b := bindings(
		{"x", "y"},
		{{rdf.Blank_Node("z9"), rdf.Blank_Node("z8")}, {rdf.Blank_Node("z8"), rdf.Blank_Node("z9")}},
	)
	defer result_set_destroy(&b)

	equal, reason := results_equal(&a, &b)
	testing.expectf(t, equal, "consistently renamed blank nodes should compare equal: %s", reason)
}

@(test)
test_comparison_rejects_blank_node_collapse :: proc(t: ^testing.T) {
	// Two distinct blank nodes cannot map onto one: that is the
	// difference between a bijection and "ignore blank nodes", and it is
	// what makes bnode-coreference tests mean anything.
	distinct_pair := bindings({"x", "y"}, {{rdf.Blank_Node("a1"), rdf.Blank_Node("a2")}})
	defer result_set_destroy(&distinct_pair)
	same_twice := bindings({"x", "y"}, {{rdf.Blank_Node("z1"), rdf.Blank_Node("z1")}})
	defer result_set_destroy(&same_twice)

	equal, _ := results_equal(&distinct_pair, &same_twice)
	testing.expect(t, !equal, "distinct blank nodes must not collapse onto one")
}

@(test)
test_comparison_treats_unbound_as_absent :: proc(t: ^testing.T) {
	// A variable in the header that nothing binds is not a difference —
	// a solution is a partial function, so the answer is the same either
	// way. An actually-bound variable, of course, is.
	with_header := bindings({"x", "unused"}, {{rdf.IRI("http://example/1"), nil}})
	defer result_set_destroy(&with_header)
	without_header := bindings({"x"}, {{rdf.IRI("http://example/1")}})
	defer result_set_destroy(&without_header)

	equal, reason := results_equal(&with_header, &without_header)
	testing.expectf(t, equal, "an unbound header variable is not a difference: %s", reason)

	bound := bindings({"x", "unused"}, {{rdf.IRI("http://example/1"), rdf.IRI("http://example/2")}})
	defer result_set_destroy(&bound)
	extra_equal, _ := results_equal(&bound, &without_header)
	testing.expect(t, !extra_equal, "an extra binding is a difference")
}

@(test)
test_comparison_distinguishes_literal_forms :: proc(t: ^testing.T) {
	plain := bindings({"x"}, {{rdf.literal_plain("1")}})
	defer result_set_destroy(&plain)
	typed := bindings({"x"}, {{rdf.literal_typed("1", rdf.XSD_INTEGER)}})
	defer result_set_destroy(&typed)
	tagged := bindings({"x"}, {{rdf.literal_lang("1", "en")}})
	defer result_set_destroy(&tagged)

	// Comparison is on RDF terms, not on values: "1" and "1"^^xsd:integer
	// are different terms even though they compare equal under SPARQL's
	// value semantics. Tests that mean value equality say so in the query.
	equal_typed, _ := results_equal(&plain, &typed)
	testing.expect(t, !equal_typed, "a plain and a typed literal are different terms")
	equal_tagged, _ := results_equal(&plain, &tagged)
	testing.expect(t, !equal_tagged, "a plain and a language-tagged literal are different terms")
}

@(test)
test_boolean_and_kind_mismatch :: proc(t: ^testing.T) {
	yes := Result_Set {
		kind    = .Boolean,
		boolean = true,
	}
	no := Result_Set {
		kind    = .Boolean,
		boolean = false,
	}
	equal, _ := results_equal(&yes, &no)
	testing.expect(t, !equal, "true and false are different answers")
	same, reason := results_equal(&yes, &yes)
	testing.expectf(t, same, "an ASK answer equals itself: %s", reason)

	rows := bindings({"x"}, {})
	defer result_set_destroy(&rows)
	kind_equal, _ := results_equal(&rows, &yes)
	testing.expect(t, !kind_equal, "a solution sequence is not a boolean answer")
}

@(test)
test_graph_isomorphism :: proc(t: ^testing.T) {
	// The CONSTRUCT/DESCRIBE side of the same bijection requirement.
	p := rdf.IRI("http://example/p")
	a := Result_Set {
		kind = .Graph,
	}
	defer result_set_destroy(&a)
	result_set_add_triple(&a, rdf.Triple{rdf.Blank_Node("b1"), p, rdf.IRI("http://example/o")})
	result_set_add_triple(&a, rdf.Triple{rdf.IRI("http://example/s"), p, rdf.Blank_Node("b1")})

	b := Result_Set {
		kind = .Graph,
	}
	defer result_set_destroy(&b)
	result_set_add_triple(&b, rdf.Triple{rdf.IRI("http://example/s"), p, rdf.Blank_Node("x9")})
	result_set_add_triple(&b, rdf.Triple{rdf.Blank_Node("x9"), p, rdf.IRI("http://example/o")})

	equal, reason := results_equal(&a, &b)
	testing.expectf(t, equal, "isomorphic graphs should compare equal: %s", reason)

	c := Result_Set {
		kind = .Graph,
	}
	defer result_set_destroy(&c)
	result_set_add_triple(&c, rdf.Triple{rdf.IRI("http://example/s"), p, rdf.Blank_Node("x9")})
	result_set_add_triple(&c, rdf.Triple{rdf.Blank_Node("x8"), p, rdf.IRI("http://example/o")})

	split_equal, _ := results_equal(&a, &c)
	testing.expect(t, !split_equal, "splitting a shared blank node changes the graph")
}

@(test)
test_triple_terms_compare_structurally :: proc(t: ^testing.T) {
	// SPARQL 1.2 triple terms are terms, so they take part in the same
	// bijection: two triple terms match when their components do.
	inner_a := rdf.Triple {
		subject   = rdf.Blank_Node("b1"),
		predicate = rdf.IRI("http://example/p"),
		object    = rdf.IRI("http://example/o"),
	}
	inner_b := rdf.Triple {
		subject   = rdf.Blank_Node("z1"),
		predicate = rdf.IRI("http://example/p"),
		object    = rdf.IRI("http://example/o"),
	}
	inner_c := rdf.Triple {
		subject   = rdf.Blank_Node("z1"),
		predicate = rdf.IRI("http://example/p"),
		object    = rdf.IRI("http://example/other"),
	}
	a := bindings({"x"}, {{&inner_a}})
	defer result_set_destroy(&a)
	b := bindings({"x"}, {{&inner_b}})
	defer result_set_destroy(&b)
	c := bindings({"x"}, {{&inner_c}})
	defer result_set_destroy(&c)

	equal, reason := results_equal(&a, &b)
	testing.expectf(t, equal, "triple terms equal up to blank-node renaming: %s", reason)
	unequal, _ := results_equal(&a, &c)
	testing.expect(t, !unequal, "a differing component makes triple terms differ")
}

// The readers are tested against the whole vendored corpus in
// readers_test.odin; these pin the term forms specifically, where a
// wrong datatype or a dropped language tag would otherwise show up only
// as a puzzling failure in some later suite.

@(test)
test_srx_reader_term_forms :: proc(t: ^testing.T) {
	source := `<?xml version="1.0"?>
<sparql xmlns="http://www.w3.org/2005/sparql-results#">
  <head><variable name="i"/><variable name="b"/><variable name="p"/><variable name="d"/><variable name="l"/></head>
  <results>
    <result>
      <binding name="i"><uri>http://example/s</uri></binding>
      <binding name="b"><bnode>r2</bnode></binding>
      <binding name="p"><literal>a &amp; b &lt;c&gt;</literal></binding>
      <binding name="d"><literal datatype="http://www.w3.org/2001/XMLSchema#integer">42</literal></binding>
      <binding name="l"><literal xml:lang="en">hello</literal></binding>
    </result>
  </results>
</sparql>`
	rs, ok := read_srx(source)
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)

	testing.expect(t, rs.kind == .Bindings, "a results document is a solution sequence")
	testing.expectf(t, len(rs.rows) == 1, "expected one solution, got %d", len(rs.rows))
	testing.expect(t, rdf.equal_term(rs.rows[0][0], rdf.IRI("http://example/s")), "uri")
	testing.expect(t, rdf.equal_term(rs.rows[0][1], rdf.Blank_Node("r2")), "bnode")
	testing.expect(t, rdf.equal_term(rs.rows[0][2], rdf.literal_plain("a & b <c>")), "entities decoded")
	testing.expect(t, rdf.equal_term(rs.rows[0][3], rdf.literal_typed("42", rdf.XSD_INTEGER)), "datatype")
	testing.expect(t, rdf.equal_term(rs.rows[0][4], rdf.literal_lang("hello", "en")), "language tag")
}

@(test)
test_srx_reader_boolean :: proc(t: ^testing.T) {
	rs, ok := read_srx(
		`<?xml version="1.0"?>
<sparql xmlns="http://www.w3.org/2005/sparql-results#"><head/><boolean>true</boolean></sparql>`,
	)
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)
	testing.expect(t, rs.kind == .Boolean && rs.boolean, "an ASK answer of true")
}

@(test)
test_srj_reader_term_forms :: proc(t: ^testing.T) {
	source := `{
	  "head": { "vars": [ "i", "d", "l", "b" ] },
	  "results": { "bindings": [ {
	    "i": { "type": "uri", "value": "http://example/s" },
	    "d": { "type": "literal", "datatype": "http://www.w3.org/2001/XMLSchema#integer", "value": "7" },
	    "l": { "type": "literal", "xml:lang": "fr", "value": "bonjour" },
	    "b": { "type": "bnode", "value": "r1" }
	  } ] }
	}`
	rs, ok := read_srj(transmute([]byte)source)
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)

	testing.expectf(t, len(rs.rows) == 1, "expected one solution, got %d", len(rs.rows))
	testing.expect(t, rdf.equal_term(rs.rows[0][0], rdf.IRI("http://example/s")), "uri")
	testing.expect(t, rdf.equal_term(rs.rows[0][1], rdf.literal_typed("7", rdf.XSD_INTEGER)), "datatype")
	testing.expect(t, rdf.equal_term(rs.rows[0][2], rdf.literal_lang("bonjour", "fr")), "language tag")
	testing.expect(t, rdf.equal_term(rs.rows[0][3], rdf.Blank_Node("r1")), "bnode")
}

@(test)
test_result_set_vocabulary_in_turtle :: proc(t: ^testing.T) {
	source := `@prefix rs: <http://www.w3.org/2001/sw/DataAccess/tests/result-set#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix : <http://example/> .
[] rdf:type rs:ResultSet ;
   rs:resultVariable "x" ;
   rs:solution [ rs:index 2 ; rs:binding [ rs:variable "x" ; rs:value :second ] ] ;
   rs:solution [ rs:index 1 ; rs:binding [ rs:variable "x" ; rs:value :first ] ] .`
	rs, ok := read_result_turtle(source, "http://example/base")
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)

	testing.expect(t, rs.kind == .Bindings, "an rs:ResultSet is a solution sequence")
	testing.expectf(t, len(rs.rows) == 2, "expected two solutions, got %d", len(rs.rows))
	// rs:index states the order the answer must come back in, so the
	// reader sorts by it — otherwise every ORDER BY test would depend on
	// the order the Turtle happened to list its solutions in.
	testing.expect(t, rdf.equal_term(rs.rows[0][0], rdf.IRI("http://example/first")), "sorted by rs:index")
	testing.expect(t, rdf.equal_term(rs.rows[1][0], rdf.IRI("http://example/second")), "sorted by rs:index")
}

@(test)
test_plain_graph_expectation :: proc(t: ^testing.T) {
	// A Turtle expectation with no rs:ResultSet is a CONSTRUCT answer.
	rs, ok := read_result_turtle(`@prefix : <http://example/> . :s :p :o , :o2 .`, "http://example/base")
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)
	testing.expect(t, rs.kind == .Graph, "a plain graph is a graph expectation")
	testing.expectf(t, len(rs.graph) == 2, "expected two triples, got %d", len(rs.graph))
}

@(test)
test_result_set_vocabulary_in_rdfxml :: proc(t: ^testing.T) {
	source := `<?xml version="1.0"?>
<rdf:RDF xmlns:rs="http://www.w3.org/2001/sw/DataAccess/tests/result-set#"
         xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rs:ResultSet>
    <rs:resultVariable>name</rs:resultVariable>
    <rs:solution rdf:parseType="Resource">
      <rs:index rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">2</rs:index>
      <rs:binding rdf:parseType="Resource">
        <rs:variable>name</rs:variable>
        <rs:value rdf:resource="http://example/second"/>
      </rs:binding>
    </rs:solution>
    <rs:solution rdf:parseType="Resource">
      <rs:index rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">1</rs:index>
      <rs:binding rdf:parseType="Resource">
        <rs:variable>name</rs:variable>
        <rs:value>Alice</rs:value>
      </rs:binding>
    </rs:solution>
  </rs:ResultSet>
</rdf:RDF>`
	rs, ok := read_result_rdfxml(source)
	testing.expect(t, ok, "the document should read")
	defer result_set_destroy(&rs)

	testing.expectf(t, len(rs.rows) == 2, "expected two solutions, got %d", len(rs.rows))
	testing.expect(t, rdf.equal_term(rs.rows[0][0], rdf.literal_plain("Alice")), "sorted by rs:index; literal value")
	testing.expect(t, rdf.equal_term(rs.rows[1][0], rdf.IRI("http://example/second")), "rdf:resource is an IRI")
}
