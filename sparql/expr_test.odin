package sparql

import "core:testing"

import rdf "rdf:rdf"

// parse_filter parses `ASK { FILTER <src> }` and returns the filter's
// condition, valid until parser_destroy.
@(private = "file")
filter_expr :: proc(t: ^testing.T, p: ^Parser, buf: []byte, loc := #caller_location) -> Expr {
	q, ok := parse(p)
	if !testing.expectf(t, ok, "parse failed: %s at %d:%d", error_message(p.err.kind), p.err.line, p.err.column, loc = loc) {
		return nil
	}
	f, f_ok := q.where_clause.elements[0].(^Filter_Pattern)
	if !testing.expect(t, f_ok, "first element is not a FILTER", loc = loc) {
		return nil
	}
	_ = buf
	return f.condition
}

@(private = "file")
filter_of :: proc(t: ^testing.T, p: ^Parser, src: string, loc := #caller_location) -> Expr {
	parser_init(p, transmute([]byte)src)
	return filter_expr(t, p, nil, loc)
}

@(test)
test_expr_precedence :: proc(t: ^testing.T) {
	// || binds looser than &&.
	{
		p: Parser
		defer parser_destroy(&p)
		e := filter_of(t, &p, "ASK { FILTER(?a || ?b && ?c) }")
		or_node, or_ok := e.(^Binary_Expr)
		testing.expect(t, or_ok)
		if or_ok {
			testing.expect_value(t, or_node.op, Binary_Op.Or)
			and_node, and_ok := or_node.right.(^Binary_Expr)
			testing.expect(t, and_ok)
			if and_ok {
				testing.expect_value(t, and_node.op, Binary_Op.And)
			}
		}
	}
	// * binds tighter than +; comparison looser than both.
	{
		p: Parser
		defer parser_destroy(&p)
		e := filter_of(t, &p, "ASK { FILTER(?x = 1 + 2 * 3) }")
		eq_node, eq_ok := e.(^Binary_Expr)
		testing.expect(t, eq_ok)
		if eq_ok {
			testing.expect_value(t, eq_node.op, Binary_Op.Eq)
			add_node, add_ok := eq_node.right.(^Binary_Expr)
			testing.expect(t, add_ok)
			if add_ok {
				testing.expect_value(t, add_node.op, Binary_Op.Add)
				mul_node, mul_ok := add_node.right.(^Binary_Expr)
				testing.expect(t, mul_ok)
				if mul_ok {
					testing.expect_value(t, mul_node.op, Binary_Op.Mul)
				}
			}
		}
	}
	// Left associativity of same-precedence operators.
	{
		p: Parser
		defer parser_destroy(&p)
		e := filter_of(t, &p, "ASK { FILTER(1 - 2 - 3) }")
		outer, outer_ok := e.(^Binary_Expr)
		testing.expect(t, outer_ok)
		if outer_ok {
			testing.expect_value(t, outer.op, Binary_Op.Sub)
			inner, inner_ok := outer.left.(^Binary_Expr)
			testing.expect(t, inner_ok)
			if inner_ok {
				testing.expect_value(t, inner.op, Binary_Op.Sub)
			}
		}
	}
	// Unary binds tighter than binary; brackets override.
	{
		p: Parser
		defer parser_destroy(&p)
		e := filter_of(t, &p, "ASK { FILTER(!?a && (1 + 2) * 3 > ?b) }")
		and_node, and_ok := e.(^Binary_Expr)
		testing.expect(t, and_ok)
		if and_ok {
			testing.expect_value(t, and_node.op, Binary_Op.And)
			not_node, not_ok := and_node.left.(^Unary_Expr)
			testing.expect(t, not_ok)
			if not_ok {
				testing.expect_value(t, not_node.op, Unary_Op.Not)
			}
			gt_node, gt_ok := and_node.right.(^Binary_Expr)
			testing.expect(t, gt_ok)
			if gt_ok {
				testing.expect_value(t, gt_node.op, Binary_Op.Gt)
				mul_node, mul_ok := gt_node.left.(^Binary_Expr)
				testing.expect(t, mul_ok)
				if mul_ok {
					testing.expect_value(t, mul_node.op, Binary_Op.Mul)
					add_node, add_ok := mul_node.left.(^Binary_Expr)
					testing.expect(t, add_ok)
					if add_ok {
						testing.expect_value(t, add_node.op, Binary_Op.Add)
					}
				}
			}
		}
	}
}

@(test)
test_expr_signed_literal_shorthand :: proc(t: ^testing.T) {
	// `?x+2*3` scans '+2' as a signed literal; the grammar makes it
	// ?x + (2 * 3).
	p: Parser
	defer parser_destroy(&p)
	e := filter_of(t, &p, "ASK { FILTER(?x+2*3 = ?y) }")
	eq_node, eq_ok := e.(^Binary_Expr)
	testing.expect(t, eq_ok)
	if eq_ok {
		add_node, add_ok := eq_node.left.(^Binary_Expr)
		testing.expect(t, add_ok)
		if add_ok {
			testing.expect_value(t, add_node.op, Binary_Op.Add)
			mul_node, mul_ok := add_node.right.(^Binary_Expr)
			testing.expect(t, mul_ok)
			if mul_ok {
				testing.expect_value(t, mul_node.op, Binary_Op.Mul)
				lit, lit_ok := mul_node.left.(rdf.Literal)
				testing.expect(t, lit_ok)
				testing.expect_value(t, lit.lexical, "2") // sign lifted into the op
			}
		}
	}
}

@(test)
test_expr_in :: proc(t: ^testing.T) {
	p: Parser
	defer parser_destroy(&p)
	e := filter_of(t, &p, "ASK { FILTER(?x IN (1, 2, 3)) }")
	in_node, in_ok := e.(^In_Expr)
	testing.expect(t, in_ok)
	if in_ok {
		testing.expect(t, !in_node.negated)
		testing.expect_value(t, len(in_node.list), 3)
	}

	p2: Parser
	defer parser_destroy(&p2)
	e2 := filter_of(t, &p2, "ASK { FILTER(?x NOT IN ()) }")
	in2, in2_ok := e2.(^In_Expr)
	testing.expect(t, in2_ok)
	if in2_ok {
		testing.expect(t, in2.negated)
		testing.expect_value(t, len(in2.list), 0)
	}
}

@(test)
test_expr_builtins_and_arity :: proc(t: ^testing.T) {
	// A spread of arities incl. SPARQL 1.2 built-ins.
	{
		p: Parser
		defer parser_destroy(&p)
		src := `ASK { FILTER(STRLEN(?x) > 0 && REGEX(?x, "p", "i") && sameTerm(?a, ?b) && isTRIPLE(TRIPLE(?s, ?p, ?o)) && CONCAT() = "" && BNODE() != BNODE(?n) && IF(BOUND(?x), SUBSTR(?x, 1), COALESCE(?y, ?z)) = STR(NOW())) }`
		e := filter_of(t, &p, src)
		testing.expect(t, e != nil)
	}
	// Arity violations position at the call keyword.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(STRLEN()) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Wrong_Arity)
		testing.expect_value(t, p.err.column, 14)
	}
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(REGEX(?x)) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Wrong_Arity)
	}
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(IF(1, 2)) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Wrong_Arity)
	}
	// BOUND takes a variable, not an expression.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(BOUND(1)) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Variable)
	}
}

@(test)
test_expr_exists :: proc(t: ^testing.T) {
	p: Parser
	defer parser_destroy(&p)
	e := filter_of(t, &p, "ASK { FILTER EXISTS { ?s ?p ?o } }")
	ex, ex_ok := e.(^Exists_Expr)
	testing.expect(t, ex_ok)
	if ex_ok {
		testing.expect(t, !ex.negated)
		testing.expect(t, ex.group != nil)
	}

	p2: Parser
	defer parser_destroy(&p2)
	e2 := filter_of(t, &p2, "ASK { FILTER NOT EXISTS { ?s ?p ?o } }")
	ex2, ex2_ok := e2.(^Exists_Expr)
	testing.expect(t, ex2_ok)
	if ex2_ok {
		testing.expect(t, ex2.negated)
	}
}

@(test)
test_expr_function_calls :: proc(t: ^testing.T) {
	p: Parser
	defer parser_destroy(&p)
	src := "PREFIX ex: <urn:ex#> ASK { FILTER ex:f(?x, 2) }"
	parser_init(&p, transmute([]byte)string(src))
	e := filter_expr(t, &p, nil)
	f, f_ok := e.(^Function_Call)
	testing.expect(t, f_ok)
	if f_ok {
		testing.expect_value(t, string(f.iri), "urn:ex#f")
		testing.expect_value(t, len(f.args), 2)
		testing.expect(t, !f.is_distinct)
	}

	// Empty argument list via NIL, and DISTINCT.
	p2: Parser
	defer parser_destroy(&p2)
	src2 := "PREFIX ex: <urn:ex#> ASK { FILTER(ex:g( ) = ex:agg(DISTINCT ?x)) }"
	parser_init(&p2, transmute([]byte)string(src2))
	e2 := filter_expr(t, &p2, nil)
	eq_node, eq_ok := e2.(^Binary_Expr)
	testing.expect(t, eq_ok)
	if eq_ok {
		g, g_ok := eq_node.left.(^Function_Call)
		testing.expect(t, g_ok)
		if g_ok {
			testing.expect_value(t, len(g.args), 0)
		}
		agg, agg_ok := eq_node.right.(^Function_Call)
		testing.expect(t, agg_ok)
		if agg_ok {
			testing.expect(t, agg.is_distinct)
			testing.expect_value(t, len(agg.args), 1)
		}
	}
}

@(test)
test_filter_placements_and_bind :: proc(t: ^testing.T) {
	src := `ASK { FILTER(?a) ?s ?p ?o . FILTER regex(?o, "x") BIND(?o + 1 AS ?n) }`
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.where_clause.elements), 4)
	if len(q.where_clause.elements) == 4 {
		_, f0 := q.where_clause.elements[0].(^Filter_Pattern)
		testing.expect(t, f0)
		_, f2 := q.where_clause.elements[2].(^Filter_Pattern)
		testing.expect(t, f2)
		b, b_ok := q.where_clause.elements[3].(^Bind_Pattern)
		testing.expect(t, b_ok)
		if b_ok {
			testing.expect_value(t, b.v.name, "n")
			add_node, add_ok := b.expr.(^Binary_Expr)
			testing.expect(t, add_ok)
			if add_ok {
				testing.expect_value(t, add_node.op, Binary_Op.Add)
			}
		}
	}
}

@(test)
test_projection_expressions :: proc(t: ^testing.T) {
	src := "SELECT (?x + 1 AS ?y) ?z { ?x ?p ?z }"
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.projection), 2)
	if len(q.projection) == 2 {
		testing.expect_value(t, q.projection[0].v.name, "y")
		testing.expect(t, q.projection[0].expr != nil)
		testing.expect_value(t, q.projection[1].v.name, "z")
		testing.expect(t, q.projection[1].expr == nil)
	}
}

@(test)
test_order_by_constraints :: proc(t: ^testing.T) {
	src := `SELECT * { ?s ?p ?x . ?s ?q ?y . ?s ?r ?z } ORDER BY str(?x) (?y) DESC(?z + 1) LIMIT 3`
	p: Parser
	parser_init(&p, transmute([]byte)string(src))
	defer parser_destroy(&p)
	q, ok := parse(&p)
	testing.expect_value(t, p.err.kind, Error_Kind.None)
	testing.expect(t, ok)
	testing.expect_value(t, len(q.order), 3)
	if len(q.order) == 3 {
		_, c0 := q.order[0].expr.(^Builtin_Call)
		testing.expect(t, c0)
		_, c1 := q.order[1].expr.(Var)
		testing.expect(t, c1)
		testing.expect_value(t, q.order[2].direction, Order_Direction.Descending)
		_, c2 := q.order[2].expr.(^Binary_Expr)
		testing.expect(t, c2)
	}
	testing.expect_value(t, q.limit, 3)
}

@(test)
test_expr_literals :: proc(t: ^testing.T) {
	p: Parser
	defer parser_destroy(&p)
	e := filter_of(t, &p, `ASK { FILTER(?x = "a"@en) }`)
	eq_node, eq_ok := e.(^Binary_Expr)
	testing.expect(t, eq_ok)
	if eq_ok {
		lit, lit_ok := eq_node.right.(rdf.Literal)
		testing.expect(t, lit_ok)
		testing.expect_value(t, lit.language, "en")
	}
}

@(test)
test_expr_error_positions :: proc(t: ^testing.T) {
	// Dangling operator.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(?x + ) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Expression)
		testing.expect_value(t, p.err.column, 19) // the ')'
	}
	// Relational operators do not chain.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(?a < ?b = ?c) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Close_Paren)
	}
	// BIND without AS.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { BIND(?x ?y) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_As)
	}
	// Projection expression without AS.
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("SELECT (1 ?x) { ?s ?p ?o }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_As)
	}
	// An aggregate keyword is not yet an expression (SPARQL-T-0005).
	{
		p: Parser
		parser_init(&p, transmute([]byte)string("ASK { FILTER(COUNT(?x) > 0) }"))
		defer parser_destroy(&p)
		_, ok := parse(&p)
		testing.expect(t, !ok)
		testing.expect_value(t, p.err.kind, Error_Kind.Expected_Expression)
	}
}
