package sparql

import "core:testing"

import rdf "rdf:rdf"

@(test)
test_parse_triple_term_pattern :: proc(t: ^testing.T) {
	src := "PREFIX : <urn:x#> SELECT * { <<( ?s :p 1 )>> :author ?a }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp, _ := q.where_clause.elements[0].(^Basic_Pattern)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 1)
		tt, tt_ok := bp.triples[0].subject.(^Triple_Term)
		testing.expect(t, tt_ok)
		if tt_ok {
			_, s_ok := tt.subject.(Var)
			testing.expect(t, s_ok)
			lit, o_ok := tt.object.(rdf.Literal)
			testing.expect(t, o_ok)
			testing.expect_value(t, lit.datatype, rdf.XSD_INTEGER)
		}
	}
}

@(test)
test_parse_reified_triple_desugars :: proc(t: ^testing.T) {
	// << :a :b :c ~ :r >> :p :o desugars to
	//   :r rdf:reifies <<(:a :b :c)>> .  :r :p :o
	src := "PREFIX : <urn:x#> SELECT * { << :a :b :c ~ :r >> :p :o }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp, _ := q.where_clause.elements[0].(^Basic_Pattern)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 2)
		reifies, _ := bp.triples[0].predicate.(rdf.IRI)
		testing.expect_value(t, reifies, rdf.RDF_REIFIES)
		reifier, _ := bp.triples[0].subject.(rdf.IRI)
		testing.expect_value(t, string(reifier), "urn:x#r")
		_, tt_ok := bp.triples[0].object.(^Triple_Term)
		testing.expect(t, tt_ok)
		main_subject, _ := bp.triples[1].subject.(rdf.IRI)
		testing.expect_value(t, string(main_subject), "urn:x#r")
	}

	// An anonymous reifier gets a generated blank node; the bare
	// reified triple is a complete statement.
	src2 := "SELECT * { << ?s ?p ?o >> . }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	q2, ok2 := parse(&p2)
	testing.expect_value(t, p2.err.kind, Error_Kind.None)
	testing.expect(t, ok2)
	bp2, _ := q2.where_clause.elements[0].(^Basic_Pattern)
	if bp2 != nil {
		testing.expect_value(t, len(bp2.triples), 1)
		_, blank_ok := bp2.triples[0].subject.(rdf.Blank_Node)
		testing.expect(t, blank_ok)
	}
}

@(test)
test_parse_annotations :: proc(t: ^testing.T) {
	// ?s ?p ?o ~ :r {| :q 1 |} — the annotation attaches to :r.
	src := "PREFIX : <urn:x#> SELECT * { ?s ?p ?o ~ :r {| :q 1 |} }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp, _ := q.where_clause.elements[0].(^Basic_Pattern)
	testing.expect(t, bp != nil)
	if bp != nil {
		// ?s ?p ?o ; :r reifies <<(?s ?p ?o)>> ; :r :q 1
		testing.expect_value(t, len(bp.triples), 3)
		annotated, _ := bp.triples[2].subject.(rdf.IRI)
		testing.expect_value(t, string(annotated), "urn:x#r")
	}

	// A bare annotation block generates a fresh reifier.
	src2 := "PREFIX : <urn:x#> SELECT * { ?s ?p ?o {| :q 1 |} }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect_value(t, p2.err.kind, Error_Kind.None)
	testing.expect(t, ok2)
	bp2, _ := p2.query.where_clause.elements[0].(^Basic_Pattern)
	if bp2 != nil {
		testing.expect_value(t, len(bp2.triples), 3)
		_, blank_ok := bp2.triples[1].subject.(rdf.Blank_Node)
		testing.expect(t, blank_ok)
	}
}

@(test)
test_parse_version_decl :: proc(t: ^testing.T) {
	src := `VERSION "1.2" SELECT * { ?s ?p ?o }`
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, q.version, "1.2")

	// A long string is not a VersionDecl (sparql12 version-bad-01).
	src2 := `VERSION """1.2""" SELECT * { ?s ?p ?o }`
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect(t, !ok2)
	testing.expect_value(t, p2.err.kind, Error_Kind.Expected_Version_String)
}

@(test)
test_translate_triple_terms :: proc(t: ^testing.T) {
	// Triple terms flow through §18.2 into BGP triples.
	p: Parser
	src := "SELECT * { <<( ?s <urn:p> ?o )>> <urn:author> ?a }"
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	_, parse_ok := parse(&p)
	testing.expect(t, parse_ok)
	a, translate_ok := translate(&p)
	testing.expect(t, translate_ok)
	got := algebra_to_string(a)
	defer delete(got)
	testing.expect_value(t, got, "(bgp (triple <<(?s <urn:p> ?o)>> <urn:author> ?a))\n")
}

@(test)
test_triple_term_restrictions :: proc(t: ^testing.T) {
	// Blank nodes are content in patterns but not in expressions.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("SELECT * { ?x ?y ?z BIND(<<( _:b <urn:p> 1 )>> AS ?t) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
	}
	// VALUES data must be ground.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("SELECT * { VALUES ?x { <<( ?s <urn:p> 1 )>> } }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Data_Value)
	}
	// NIL is not a triple-term constituent.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("SELECT * { <<( ?s <urn:p> ( ) )>> <urn:q> 1 }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
	}
}
