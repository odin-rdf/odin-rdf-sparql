package sparql

import "core:testing"

// The corpus asserts full parse→translate→SSE pipelines. The shapes
// follow the spec's own §18.2 worked examples plus one case per
// operator; the notation is ARQ's (see algebra_test.odin for the
// provenance note).

@(private = "file")
expect_translation :: proc(t: ^testing.T, src: string, want: string, loc := #caller_location) {
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	_, parse_ok := parse(&p)
	if !testing.expectf(
		t,
		parse_ok,
		"parse failed: %s at %d:%d",
		error_message(p.err.kind),
		p.err.line,
		p.err.column,
		loc = loc,
	) {
		return
	}
	a, translate_ok := translate(&p)
	if !testing.expect(t, translate_ok, "translate failed", loc = loc) {
		return
	}
	got := algebra_to_string(a)
	defer delete(got)
	testing.expectf(t, got == want, "algebra mismatch:\n--- got ---\n%s--- want ---\n%s", got, want, loc = loc)
}

@(test)
test_translate_bgp_and_project :: proc(t: ^testing.T) {
	// §18.2.4.4: the simplification step leaves a bare BGP under the
	// projection; SELECT * drops the identity projection.
	expect_translation(
		t,
		"SELECT ?s { ?s <urn:p> ?o . ?o <urn:q> ?z }",
		"(project (?s)\n" +
		"  (bgp (triple ?s <urn:p> ?o) (triple ?o <urn:q> ?z)))\n",
	)
	expect_translation(t, "SELECT * { ?s <urn:p> ?o }", "(bgp (triple ?s <urn:p> ?o))\n")
	expect_translation(t, "ASK { }", "(table unit)\n")
}

@(test)
test_translate_filter_placement :: proc(t: ^testing.T) {
	// §18.2.2.2: filters collect over the whole group regardless of
	// position.
	expect_translation(
		t,
		"SELECT * { FILTER(?o > 1) ?s <urn:p> ?o . ?s <urn:q> ?w }",
		"(filter (> ?o 1)\n" +
		"  (bgp (triple ?s <urn:p> ?o) (triple ?s <urn:q> ?w)))\n",
	)
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o FILTER(?o > 1) FILTER(?o < 5) }",
		"(filter (exprlist (> ?o 1) (< ?o 5))\n" +
		"  (bgp (triple ?s <urn:p> ?o)))\n",
	)
}

@(test)
test_translate_optional :: proc(t: ^testing.T) {
	// §18.2.2.6 with the inner filter hoisted onto the LeftJoin.
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o OPTIONAL { ?s <urn:m> ?m FILTER(?m != 0) } }",
		"(leftjoin\n" +
		"  (bgp (triple ?s <urn:p> ?o))\n" +
		"  (bgp (triple ?s <urn:m> ?m))\n" +
		"  (!= ?m 0))\n",
	)
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o OPTIONAL { ?s <urn:m> ?m } }",
		"(leftjoin\n" +
		"  (bgp (triple ?s <urn:p> ?o))\n" +
		"  (bgp (triple ?s <urn:m> ?m)))\n",
	)
}

@(test)
test_translate_union_join_graph_minus :: proc(t: ^testing.T) {
	expect_translation(
		t,
		"SELECT * { { ?a <urn:p> ?b } UNION { ?a <urn:q> ?b } UNION { ?a <urn:r> ?b } }",
		"(union\n" +
		"  (union\n" +
		"    (bgp (triple ?a <urn:p> ?b))\n" +
		"    (bgp (triple ?a <urn:q> ?b)))\n" +
		"  (bgp (triple ?a <urn:r> ?b)))\n",
	)
	expect_translation(
		t,
		"SELECT * { { ?a <urn:p> ?b } { ?b <urn:q> ?c } }",
		"(join\n" +
		"  (bgp (triple ?a <urn:p> ?b))\n" +
		"  (bgp (triple ?b <urn:q> ?c)))\n",
	)
	expect_translation(
		t,
		"SELECT * { GRAPH ?g { ?s <urn:p> ?o } }",
		"(graph ?g\n" +
		"  (bgp (triple ?s <urn:p> ?o)))\n",
	)
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o MINUS { ?s <urn:p> 1 } }",
		"(minus\n" +
		"  (bgp (triple ?s <urn:p> ?o))\n" +
		"  (bgp (triple ?s <urn:p> 1)))\n",
	)
}

@(test)
test_translate_bind_and_values :: proc(t: ^testing.T) {
	// BIND extends the accumulated pattern; triples after it join in.
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o BIND(?o + 1 AS ?n) ?s <urn:q> ?w }",
		"(join\n" +
		"  (extend ((?n (+ ?o 1)))\n" +
		"    (bgp (triple ?s <urn:p> ?o)))\n" +
		"  (bgp (triple ?s <urn:q> ?w)))\n",
	)
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?x VALUES ?x { 1 2 } }",
		"(join\n" +
		"  (bgp (triple ?s <urn:p> ?x))\n" +
		"  (table (vars ?x)\n" +
		"    (row [?x 1])\n" +
		"    (row [?x 2])))\n",
	)
	// The trailing VALUES clause joins after grouping/HAVING.
	expect_translation(
		t,
		"SELECT ?s { ?s <urn:p> ?x } VALUES ?s { <urn:a> }",
		"(project (?s)\n" +
		"  (join\n" +
		"    (bgp (triple ?s <urn:p> ?x))\n" +
		"    (table (vars ?s)\n" +
		"      (row [?s <urn:a>]))))\n",
	)
}

@(test)
test_translate_aggregation :: proc(t: ^testing.T) {
	// §18.2.4: group → having-filter → extend → project layering, with
	// aggregate substitution introducing ?.0/?.1.
	expect_translation(
		t,
		"SELECT ?s (COUNT(?v) AS ?n) { ?s <urn:p> ?v } GROUP BY ?s HAVING(SUM(?v) > 10) ORDER BY DESC(?n) LIMIT 3",
		"(slice _ 3\n" +
		"  (project (?s ?n)\n" +
		"    (order ((desc ?n))\n" +
		"      (extend ((?n ?.0))\n" +
		"        (filter (> ?.1 10)\n" +
		"          (group (?s) ((?.0 (count ?v)) (?.1 (sum ?v)))\n" +
		"            (bgp (triple ?s <urn:p> ?v))))))))\n",
	)
	// Implicit grouping: an aggregate with no GROUP BY groups over
	// everything.
	expect_translation(
		t,
		"SELECT (COUNT(*) AS ?n) { ?s <urn:p> ?o }",
		"(project (?n)\n" +
		"  (extend ((?n ?.0))\n" +
		"    (group () ((?.0 (count)))\n" +
		"      (bgp (triple ?s <urn:p> ?o)))))\n",
	)
}

@(test)
test_translate_subselect_and_modifiers :: proc(t: ^testing.T) {
	expect_translation(
		t,
		"SELECT DISTINCT ?s { ?s <urn:p> ?o { SELECT ?o { ?o <urn:q> ?z } LIMIT 2 } } OFFSET 5",
		"(slice 5 _\n" +
		"  (distinct\n" +
		"    (project (?s)\n" +
		"      (join\n" +
		"        (bgp (triple ?s <urn:p> ?o))\n" +
		"        (slice _ 2\n" +
		"          (project (?o)\n" +
		"            (bgp (triple ?o <urn:q> ?z))))))))\n",
	)
}

@(test)
test_translate_paths :: proc(t: ^testing.T) {
	// §18.4: sequences decompose with fresh variables; inverses swap
	// endpoints; link paths were already plain triples.
	expect_translation(
		t,
		"SELECT * { ?s <urn:p>/<urn:q> ?o }",
		"(join\n" +
		"  (bgp (triple ?s <urn:p> ?.p0))\n" +
		"  (bgp (triple ?.p0 <urn:q> ?o)))\n",
	)
	expect_translation(t, "SELECT * { ?s ^<urn:p> ?o }", "(bgp (triple ?o <urn:p> ?s))\n")
	// Inverse distributes into sequences: ^(p/q) reverses the chain.
	expect_translation(
		t,
		"SELECT * { ?s ^(<urn:p>/<urn:q>) ?o }",
		"(join\n" +
		"  (bgp (triple ?o <urn:p> ?.p0))\n" +
		"  (bgp (triple ?.p0 <urn:q> ?s)))\n",
	)
	// The remaining operators stay Path() algebra.
	expect_translation(
		t,
		"SELECT * { ?s <urn:p>* ?o . ?s !(<urn:a>|^<urn:b>) ?x }",
		"(join\n" +
		"  (path ?s (path* <urn:p>) ?o)\n" +
		"  (path ?s (notoneof <urn:a> (reverse <urn:b>)) ?x))\n",
	)
	// Mixed simple and path predicates keep block order.
	expect_translation(
		t,
		"SELECT * { ?s <urn:a> ?x . ?s <urn:p>+ ?o . ?o <urn:b> ?y }",
		"(join\n" +
		"  (join\n" +
		"    (bgp (triple ?s <urn:a> ?x))\n" +
		"    (path ?s (path+ <urn:p>) ?o))\n" +
		"  (bgp (triple ?o <urn:b> ?y)))\n",
	)
}

@(test)
test_translate_exists_and_construct :: proc(t: ^testing.T) {
	expect_translation(
		t,
		"SELECT * { ?s <urn:p> ?o FILTER EXISTS { ?s <urn:q> ?o } }",
		"(filter (exists (bgp (triple ?s <urn:q> ?o)))\n" +
		"  (bgp (triple ?s <urn:p> ?o)))\n",
	)
	// CONSTRUCT: the algebra is the WHERE pattern; the template stays
	// outside the algebra. The shorthand's template doubles as pattern.
	expect_translation(
		t,
		"CONSTRUCT { ?s <urn:label> ?o } WHERE { ?s <urn:p> ?o }",
		"(bgp (triple ?s <urn:p> ?o))\n",
	)
	expect_translation(t, "CONSTRUCT WHERE { ?s <urn:p> ?o }", "(bgp (triple ?s <urn:p> ?o))\n")
	expect_translation(t, "DESCRIBE <urn:thing>", "(table unit)\n")
}
