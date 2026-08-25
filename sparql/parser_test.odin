package sparql

import "core:testing"

import rdf "rdf:rdf"

@(private = "file")
first_bgp :: proc(q: ^Parsed_Query) -> ^Basic_Pattern {
	if q == nil || q.where_clause == nil || len(q.where_clause.elements) == 0 {
		return nil
	}
	bp, _ := q.where_clause.elements[0].(^Basic_Pattern)
	return bp
}

@(test)
test_parse_select_basic :: proc(t: ^testing.T) {
	src := "SELECT ?s WHERE { ?s ?p ?o }"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, q.form, Query_Form.Select)
	testing.expect_value(t, len(q.projection), 1)
	testing.expect_value(t, q.projection[0].v.name, "s")
	testing.expect_value(t, q.limit, -1)
	bp := first_bgp(q)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 1)
		s, s_ok := bp.triples[0].subject.(Var)
		testing.expect(t, s_ok)
		testing.expect_value(t, s.name, "s")
	}
}

@(test)
test_parse_select_star_distinct_and_ask :: proc(t: ^testing.T) {
	src := "SELECT DISTINCT * { ?s ?p ?o }"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect(t, ok)
	testing.expect(t, q.select_star)
	testing.expect_value(t, q.select_modifier, Select_Modifier.Distinct)

	src2 := "ASK { ?s ?p ?o }"
	p2: Parser
	parser_init(&p2, transmute([]byte)src2)
	defer parser_destroy(&p2)
	q2, ok2 := parse(&p2)
	testing.expect(t, ok2)
	testing.expect_value(t, q2.form, Query_Form.Ask)
}

@(test)
test_parse_prologue :: proc(t: ^testing.T) {
	src := `BASE <http://example.org/dir/>
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
PREFIX : <local#>
SELECT * { <rel> foaf:name :x }`
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp := first_bgp(q)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 1)
		s, _ := bp.triples[0].subject.(rdf.IRI)
		pred, _ := bp.triples[0].predicate.(rdf.IRI)
		o, _ := bp.triples[0].object.(rdf.IRI)
		testing.expect_value(t, string(s), "http://example.org/dir/rel")
		testing.expect_value(t, string(pred), "http://xmlns.com/foaf/0.1/name")
		// The ':' prefix was itself declared with a relative IRI.
		testing.expect_value(t, string(o), "http://example.org/dir/local#x")
	}
}

@(test)
test_parse_abbreviations :: proc(t: ^testing.T) {
	src := "PREFIX f: <urn:f#> SELECT * { ?s a f:Person ; f:knows ?x , ?y . }"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp := first_bgp(q)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 3)
		p0, _ := bp.triples[0].predicate.(rdf.IRI)
		testing.expect_value(t, p0, rdf.RDF_TYPE)
		p1, _ := bp.triples[1].predicate.(rdf.IRI)
		testing.expect_value(t, string(p1), "urn:f#knows")
		o2, o2_ok := bp.triples[2].object.(Var)
		testing.expect(t, o2_ok)
		testing.expect_value(t, o2.name, "y")
	}
}

@(test)
test_parse_collection_and_bnode_list :: proc(t: ^testing.T) {
	src := "SELECT * { ?s ?p (1 2) . [ ?q 3 ] ?r ?o }"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	_, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp := first_bgp(p.query)
	testing.expect(t, bp != nil)
	if bp != nil {
		// (1 2): first/rest/first/rest-nil = 4 triples + main + bnode
		// list's inner + outer = 7 total.
		testing.expect_value(t, len(bp.triples), 7)
		// The collection's head appears as the main triple's object.
		main := bp.triples[4]
		head, head_ok := main.object.(rdf.Blank_Node)
		testing.expect(t, head_ok)
		first := bp.triples[0]
		cell, cell_ok := first.subject.(rdf.Blank_Node)
		testing.expect(t, cell_ok)
		testing.expect_value(t, string(head), string(cell))
		// Chain terminates in rdf:nil.
		last_rest := bp.triples[3]
		nil_obj, nil_ok := last_rest.object.(rdf.IRI)
		testing.expect(t, nil_ok)
		testing.expect_value(t, nil_obj, rdf.RDF_NIL)
	}
}

@(test)
test_parse_group_nesting :: proc(t: ^testing.T) {
	src := "SELECT * { { ?a ?b ?c } UNION { ?d ?e ?f } OPTIONAL { ?g ?h ?i } GRAPH ?g { ?x ?y ?z } }"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.where_clause.elements), 3)
	if len(q.where_clause.elements) == 3 {
		u, u_ok := q.where_clause.elements[0].(^Union_Pattern)
		testing.expect(t, u_ok)
		if u_ok {
			testing.expect_value(t, len(u.alternatives), 2)
		}
		_, o_ok := q.where_clause.elements[1].(^Optional_Pattern)
		testing.expect(t, o_ok)
		g, g_ok := q.where_clause.elements[2].(^Graph_Pattern)
		testing.expect(t, g_ok)
		if g_ok {
			gv, gv_ok := g.graph.(Var)
			testing.expect(t, gv_ok)
			testing.expect_value(t, gv.name, "g")
		}
	}
}

@(test)
test_parse_literals :: proc(t: ^testing.T) {
	src := `PREFIX x: <urn:x#> SELECT * { ?s ?p "plain" , "hi"@en , "shalom"@he--rtl , "5"^^x:t , 4.2 , TRUE }`
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	_, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	bp := first_bgp(p.query)
	testing.expect(t, bp != nil)
	if bp != nil {
		testing.expect_value(t, len(bp.triples), 6)
		l0, _ := bp.triples[0].object.(rdf.Literal)
		testing.expect_value(t, l0.lexical, "plain")
		testing.expect_value(t, l0.datatype, rdf.XSD_STRING)
		l1, _ := bp.triples[1].object.(rdf.Literal)
		testing.expect_value(t, l1.language, "en")
		l2, _ := bp.triples[2].object.(rdf.Literal)
		testing.expect_value(t, l2.language, "he")
		testing.expect_value(t, l2.direction, rdf.Direction.RTL)
		l3, _ := bp.triples[3].object.(rdf.Literal)
		testing.expect_value(t, string(l3.datatype), "urn:x#t")
		l4, _ := bp.triples[4].object.(rdf.Literal)
		testing.expect_value(t, l4.datatype, rdf.XSD_DECIMAL)
		l5, _ := bp.triples[5].object.(rdf.Literal)
		testing.expect_value(t, l5.lexical, "true")
		testing.expect_value(t, l5.datatype, rdf.XSD_BOOLEAN)
	}
}

@(test)
test_parse_datasets_and_modifiers :: proc(t: ^testing.T) {
	src := "SELECT ?s FROM <urn:g1> FROM NAMED <urn:g2> WHERE { ?s ?p ?o } ORDER BY ?s DESC(?o) LIMIT 10 OFFSET 5"
	p: Parser
	parser_init(&p, transmute([]byte)src)
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.datasets), 2)
	testing.expect(t, !q.datasets[0].named)
	testing.expect(t, q.datasets[1].named)
	testing.expect_value(t, len(q.order), 2)
	testing.expect_value(t, q.order[0].direction, Order_Direction.Ascending)
	testing.expect_value(t, q.order[1].direction, Order_Direction.Descending)
	ov, ov_ok := q.order[1].expr.(Var)
	testing.expect(t, ov_ok)
	testing.expect_value(t, ov.name, "o")
	testing.expect_value(t, q.limit, 10)
	testing.expect_value(t, q.offset, 5)
}

@(test)
test_parse_error_positions :: proc(t: ^testing.T) {
	// Undeclared prefix, exact position.
	{
		src := "SELECT * {\n  ?s foaf:name ?o }"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Undefined_Prefix)
		testing.expect_value(t, p.err.line, 2)
		testing.expect_value(t, p.err.column, 6)
	}
	// Unclosed group at end of input.
	{
		src := "SELECT * { ?s ?p ?o "
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Unclosed_Group)
	}
	// Relative IRI without a base.
	{
		src := "SELECT * { <rel> ?p ?o }"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Relative_IRI)
		testing.expect_value(t, p.err.column, 12)
	}
	// Signed integer after LIMIT.
	{
		src := "ASK { ?s ?p ?o } LIMIT +1"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Integer)
	}
	// Trailing content after the query.
	{
		src := "ASK { ?s ?p ?o } ?x"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Trailing_Content)
	}
	// A scanner error surfaces through parse with its position.
	{
		src := "SELECT * { ?s ?p 'unterminated }"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Unterminated_String)
	}
}

@(test)
test_blank_label_scoping :: proc(t: ^testing.T) {
	// Reuse within one basic graph pattern is fine.
	{
		src := "SELECT * { _:a ?p ?o . ?s ?q _:a }"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect_value(t, p.err.kind, Error_Kind.None)
		testing.expect(t, ok)
	}
	// Reuse across two basic graph patterns is an error (§19.6).
	{
		src := "SELECT * { _:a ?p ?o OPTIONAL { ?s ?q _:a } }"
		p: Parser
		parser_init(&p, transmute([]byte)src)
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Blank_Label_Reuse)
	}
}

// The zero-copy half of the memory contract: an absolute, escape-free
// IRI in the query borrows the source buffer rather than a copy.
@(test)
test_iri_borrows_source :: proc(t: ^testing.T) {
	src := "SELECT * { <http://example.org/s> ?p ?o }"
	source := transmute([]byte)src
	p: Parser
	parser_init(&p, source)
	defer parser_destroy(&p)
	_, ok := parse(&p)
	testing.expect(t, ok)
	bp := first_bgp(p.query)
	testing.expect(t, bp != nil)
	if bp != nil {
		s, _ := bp.triples[0].subject.(rdf.IRI)
		text := string(s)
		lo := uintptr(raw_data(source))
		hi := lo + uintptr(len(source))
		at := uintptr(raw_data(text))
		testing.expect(t, at >= lo && at < hi, "IRI text must borrow the source buffer")
	}
}
