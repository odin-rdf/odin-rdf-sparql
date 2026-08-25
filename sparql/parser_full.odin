// Grammar completion (SPARQL-T-0005): property paths, aggregates,
// GROUP BY/HAVING, VALUES, subqueries, CONSTRUCT/DESCRIBE support
// procs, and the static scope rules the spec states as grammar notes
// (§19.8): BIND/AS assignment freshness and the grouped-query
// projection restriction. The group-parser and query-form dispatch
// live in parser.odin; this file holds the productions they call.
package sparql

import rdf "rdf:rdf"

// --- Property paths -------------------------------------------------

@(private)
starts_path :: proc(p: ^Parser) -> bool {
	if !p.has_tok {
		return false
	}
	#partial switch p.tok.kind {
	case .IRI_Ref, .PName, .A, .Caret, .Bang, .L_Paren:
		return true
	}
	return false
}

// parse_verb_path parses VerbPath | VerbSimple, collapsing a bare link
// to a plain IRI node.
@(private)
parse_verb_path :: proc(p: ^Parser) -> Pattern_Node {
	if at(p, .Var) {
		v := var_of(p.tok)
		advance(p)
		return v
	}
	if !starts_path(p) {
		fail_current(p, .Expected_Predicate)
		return nil
	}
	path := parse_path(p)
	if p.err.kind != .None || path == nil {
		// The partial path is not reachable from the AST yet; free it
		// here rather than leak it (destroy_path handles nil).
		destroy_path(path, p.allocator)
		return nil
	}
	return collapse_path(p, path)
}

// collapse_path turns a Link-only path node back into its IRI.
@(private = "file")
collapse_path :: proc(p: ^Parser, path: ^Path_Expr) -> Pattern_Node {
	if path.op == .Link {
		iri := path.iri
		delete(path.children)
		free(path, p.allocator)
		return iri
	}
	return path
}

// parse_path parses Path ::= PathAlternative.
@(private)
parse_path :: proc(p: ^Parser) -> ^Path_Expr {
	if p.depth >= MAX_DEPTH {
		fail_current(p, .Nesting_Too_Deep)
		return nil
	}
	p.depth += 1
	defer p.depth -= 1

	first := parse_path_sequence(p)
	if p.err.kind != .None || !at(p, .Pipe) {
		return first
	}
	alt := path_node(p, .Alternative, token_pos(p.tok))
	append(&alt.children, first)
	for p.err.kind == .None && at(p, .Pipe) {
		advance(p)
		append(&alt.children, parse_path_sequence(p))
	}
	return alt
}

@(private = "file")
parse_path_sequence :: proc(p: ^Parser) -> ^Path_Expr {
	first := parse_path_elt_or_inverse(p)
	if p.err.kind != .None || !at(p, .Slash) {
		return first
	}
	seq := path_node(p, .Sequence, token_pos(p.tok))
	append(&seq.children, first)
	for p.err.kind == .None && at(p, .Slash) {
		advance(p)
		append(&seq.children, parse_path_elt_or_inverse(p))
	}
	return seq
}

@(private = "file")
parse_path_elt_or_inverse :: proc(p: ^Parser) -> ^Path_Expr {
	if at(p, .Caret) {
		pos := token_pos(p.tok)
		advance(p)
		inverse := path_node(p, .Inverse, pos)
		append(&inverse.children, parse_path_elt(p))
		return inverse
	}
	return parse_path_elt(p)
}

@(private = "file")
parse_path_elt :: proc(p: ^Parser) -> ^Path_Expr {
	primary := parse_path_primary(p)
	if p.err.kind != .None || !p.has_tok {
		return primary
	}
	mod_op: Path_Op
	#partial switch p.tok.kind {
	case .Question:
		mod_op = .Zero_Or_One
	case .Star:
		mod_op = .Zero_Or_More
	case .Plus:
		mod_op = .One_Or_More
	case:
		return primary
	}
	mod := path_node(p, mod_op, token_pos(p.tok))
	advance(p)
	append(&mod.children, primary)
	return mod
}

@(private = "file")
parse_path_primary :: proc(p: ^Parser) -> ^Path_Expr {
	if !p.has_tok {
		fail_here(p, .Expected_Path)
		return nil
	}
	pos := token_pos(p.tok)
	#partial switch p.tok.kind {
	case .A:
		advance(p)
		link := path_node(p, .Link, pos)
		link.iri = rdf.RDF_TYPE
		return link
	case .IRI_Ref, .PName:
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		link := path_node(p, .Link, pos)
		link.iri = iri
		return link
	case .Bang:
		advance(p)
		return parse_path_negated_set(p, pos)
	case .L_Paren:
		if p.depth >= MAX_DEPTH {
			fail_current(p, .Nesting_Too_Deep)
			return nil
		}
		p.depth += 1
		defer p.depth -= 1
		advance(p)
		inner := parse_path(p)
		if p.err.kind != .None {
			return inner
		}
		if !at(p, .R_Paren) {
			fail_current(p, .Expected_Close_Paren)
			return inner
		}
		advance(p)
		return inner
	}
	fail_at(p, .Expected_Path, p.tok)
	return nil
}

// parse_path_negated_set parses PathNegatedPropertySet: one member or
// a parenthesised '|' list of PathOneInPropertySet.
@(private = "file")
parse_path_negated_set :: proc(p: ^Parser, pos: Position) -> ^Path_Expr {
	neg := path_node(p, .Negated_Set, pos)
	if at(p, .L_Paren) {
		advance(p)
		if at(p, .R_Paren) { // '!()' — empty set is legal
			advance(p)
			return neg
		}
		for p.err.kind == .None {
			append(&neg.children, parse_path_one_in_set(p))
			if at(p, .Pipe) {
				advance(p)
				continue
			}
			break
		}
		if p.err.kind != .None {
			return neg
		}
		if !at(p, .R_Paren) {
			fail_current(p, .Expected_Close_Paren)
			return neg
		}
		advance(p)
		return neg
	}
	append(&neg.children, parse_path_one_in_set(p))
	return neg
}

// parse_path_one_in_set parses PathOneInPropertySet ::= iri | 'a' |
// '^' (iri | 'a').
@(private = "file")
parse_path_one_in_set :: proc(p: ^Parser) -> ^Path_Expr {
	if !p.has_tok {
		fail_here(p, .Expected_Path)
		return nil
	}
	pos := token_pos(p.tok)
	if at(p, .Caret) {
		advance(p)
		inverse := path_node(p, .Inverse, pos)
		append(&inverse.children, parse_path_one_in_set(p))
		return inverse
	}
	if at(p, .A) {
		advance(p)
		link := path_node(p, .Link, pos)
		link.iri = rdf.RDF_TYPE
		return link
	}
	if at(p, .IRI_Ref) || at(p, .PName) {
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		link := path_node(p, .Link, pos)
		link.iri = iri
		return link
	}
	fail_at(p, .Expected_Path, p.tok)
	return nil
}

@(private = "file")
path_node :: proc(p: ^Parser, op: Path_Op, pos: Position) -> ^Path_Expr {
	node := new(Path_Expr, p.allocator)
	node.op = op
	node.pos = pos
	node.children = make([dynamic]^Path_Expr, p.allocator)
	return node
}

// --- Aggregates -----------------------------------------------------

@(private)
aggregate_keyword :: proc(kw: Keyword) -> bool {
	#partial switch kw {
	case .Count, .Sum, .Min, .Max, .Avg, .Sample, .Group_Concat:
		return true
	}
	return false
}

// parse_aggregate parses the Aggregate production; the aggregate
// keyword is the current token on entry.
@(private)
parse_aggregate :: proc(p: ^Parser) -> Expr {
	kw_tok := p.tok
	pos := token_pos(kw_tok)
	advance(p)
	if !at(p, .L_Paren) {
		// A NIL token here would mean zero arguments, which no
		// aggregate permits.
		fail_current(p, .Wrong_Arity if at(p, .Nil) else .Expected_Expression)
		return nil
	}
	advance(p)
	agg := new(Aggregate, p.allocator)
	agg.op = kw_tok.keyword
	agg.pos = pos
	if at_keyword(p, .Distinct) {
		agg.is_distinct = true
		advance(p)
	}
	if kw_tok.keyword == .Count && at(p, .Star) {
		agg.star = true
		advance(p)
	} else {
		agg.expr = parse_expression(p)
		if p.err.kind != .None {
			return agg
		}
		if expr_uses_aggregate(agg.expr) {
			fail_at(p, .Nested_Aggregate, kw_tok)
			return agg
		}
	}
	if kw_tok.keyword == .Group_Concat && at(p, .Semicolon) {
		advance(p)
		if !at_keyword(p, .Separator) {
			fail_current(p, .Expected_Separator)
			return agg
		}
		advance(p)
		if !at(p, .Eq) {
			fail_current(p, .Expected_Separator)
			return agg
		}
		advance(p)
		if !at(p, .String_Literal) {
			fail_current(p, .Expected_Separator)
			return agg
		}
		agg.separator = unescape_string_text(p, p.tok)
		agg.has_separator = true
		advance(p)
	}
	if !at(p, .R_Paren) {
		fail_current(p, .Expected_Close_Paren)
		return agg
	}
	advance(p)
	return agg
}

// --- VALUES ---------------------------------------------------------

// parse_values parses VALUES DataBlock; the VALUES keyword is the
// current token on entry.
@(private)
parse_values :: proc(p: ^Parser) -> ^Values_Pattern {
	vp := new(Values_Pattern, p.allocator)
	vp.pos = token_pos(p.tok)
	vp.vars = make([dynamic]Var, p.allocator)
	vp.rows = make([dynamic][dynamic]Pattern_Node, p.allocator)
	advance(p) // VALUES

	one_var := false
	switch {
	case at(p, .Var):
		one_var = true
		append(&vp.vars, var_of(p.tok))
		advance(p)
	case at(p, .Nil):
		advance(p)
	case at(p, .L_Paren):
		advance(p)
		for at(p, .Var) {
			// A data block may not name the same variable twice
			// (sparql12 duplicated-values-variable).
			for existing in vp.vars {
				if existing.name == p.tok.text {
					fail_at(p, .Variable_In_Scope, p.tok)
					return vp
				}
			}
			append(&vp.vars, var_of(p.tok))
			advance(p)
		}
		if !at(p, .R_Paren) {
			fail_current(p, .Expected_Variable)
			return vp
		}
		advance(p)
	case:
		fail_current(p, .Expected_Variable)
		return vp
	}

	if !at(p, .L_Brace) {
		fail_current(p, .Expected_Group)
		return vp
	}
	advance(p)

	for p.err.kind == .None {
		if at(p, .R_Brace) {
			advance(p)
			return vp
		}
		if one_var {
			row := make([dynamic]Pattern_Node, p.allocator)
			append(&vp.rows, row)
			value, ok := parse_data_value(p)
			if !ok {
				return vp
			}
			append(&vp.rows[len(vp.rows) - 1], value)
			continue
		}
		row_tok := p.tok
		row := make([dynamic]Pattern_Node, p.allocator)
		append(&vp.rows, row)
		switch {
		case at(p, .Nil):
			advance(p)
		case at(p, .L_Paren):
			advance(p)
			for p.err.kind == .None && !at(p, .R_Paren) {
				value, ok := parse_data_value(p)
				if !ok {
					return vp
				}
				append(&vp.rows[len(vp.rows) - 1], value)
			}
			if !at(p, .R_Paren) {
				fail_current(p, .Expected_Data_Value)
				return vp
			}
			advance(p)
		case:
			fail_current(p, .Expected_Data_Value)
			return vp
		}
		if len(vp.rows[len(vp.rows) - 1]) != len(vp.vars) {
			fail_at(p, .Values_Arity, row_tok)
			return vp
		}
	}
	if !p.has_tok {
		fail_here(p, .Unclosed_Group)
	}
	return vp
}

// parse_data_value parses DataBlockValue: iri, literal, or UNDEF (a
// nil Pattern_Node).
@(private = "file")
parse_data_value :: proc(p: ^Parser) -> (value: Pattern_Node, ok: bool) {
	if !p.has_tok {
		fail_here(p, .Expected_Data_Value)
		return nil, false
	}
	#partial switch p.tok.kind {
	case .Triple_Term_Open:
		// SPARQL 1.2: a ground triple term is a data value.
		tt := parse_triple_term(p, .Data)
		if p.err.kind != .None {
			return nil, false
		}
		return tt, true
	case .IRI_Ref, .PName:
		iri, iri_ok := parse_iri(p)
		if !iri_ok {
			return nil, false
		}
		return iri, true
	case .String_Literal:
		lit, lit_ok := parse_rdf_literal(p)
		if !lit_ok {
			return nil, false
		}
		return lit, true
	case .Integer, .Decimal, .Double:
		lit := numeric_literal(p.tok.kind, p.tok.text)
		advance(p)
		return lit, true
	case .Boolean:
		lexical := "true" if (p.tok.text[0] == 't' || p.tok.text[0] == 'T') else "false"
		advance(p)
		return rdf.literal_typed(lexical, rdf.XSD_BOOLEAN), true
	case .Keyword:
		if p.tok.keyword == .Undef {
			advance(p)
			return nil, true
		}
	}
	fail_at(p, .Expected_Data_Value, p.tok)
	return nil, false
}

// --- In-scope variables and the assignment rules --------------------

// collect_in_scope adds the in-scope variables of a pattern per
// §18.2.1. MINUS contributes nothing; FILTER binds nothing.
@(private)
collect_in_scope :: proc(pat: Pattern, scope: ^map[string]bool) {
	switch v in pat {
	case ^Basic_Pattern:
		for tp in v.triples {
			collect_node_var(tp.subject, scope)
			collect_node_var(tp.predicate, scope)
			collect_node_var(tp.object, scope)
		}
	case ^Group_Pattern:
		collect_group_in_scope(v, scope)
	case ^Optional_Pattern:
		collect_group_in_scope(v.group, scope)
	case ^Union_Pattern:
		for alternative in v.alternatives {
			collect_group_in_scope(alternative, scope)
		}
	case ^Graph_Pattern:
		collect_node_var(v.graph, scope)
		collect_group_in_scope(v.group, scope)
	case ^Filter_Pattern:
	// Filters bind nothing.
	case ^Bind_Pattern:
		scope[v.v.name] = true
	case ^Minus_Pattern:
	// MINUS variables are not in scope outside it.
	case ^Values_Pattern:
		for values_var in v.vars {
			scope[values_var.name] = true
		}
	case ^Sub_Select:
		if v.query != nil {
			if v.query.select_star {
				collect_group_in_scope(v.query.where_clause, scope)
			} else {
				for projection in v.query.projection {
					scope[projection.v.name] = true
				}
			}
		}
	}
}

@(private)
collect_group_in_scope :: proc(g: ^Group_Pattern, scope: ^map[string]bool) {
	if g == nil {
		return
	}
	for element in g.elements {
		collect_in_scope(element, scope)
	}
}

@(private = "file")
collect_node_var :: proc(node: Pattern_Node, scope: ^map[string]bool) {
	#partial switch v in node {
	case Var:
		scope[v.name] = true
	case ^Triple_Term:
		// Variables inside a triple term bind during matching and are
		// in scope.
		collect_node_var(v.subject, scope)
		collect_node_var(v.predicate, scope)
		collect_node_var(v.object, scope)
	}
}

// var_in_scope_of_elements reports whether name is in scope after the
// given elements, using the parser's scratch map.
@(private)
var_in_scope_of_elements :: proc(p: ^Parser, elements: []Pattern, name: string) -> bool {
	clear(&p.scope_scratch)
	for element in elements {
		collect_in_scope(element, &p.scope_scratch)
	}
	return p.scope_scratch[name]
}

// check_query_scopes enforces the §19.8 grammar notes after a query
// (or subquery) has fully parsed: AS-variable freshness in the SELECT
// clause and the grouped-query projection restriction.
@(private)
check_query_scopes :: proc(p: ^Parser, q: ^Parsed_Query) {
	if p.err.kind != .None {
		return
	}

	// AS variables must be fresh. GROUP BY (expr AS v) checks against
	// the pattern's in-scope set; a grouped query's SELECT AS targets
	// check against what grouping leaves visible — the group keys —
	// not the raw pattern scope (sparql12 group-by-scope tests).
	clear(&p.scope_scratch)
	collect_group_in_scope(q.where_clause, &p.scope_scratch)
	if q.values != nil {
		for values_var in q.values.vars {
			p.scope_scratch[values_var.name] = true
		}
	}
	for condition in q.group_by {
		if condition.has_var {
			if p.scope_scratch[condition.v.name] {
				fail_var(p, .Variable_In_Scope, condition.v)
				return
			}
			p.scope_scratch[condition.v.name] = true
		}
	}
	if len(q.group_by) > 0 {
		// Rebuild as the post-grouping visible set.
		clear(&p.scope_scratch)
		for condition in q.group_by {
			if v, is_var := condition.expr.(Var); is_var {
				p.scope_scratch[v.name] = true
			}
			if condition.has_var {
				p.scope_scratch[condition.v.name] = true
			}
		}
	}
	for projection in q.projection {
		if projection.expr == nil {
			continue
		}
		if p.scope_scratch[projection.v.name] {
			fail_var(p, .Variable_In_Scope, projection.v)
			return
		}
		p.scope_scratch[projection.v.name] = true
	}
	// A bare projected variable may repeat, but an AS target may not
	// collide with a bare projection either.
	for projection, i in q.projection {
		if projection.expr != nil {
			continue
		}
		for other, j in q.projection {
			if i != j && other.expr != nil && other.v.name == projection.v.name {
				fail_var(p, .Variable_In_Scope, other.v)
				return
			}
		}
	}

	check_grouping(p, q)
}

// check_grouping enforces the aggregate projection restriction: in a
// grouped query (explicit GROUP BY, or implicit through an aggregate
// in the projection or HAVING), variables may only be used inside
// aggregates or if they are grouped.
@(private = "file")
check_grouping :: proc(p: ^Parser, q: ^Parsed_Query) {
	grouped := len(q.group_by) > 0
	uses_aggregate := len(q.having) > 0
	for projection in q.projection {
		if expr_uses_aggregate(projection.expr) {
			uses_aggregate = true
		}
	}
	for condition in q.having {
		if expr_uses_aggregate(condition) {
			uses_aggregate = true
		}
	}
	if !grouped && !uses_aggregate {
		return
	}

	// SELECT * cannot be grouped (syn-bad-01): the projection must name
	// what it projects so the restriction below is checkable.
	if q.select_star {
		pos := Position{}
		if len(q.group_by) > 0 {
			if v, is_var := q.group_by[0].expr.(Var); is_var {
				pos = v.pos
			}
		}
		if p.err.kind == .None {
			p.err = {kind = .Ungrouped_Variable, offset = pos.offset, line = pos.line, column = pos.column}
		}
		return
	}

	// The grouped variables: GROUP BY Var conditions and AS targets.
	clear(&p.scope_scratch)
	for condition in q.group_by {
		if v, is_var := condition.expr.(Var); is_var {
			p.scope_scratch[v.name] = true
		}
		if condition.has_var {
			p.scope_scratch[condition.v.name] = true
		}
	}

	for projection in q.projection {
		if projection.expr == nil {
			if !p.scope_scratch[projection.v.name] {
				fail_var(p, .Ungrouped_Variable, projection.v)
				return
			}
			continue
		}
		if bad, v := ungrouped_var(projection.expr, &p.scope_scratch); bad {
			fail_var(p, .Ungrouped_Variable, v)
			return
		}
		// The AS target becomes available to later conditions.
		p.scope_scratch[projection.v.name] = true
	}
	for condition in q.having {
		if bad, v := ungrouped_var(condition, &p.scope_scratch); bad {
			fail_var(p, .Ungrouped_Variable, v)
			return
		}
	}
}

@(private = "file")
fail_var :: proc(p: ^Parser, kind: Error_Kind, v: Var) {
	if p.err.kind == .None {
		p.err = {kind = kind, offset = v.pos.offset, line = v.pos.line, column = v.pos.column}
	}
}

@(private)
expr_uses_aggregate :: proc(e: Expr) -> bool {
	switch v in e {
	case ^Binary_Expr:
		return expr_uses_aggregate(v.left) || expr_uses_aggregate(v.right)
	case ^Unary_Expr:
		return expr_uses_aggregate(v.operand)
	case ^Builtin_Call:
		for arg in v.args {
			if expr_uses_aggregate(arg) {
				return true
			}
		}
	case ^Function_Call:
		for arg in v.args {
			if expr_uses_aggregate(arg) {
				return true
			}
		}
	case ^In_Expr:
		if expr_uses_aggregate(v.value) {
			return true
		}
		for item in v.list {
			if expr_uses_aggregate(item) {
				return true
			}
		}
	case ^Aggregate:
		return true
	case ^Exists_Expr, ^Triple_Term, Var, rdf.IRI, rdf.Literal:
	}
	return false
}

// ungrouped_var finds a variable used outside any aggregate that is
// not in the grouped set.
@(private = "file")
ungrouped_var :: proc(e: Expr, grouped: ^map[string]bool) -> (found: bool, v: Var) {
	switch node in e {
	case ^Binary_Expr:
		if found, v = ungrouped_var(node.left, grouped); found {
			return
		}
		return ungrouped_var(node.right, grouped)
	case ^Unary_Expr:
		return ungrouped_var(node.operand, grouped)
	case ^Builtin_Call:
		for arg in node.args {
			if found, v = ungrouped_var(arg, grouped); found {
				return
			}
		}
	case ^Function_Call:
		for arg in node.args {
			if found, v = ungrouped_var(arg, grouped); found {
				return
			}
		}
	case ^In_Expr:
		if found, v = ungrouped_var(node.value, grouped); found {
			return
		}
		for item in node.list {
			if found, v = ungrouped_var(item, grouped); found {
				return
			}
		}
	case ^Aggregate:
	// Anything under an aggregate is fine.
	case ^Exists_Expr:
	// EXISTS patterns have their own scope.
	case ^Triple_Term:
		return ungrouped_var_in_term(node, grouped)
	case Var:
		if !grouped[node.name] {
			return true, node
		}
	case rdf.IRI, rdf.Literal:
	}
	return false, {}
}

@(private = "file")
ungrouped_var_in_term :: proc(tt: ^Triple_Term, grouped: ^map[string]bool) -> (found: bool, v: Var) {
	nodes := [3]Pattern_Node{tt.subject, tt.predicate, tt.object}
	for node in nodes {
		#partial switch inner in node {
		case Var:
			if !grouped[inner.name] {
				return true, inner
			}
		case ^Triple_Term:
			if found, v = ungrouped_var_in_term(inner, grouped); found {
				return
			}
		}
	}
	return false, {}
}
