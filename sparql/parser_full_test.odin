package sparql

import "core:testing"

import rdf "rdf:rdf"

@(test)
test_parse_property_paths :: proc(t: ^testing.T) {
	src := "PREFIX f: <urn:f#> SELECT * { ?s ^f:p/f:q|f:r* ?o . ?a !(f:x|^f:y) ?b }"
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
		// ^f:p/f:q|f:r* — '|' loosest: Alternative(Sequence(Inverse(p), q), ZeroOrMore(r)).
		alt, alt_ok := bp.triples[0].predicate.(^Path_Expr)
		testing.expect(t, alt_ok)
		if alt_ok {
			testing.expect_value(t, alt.op, Path_Op.Alternative)
			testing.expect_value(t, len(alt.children), 2)
			seq := alt.children[0]
			testing.expect_value(t, seq.op, Path_Op.Sequence)
			testing.expect_value(t, seq.children[0].op, Path_Op.Inverse)
			testing.expect_value(t, seq.children[1].op, Path_Op.Link)
			star := alt.children[1]
			testing.expect_value(t, star.op, Path_Op.Zero_Or_More)
			testing.expect_value(t, star.children[0].op, Path_Op.Link)
		}
		// !(f:x|^f:y) — negated set with a forward and an inverse member.
		neg, neg_ok := bp.triples[1].predicate.(^Path_Expr)
		testing.expect(t, neg_ok)
		if neg_ok {
			testing.expect_value(t, neg.op, Path_Op.Negated_Set)
			testing.expect_value(t, len(neg.children), 2)
			testing.expect_value(t, neg.children[0].op, Path_Op.Link)
			testing.expect_value(t, neg.children[1].op, Path_Op.Inverse)
		}
	}

	// A plain-IRI path collapses back to an IRI predicate.
	src2 := "PREFIX f: <urn:f#> SELECT * { ?s f:p ?o }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	q2, ok2 := parse(&p2)
	testing.expect(t, ok2)
	bp2, _ := q2.where_clause.elements[0].(^Basic_Pattern)
	if bp2 != nil {
		_, is_iri := bp2.triples[0].predicate.(rdf.IRI)
		testing.expect(t, is_iri)
	}
}

@(test)
test_parse_aggregates_and_grouping :: proc(t: ^testing.T) {
	src := `SELECT ?s (COUNT(DISTINCT ?v) AS ?n) (GROUP_CONCAT(?v ; SEPARATOR = "|") AS ?all)
{ ?s ?p ?v } GROUP BY ?s HAVING(COUNT(?v) > 1)`
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.group_by), 1)
	testing.expect_value(t, len(q.having), 1)
	agg, agg_ok := q.projection[1].expr.(^Aggregate)
	testing.expect(t, agg_ok)
	if agg_ok {
		testing.expect_value(t, agg.op, Keyword.Count)
		testing.expect(t, agg.is_distinct)
	}
	concat, concat_ok := q.projection[2].expr.(^Aggregate)
	testing.expect(t, concat_ok)
	if concat_ok {
		testing.expect(t, concat.has_separator)
		testing.expect_value(t, concat.separator, "|")
	}

	// COUNT(*) parses; an ungrouped projected variable does not.
	src2 := "SELECT (COUNT(*) AS ?n) ?s { ?s ?p ?o }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect(t, !ok2)
	testing.expect_value(t, p2.err.kind, Error_Kind.Ungrouped_Variable)
}

@(test)
test_parse_values :: proc(t: ^testing.T) {
	// Inline one-var and full forms, plus a trailing clause.
	src := `SELECT * { VALUES ?x { 1 2 } VALUES (?y ?z) { (1 UNDEF) (UNDEF "b") } } VALUES ?w { "a" }`
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	v1, v1_ok := q.where_clause.elements[0].(^Values_Pattern)
	testing.expect(t, v1_ok)
	if v1_ok {
		testing.expect_value(t, len(v1.vars), 1)
		testing.expect_value(t, len(v1.rows), 2)
	}
	v2, v2_ok := q.where_clause.elements[1].(^Values_Pattern)
	testing.expect(t, v2_ok)
	if v2_ok {
		testing.expect_value(t, len(v2.vars), 2)
		testing.expect_value(t, len(v2.rows), 2)
		testing.expect(t, v2.rows[0][1] == nil) // UNDEF
		testing.expect(t, v2.rows[1][0] == nil)
		testing.expect_value(t, len(v2.rows[1]), 2)
	}
	testing.expect(t, q.values != nil)

	// Row arity mismatches are syntax errors (syn-bad-values tests).
	src2 := "SELECT * { ?s ?p ?o } VALUES (?x ?y) { (1) }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect(t, !ok2)
	testing.expect_value(t, p2.err.kind, Error_Kind.Values_Arity)
}

@(test)
test_parse_subselect :: proc(t: ^testing.T) {
	src := "SELECT ?s { ?s ?p ?o { SELECT (COUNT(*) AS ?n) { ?a ?b ?c } } }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.where_clause.elements), 2)
	group, group_ok := q.where_clause.elements[1].(^Group_Pattern)
	testing.expect(t, group_ok)
	if group_ok {
		ss, ss_ok := group.elements[0].(^Sub_Select)
		testing.expect(t, ss_ok)
		if ss_ok {
			testing.expect_value(t, ss.query.form, Query_Form.Select)
			testing.expect_value(t, len(ss.query.projection), 1)
		}
	}
}

@(test)
test_parse_construct_and_describe :: proc(t: ^testing.T) {
	src := "PREFIX f: <urn:f#> CONSTRUCT { ?s f:label _:b } WHERE { ?s f:name ?n }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, q.form, Query_Form.Construct)
	testing.expect(t, q.template != nil)
	testing.expect(t, !q.construct_where)
	testing.expect(t, q.where_clause != nil)

	// The WHERE shorthand: template doubles as pattern.
	src2 := "CONSTRUCT WHERE { ?s ?p ?o }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	q2, ok2 := parse(&p2)
	testing.expect_value(t, p2.err.kind, Error_Kind.None)
	testing.expect(t, ok2)
	testing.expect(t, q2.construct_where)
	testing.expect(t, q2.template != nil)
	testing.expect(t, q2.where_clause == nil)

	src3 := "DESCRIBE ?s <urn:thing> { ?s ?p ?o } LIMIT 1"
	p3: Parser
	parser_init(&p3, transmute([]byte)string(src3))
	defer parser_destroy(&p3)
	q3, ok3 := parse(&p3)
	testing.expect_value(t, p3.err.kind, Error_Kind.None)
	testing.expect(t, ok3)
	testing.expect_value(t, q3.form, Query_Form.Describe)
	testing.expect_value(t, len(q3.describe), 2)

	// DESCRIBE without a WHERE clause.
	src4 := "DESCRIBE <urn:thing>"
	p4: Parser
	parser_init(&p4, transmute([]byte)string(src4))
	defer parser_destroy(&p4)
	q4, ok4 := parse(&p4)
	testing.expect(t, ok4)
	testing.expect(t, q4.where_clause == nil)
}

@(test)
test_parse_minus :: proc(t: ^testing.T) {
	src := "SELECT * { ?s ?p ?o MINUS { ?s ?p 1 } }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	m, m_ok := q.where_clause.elements[1].(^Minus_Pattern)
	testing.expect(t, m_ok)
	if m_ok {
		testing.expect(t, m.group != nil)
	}
}

@(test)
test_bind_scope_rule :: proc(t: ^testing.T) {
	// The BIND target must be fresh in its group (syntax-BINDscope6
	// shape).
	src := "SELECT * { ?s ?p ?o . ?s ?p ?o2 BIND(1 AS ?o2) }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	_, ok := parse(&p)
	testing.expect(t, !ok)
	testing.expect_value(t, p.err.kind, Error_Kind.Variable_In_Scope)

	// The same variable in a sibling group is fine.
	src2 := "SELECT * { { ?s ?p ?o2 } { BIND(1 AS ?o2) } }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect_value(t, p2.err.kind, Error_Kind.None)
	testing.expect(t, ok2)
}

@(test)
test_select_as_scope_rule :: proc(t: ^testing.T) {
	// An AS target must not collide with a WHERE variable...
	src := "SELECT (1 AS ?x) { ?s ?p ?x }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	_, ok := parse(&p)
	testing.expect(t, !ok)
	testing.expect_value(t, p.err.kind, Error_Kind.Variable_In_Scope)

	// ...nor with an earlier AS target.
	src2 := "SELECT (1 AS ?x) (2 AS ?x) { ?s ?p ?o }"
	p2: Parser
	parser_init(&p2, transmute([]byte)string(src2))
	defer parser_destroy(&p2)
	_, ok2 := parse(&p2)
	testing.expect(t, !ok2)
	testing.expect_value(t, p2.err.kind, Error_Kind.Variable_In_Scope)
}
