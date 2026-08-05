// The §18.2 translation (SPARQL-T-0007): AST to algebra, following the
// spec's pseudocode step by step so this file reviews side-by-side
// with the spec text. Property paths translate per §18.4 (link paths
// were already collapsed to plain predicates by the parser; sequences
// decompose here with fresh variables; inverses swap their endpoints;
// the remaining operators become Path() algebra). The one deliberate
// deviation: adjacent BGP and Path parts of a triples block combine
// with Join, where ARQ would emit its `sequence` optimization — Join
// is the spec's operator and semantically identical.
//
// Ownership: the produced tree is owned by the parser (p.algebra,
// freed by parser_destroy). Expressions referenced by algebra nodes
// remain owned by the AST — with one twist: aggregate substitution
// (§18.2.4.1) REWRITES projection/HAVING/ORDER expressions in place,
// replacing each ^Aggregate subtree with its generated ".N" variable;
// the detached subtrees move to p.detached, which parser_destroy
// frees. After translate, the AST's expressions are therefore the
// post-substitution forms.
package sparql

import "core:strconv"

import rdf "rdf:rdf"

// translate turns the parsed query into its §18.2 algebra. Requires a
// successful parse; returns nil and sets p.err on internal failure
// (which no grammatical query produces). The result is also stored as
// p.algebra and freed by parser_destroy; translate must be called at
// most once per parse.
translate :: proc(p: ^Parser) -> (a: Algebra, ok: bool) {
	if p.query == nil || p.err.kind != .None {
		return nil, false
	}
	p.detached = make([dynamic]Expr, p.allocator)
	a = translate_query(p, p.query)
	p.algebra = a
	return a, p.err.kind == .None
}

// translate_query applies §18.2.4 (grouping, HAVING, VALUES, SELECT
// expressions) and §18.2.5 (OrderBy, Project, Distinct/Reduced, Slice)
// on top of the translated pattern. Used for the main query and for
// subqueries.
@(private = "file")
translate_query :: proc(p: ^Parser, q: ^Query) -> Algebra {
	g: Algebra
	if q.construct_where {
		// The CONSTRUCT WHERE shorthand: the template is the pattern.
		g = translate_basic(p, q.template)
	} else if q.where_clause != nil {
		g = translate_group_pattern(p, q.where_clause)
	} else {
		g = unit_table(p)
	}

	// §18.2.4.1 Grouping and aggregation.
	if uses_grouping(q) {
		group := new(Alg_Group, p.allocator)
		group.by = make([dynamic]Group_Condition, p.allocator)
		for condition in q.group_by {
			append(&group.by, condition)
			translate_exists_in_expr(p, condition.expr)
		}
		group.aggregates = make([dynamic]Alg_Binding, p.allocator)
		group.input = g
		for &projection in q.projection {
			substitute_aggregates(p, &projection.expr, group)
		}
		for &condition in q.having {
			substitute_aggregates(p, &condition, group)
		}
		for &condition in q.order {
			substitute_aggregates(p, &condition.expr, group)
		}
		g = group
	}

	// HAVING is a filter over the group (§18.2.4.1 end).
	if len(q.having) > 0 {
		filter := new(Alg_Filter, p.allocator)
		filter.conditions = make([dynamic]Expr, p.allocator)
		for condition in q.having {
			append(&filter.conditions, condition)
			translate_exists_in_expr(p, condition)
		}
		filter.input = g
		g = filter
	}

	// §18.2.4.2 The final VALUES clause joins the pattern.
	if q.values != nil {
		join := new(Alg_Join, p.allocator)
		join.left = g
		join.right = table_of_values(p, q.values)
		g = join
	}

	// §18.2.4.3 SELECT expressions become one Extend layer, in order.
	extend: ^Alg_Extend
	for projection in q.projection {
		if projection.expr == nil {
			continue
		}
		if extend == nil {
			extend = new(Alg_Extend, p.allocator)
			extend.bindings = make([dynamic]Alg_Binding, p.allocator)
		}
		translate_exists_in_expr(p, projection.expr)
		append(&extend.bindings, Alg_Binding{v = projection.v, expr = projection.expr})
	}
	if extend != nil {
		extend.input = g
		g = extend
	}

	// §18.2.5 solution modifiers, in spec order.
	if len(q.order) > 0 {
		order := new(Alg_Order, p.allocator)
		order.conditions = make([dynamic]Order_Condition, p.allocator)
		for condition in q.order {
			append(&order.conditions, condition)
			translate_exists_in_expr(p, condition.expr)
		}
		order.input = g
		g = order
	}

	// Projection: SELECT with an explicit list projects it; SELECT *
	// projects everything in scope, which is the identity — dropped,
	// as ARQ drops it.
	if q.form == .Select && !q.select_star {
		project := new(Alg_Project, p.allocator)
		project.vars = make([dynamic]Var, p.allocator)
		for projection in q.projection {
			append(&project.vars, projection.v)
		}
		project.input = g
		g = project
	}

	if q.select_modifier == .Distinct {
		d := new(Alg_Distinct, p.allocator)
		d.input = g
		g = d
	} else if q.select_modifier == .Reduced {
		r := new(Alg_Reduced, p.allocator)
		r.input = g
		g = r
	}

	if q.limit >= 0 || q.offset >= 0 {
		slice := new(Alg_Slice, p.allocator)
		slice.start = q.offset if q.offset >= 0 else -1
		slice.length = q.limit if q.limit >= 0 else -1
		slice.input = g
		g = slice
	}
	return g
}

// uses_grouping reports whether §18.2.4.1 applies: explicit GROUP BY,
// or an aggregate anywhere aggregates may appear.
@(private = "file")
uses_grouping :: proc(q: ^Query) -> bool {
	if len(q.group_by) > 0 || len(q.having) > 0 {
		return true
	}
	for projection in q.projection {
		if expr_uses_aggregate(projection.expr) {
			return true
		}
	}
	for condition in q.order {
		if expr_uses_aggregate(condition.expr) {
			return true
		}
	}
	return false
}

// translate_group_pattern is §18.2.2: collect the group's filters,
// translate the elements in order, join them (with LeftJoin, Minus,
// and Extend consuming the accumulated left side), and wrap the
// collected filters around the result. A nil accumulator stands for
// the empty BGP, so Join(Z, A) simplifies to A as §18.2.2.8 requires.
@(private = "file")
translate_group_pattern :: proc(p: ^Parser, g: ^Group_Pattern) -> Algebra {
	acc: Algebra

	filters: [dynamic]Expr
	for element in g.elements {
		if f, is_filter := element.(^Filter_Pattern); is_filter {
			if filters == nil {
				filters = make([dynamic]Expr, p.allocator)
			}
			append(&filters, f.condition)
			translate_exists_in_expr(p, f.condition)
		}
	}

	for element in g.elements {
		switch v in element {
		case ^Filter_Pattern:
		// Collected above; applies at the end of the group.
		case ^Basic_Pattern:
			acc = join_with(p, acc, translate_basic(p, v))
		case ^Group_Pattern:
			acc = join_with(p, acc, translate_group_pattern(p, v))
		case ^Union_Pattern:
			acc = join_with(p, acc, translate_union(p, v))
		case ^Graph_Pattern:
			graph := new(Alg_Graph, p.allocator)
			graph.graph = v.graph
			graph.input = translate_group_pattern(p, v.group)
			acc = join_with(p, acc, graph)
		case ^Optional_Pattern:
			// §18.2.2.6: OPTIONAL{Filter(F, A)} → LeftJoin(G, A, F) —
			// the inner filter's condition list moves onto the join.
			inner := translate_group_pattern(p, v.group)
			lj := new(Alg_Left_Join, p.allocator)
			lj.left = acc if acc != nil else unit_table(p)
			if inner_filter, has_filter := inner.(^Alg_Filter); has_filter {
				lj.conditions = inner_filter.conditions
				lj.right = inner_filter.input
				free(inner_filter, p.allocator)
			} else {
				lj.right = inner
			}
			acc = lj
		case ^Minus_Pattern:
			minus := new(Alg_Minus, p.allocator)
			minus.left = acc if acc != nil else unit_table(p)
			minus.right = translate_group_pattern(p, v.group)
			acc = minus
		case ^Bind_Pattern:
			extend := new(Alg_Extend, p.allocator)
			extend.bindings = make([dynamic]Alg_Binding, p.allocator)
			translate_exists_in_expr(p, v.expr)
			append(&extend.bindings, Alg_Binding{v = v.v, expr = v.expr})
			extend.input = acc if acc != nil else unit_table(p)
			acc = extend
		case ^Values_Pattern:
			acc = join_with(p, acc, table_of_values(p, v))
		case ^Sub_Select:
			acc = join_with(p, acc, translate_query(p, v.query))
		}
	}

	if acc == nil {
		acc = unit_table(p)
	}
	if filters != nil {
		filter := new(Alg_Filter, p.allocator)
		filter.conditions = filters
		filter.input = acc
		acc = filter
	}
	return acc
}

@(private = "file")
join_with :: proc(p: ^Parser, left, right: Algebra) -> Algebra {
	if left == nil {
		return right
	}
	join := new(Alg_Join, p.allocator)
	join.left = left
	join.right = right
	return join
}

@(private = "file")
translate_union :: proc(p: ^Parser, u: ^Union_Pattern) -> Algebra {
	// Left-leaning binary chain, as §18.2.2.4's fold produces.
	acc := translate_group_pattern(p, u.alternatives[0])
	for alternative in u.alternatives[1:] {
		union_node := new(Alg_Union, p.allocator)
		union_node.left = acc
		union_node.right = translate_group_pattern(p, alternative)
		acc = union_node
	}
	return acc
}

// translate_basic is §18.2.2.1/§18.4 over one triples block: simple
// predicates accumulate into BGPs, path predicates translate — and the
// interleaved parts combine with Join in block order.
@(private = "file")
translate_basic :: proc(p: ^Parser, bp: ^Basic_Pattern) -> Algebra {
	acc: Algebra
	bgp: ^Alg_BGP
	if bp == nil {
		return unit_table(p)
	}
	for tp in bp.triples {
		if path, is_path := tp.predicate.(^Path_Expr); is_path {
			if bgp != nil {
				acc = join_with(p, acc, bgp)
				bgp = nil
			}
			acc = join_with(p, acc, translate_path_triple(p, tp.subject, path, tp.object))
			continue
		}
		if bgp == nil {
			bgp = new(Alg_BGP, p.allocator)
			bgp.triples = make([dynamic]Alg_Triple, p.allocator)
		}
		append(&bgp.triples, Alg_Triple{subject = tp.subject, predicate = tp.predicate, object = tp.object})
	}
	if bgp != nil {
		acc = join_with(p, acc, bgp)
	}
	if acc == nil {
		// An empty triples block cannot come from syntax, but a
		// CONSTRUCT WHERE { } template can.
		return unit_table(p)
	}
	return acc
}

// translate_path_triple is §18.4's translation table for one X path Y:
//   X link(iri) Y   → the parser already produced a plain triple
//   X inv(P) Y      → Translate(Y P X)
//   X seq(P, Q) Y   → Translate(X P ?fresh) joined with Translate(?fresh Q Y)
//   X P Y otherwise → Path(X, P, Y)
@(private = "file")
translate_path_triple :: proc(p: ^Parser, subject: Pattern_Node, path: ^Path_Expr, object: Pattern_Node) -> Algebra {
	switch path.op {
	case .Link:
		bgp := new(Alg_BGP, p.allocator)
		bgp.triples = make([dynamic]Alg_Triple, p.allocator)
		append(&bgp.triples, Alg_Triple{subject = subject, predicate = path.iri, object = object})
		return bgp
	case .Inverse:
		return translate_path_triple(p, object, path.children[0], subject)
	case .Sequence:
		// X (P1/…/Pn) Y — fresh variables chain the steps.
		acc: Algebra
		current := subject
		for part, i in path.children {
			target: Pattern_Node = object
			if i < len(path.children) - 1 {
				target = fresh_path_var(p)
			}
			acc = join_with(p, acc, translate_path_triple(p, current, part, target))
			current = target
		}
		return acc
	case .Alternative, .Zero_Or_More, .One_Or_More, .Zero_Or_One, .Negated_Set:
		path_op := new(Alg_Path, p.allocator)
		path_op.subject = subject
		path_op.path = path
		path_op.object = object
		return path_op
	}
	return unit_table(p)
}

// substitute_aggregates rewrites the expression in the slot, replacing
// every ^Aggregate subtree with a fresh ".N" variable bound in the
// group (§18.2.4.1's sample/aggregation step). Detached subtrees move
// to p.detached for ownership.
@(private = "file")
substitute_aggregates :: proc(p: ^Parser, slot: ^Expr, group: ^Alg_Group) {
	#partial switch v in slot^ {
	case ^Aggregate:
		binding := fresh_agg_var(p)
		append(&group.aggregates, Alg_Binding{v = binding, expr = slot^})
		append(&p.detached, slot^)
		if v.expr != nil {
			translate_exists_in_expr(p, v.expr)
		}
		slot^ = binding
	case ^Binary_Expr:
		substitute_aggregates(p, &v.left, group)
		substitute_aggregates(p, &v.right, group)
	case ^Unary_Expr:
		substitute_aggregates(p, &v.operand, group)
	case ^Builtin_Call:
		for &arg in v.args {
			substitute_aggregates(p, &arg, group)
		}
	case ^Function_Call:
		for &arg in v.args {
			substitute_aggregates(p, &arg, group)
		}
	case ^In_Expr:
		substitute_aggregates(p, &v.value, group)
		for &item in v.list {
			substitute_aggregates(p, &item, group)
		}
	case ^Exists_Expr:
		translate_exists(p, v)
	}
}

// translate_exists_in_expr walks an expression and fills the algebra
// of every EXISTS it contains — the printer and the evaluator work
// from the translated form.
@(private = "file")
translate_exists_in_expr :: proc(p: ^Parser, e: Expr) {
	switch v in e {
	case ^Binary_Expr:
		translate_exists_in_expr(p, v.left)
		translate_exists_in_expr(p, v.right)
	case ^Unary_Expr:
		translate_exists_in_expr(p, v.operand)
	case ^Builtin_Call:
		for arg in v.args {
			translate_exists_in_expr(p, arg)
		}
	case ^Function_Call:
		for arg in v.args {
			translate_exists_in_expr(p, arg)
		}
	case ^In_Expr:
		translate_exists_in_expr(p, v.value)
		for item in v.list {
			translate_exists_in_expr(p, item)
		}
	case ^Exists_Expr:
		translate_exists(p, v)
	case ^Aggregate:
		if v.expr != nil {
			translate_exists_in_expr(p, v.expr)
		}
	case ^Triple_Term:
	// Triple terms contain terms and variables, never expressions.
	case Var, rdf.IRI, rdf.Literal:
	}
}

@(private = "file")
translate_exists :: proc(p: ^Parser, e: ^Exists_Expr) {
	if e.algebra == nil && e.group != nil {
		e.algebra = translate_group_pattern(p, e.group)
	}
}

@(private = "file")
table_of_values :: proc(p: ^Parser, values: ^Values_Pattern) -> ^Alg_Table {
	table := new(Alg_Table, p.allocator)
	table.vars = make([dynamic]Var, p.allocator)
	append(&table.vars, ..values.vars[:])
	table.rows = make([dynamic][dynamic]Pattern_Node, p.allocator)
	for row in values.rows {
		table_row := make([dynamic]Pattern_Node, p.allocator)
		append(&table_row, ..row[:])
		append(&table.rows, table_row)
	}
	return table
}

@(private = "file")
unit_table :: proc(p: ^Parser) -> Algebra {
	table := new(Alg_Table, p.allocator)
	table.unit = true
	return table
}

@(private = "file")
fresh_agg_var :: proc(p: ^Parser) -> Var {
	buf: [24]byte
	buf[0] = '.'
	n := len(strconv.write_int(buf[1:], i64(p.agg_n), 10))
	p.agg_n += 1
	return {name = rdf.intern(&p.intern, string(buf[:1 + n]))}
}

@(private = "file")
fresh_path_var :: proc(p: ^Parser) -> Pattern_Node {
	buf: [24]byte
	buf[0] = '.'
	buf[1] = 'p'
	n := len(strconv.write_int(buf[2:], i64(p.path_n), 10))
	p.path_n += 1
	return Var{name = rdf.intern(&p.intern, string(buf[:2 + n]))}
}
