// The query parser core: recursive descent over the token stream, one
// proc per grammar production (SPARQL-T-0003). Covers the prologue,
// SELECT/ASK, dataset clauses, triple patterns with all abbreviations,
// group graph patterns with GRAPH/OPTIONAL/UNION, and the ORDER
// BY/LIMIT/OFFSET solution modifiers. Expressions, FILTER and BIND
// arrive with SPARQL-T-0004; property paths, aggregates, subqueries,
// VALUES, and CONSTRUCT/DESCRIBE with SPARQL-T-0005.
//
// Memory contract (the family's): the query text is caller-owned and
// must stay valid for the parser's lifetime; AST strings borrow from it
// where possible, and every derived allocation (prefix expansions,
// resolved IRIs, unescaped lexical forms, generated blank labels) is
// owned by the parser's intern table until parser_destroy.
package sparql

import "base:runtime"
import "core:strconv"
import "core:unicode/utf8"

import rdf "rdf:rdf"

// The recursion bound covers group nesting and triples-node nesting
// combined — the same guard the family's Turtle parser applies.
MAX_DEPTH :: 128

Parser :: struct {
	scanner:     Scanner,
	tok:         Token,
	has_tok:     bool,
	err:         Error,
	query:       ^Query, // owned; freed by parser_destroy
	intern:      rdf.Intern_Table,
	prefixes:    map[string]string, // prefix (borrowed) -> expansion (interned)
	base:        string, // interned; "" when no base established
	scratch:     Resolve_Scratch,
	unesc:         [dynamic]byte, // reusable unescape buffer
	blank_first:   map[string]int, // blank label -> id of the BGP that first used it
	bgp_id:        int, // current Basic_Pattern's identity for label scoping
	fresh_n:       int, // generated blank-label counter
	depth:         int,
	in_template:   bool, // CONSTRUCT template: no paths, no label scoping
	scope_scratch: map[string]bool, // reused by the §19.8 scope checks
	algebra:       Algebra, // owned; set by translate, freed by parser_destroy
	detached:      [dynamic]Expr, // aggregate trees translate lifted out of the AST
	triple_terms:  [dynamic]^Triple_Term, // registry of all 1.2 triple-term nodes (shared by design)
	agg_n:         int, // ".N" aggregate-variable counter
	path_n:        int, // ".pN" path-variable counter
	allocator:     runtime.Allocator,
}

// parser_init prepares p to parse source. base anchors relative IRIs;
// an empty or relative base establishes none, and a later relative IRI
// reference is then an error. The parser owns what it allocates until
// parser_destroy; source must stay valid and unmoved for the parser's
// lifetime.
parser_init :: proc(p: ^Parser, source: []byte, base := "", allocator := context.allocator) {
	p^ = {
		allocator = allocator,
	}
	scanner_init(&p.scanner, source)
	rdf.intern_table_init(&p.intern, allocator)
	p.prefixes = make(map[string]string, allocator)
	p.blank_first = make(map[string]int, allocator)
	p.scope_scratch = make(map[string]bool, allocator)
	p.triple_terms = make([dynamic]^Triple_Term, allocator)
	p.unesc = make([dynamic]byte, allocator)
	if base != "" {
		// A relative initial base can never resolve anything; leave the
		// base unestablished and let a relative reference error later.
		if resolved, ok := iri_resolve(&p.intern, "", base, &p.scratch); ok {
			p.base = resolved
		}
	}
}

parser_destroy :: proc(p: ^Parser) {
	destroy_query(p.query, p.allocator)
	destroy_algebra(p.algebra, p.allocator)
	for detached in p.detached {
		destroy_expr(detached, p.allocator)
	}
	delete(p.detached)
	for tt in p.triple_terms {
		free(tt, p.allocator)
	}
	delete(p.triple_terms)
	delete(p.prefixes)
	delete(p.blank_first)
	delete(p.scope_scratch)
	delete(p.unesc)
	resolve_scratch_destroy(&p.scratch)
	rdf.intern_table_destroy(&p.intern)
	p^ = {}
}

// parse consumes the whole query. ok is false on error, with p.err
// positioned at the violation; the partial tree is owned by the parser
// either way. Calling parse twice is not supported.
parse :: proc(p: ^Parser) -> (q: ^Query, ok: bool) {
	advance(p)
	if p.err.kind != .None {
		return nil, false
	}

	q = new_query(p)
	p.query = q

	parse_prologue(p, q)

	where_required := true
	switch {
	case at_keyword(p, .Select):
		q.form = .Select
		parse_select_clause(p, q)
		if p.err.kind == .None {
			parse_dataset_clauses(p, q)
		}
	case at_keyword(p, .Ask):
		q.form = .Ask
		advance(p)
		parse_dataset_clauses(p, q)
	case at_keyword(p, .Construct):
		q.form = .Construct
		advance(p)
		parse_construct_head(p, q)
		where_required = false // the shorthand form consumed its pattern
	case at_keyword(p, .Describe):
		q.form = .Describe
		advance(p)
		parse_describe_head(p, q)
		where_required = false // DESCRIBE's WHERE clause is optional
	case:
		fail_current(p, .Expected_Query_Form)
		return nil, false
	}
	if p.err.kind != .None {
		return nil, false
	}

	// WhereClause: the WHERE keyword is optional before the group.
	if q.where_clause == nil && !q.construct_where {
		if at_keyword(p, .Where) {
			advance(p)
			q.where_clause = parse_group(p)
		} else if where_required || at(p, .L_Brace) {
			q.where_clause = parse_group(p)
		}
		if p.err.kind != .None {
			return nil, false
		}
	}

	parse_solution_modifiers(p, q)
	if p.err.kind != .None {
		return nil, false
	}

	// ValuesClause: an optional trailing VALUES block.
	if at_keyword(p, .Values) {
		q.values = parse_values(p)
		if p.err.kind != .None {
			return nil, false
		}
	}

	check_query_scopes(p, q)
	if p.err.kind != .None {
		return nil, false
	}

	if p.has_tok {
		fail_at(p, .Trailing_Content, p.tok)
		return nil, false
	}
	return q, p.err.kind == .None
}

// parse_construct_head parses what follows CONSTRUCT: either a
// template, datasets, and a WHERE group — or the WHERE-shorthand form,
// whose braced triples serve as both template and pattern
// (construct_where marks it for the algebra translation).
@(private = "file")
parse_construct_head :: proc(p: ^Parser, q: ^Query) {
	if at(p, .L_Brace) {
		q.template = parse_template(p)
		if p.err.kind != .None {
			return
		}
		parse_dataset_clauses(p, q)
		if at_keyword(p, .Where) {
			advance(p)
		}
		q.where_clause = parse_group(p)
		return
	}
	parse_dataset_clauses(p, q)
	if !at_keyword(p, .Where) {
		fail_current(p, .Expected_Group)
		return
	}
	advance(p)
	q.template = parse_template(p)
	q.construct_where = true
}

// parse_template parses '{' TriplesTemplate? '}' — triple patterns
// with plain verbs (no property paths) and template-scoped blank
// labels.
@(private = "file")
parse_template :: proc(p: ^Parser) -> ^Basic_Pattern {
	if !at(p, .L_Brace) {
		fail_current(p, .Expected_Group)
		return nil
	}
	advance(p)
	bp := new(Basic_Pattern, p.allocator)
	bp.pos = token_pos(p.tok)
	bp.triples = make([dynamic]Triple_Pattern, p.allocator)
	p.in_template = true
	if starts_triples(p) {
		parse_triples_block(p, bp)
	}
	p.in_template = false
	if p.err.kind != .None {
		return bp
	}
	if !at(p, .R_Brace) {
		fail_current(p, .Unclosed_Group)
		return bp
	}
	advance(p)
	return bp
}

// parse_describe_head parses DESCRIBE ('*' | VarOrIri+) DatasetClause*.
@(private = "file")
parse_describe_head :: proc(p: ^Parser, q: ^Query) {
	q.describe = make([dynamic]Pattern_Node, p.allocator)
	if at(p, .Star) {
		q.select_star = true
		advance(p)
	} else {
		n := 0
		for p.err.kind == .None && (at(p, .Var) || at(p, .IRI_Ref) || at(p, .PName)) {
			append(&q.describe, parse_var_or_iri(p))
			n += 1
		}
		if n == 0 && p.err.kind == .None {
			fail_current(p, .Expected_Variable)
			return
		}
	}
	parse_dataset_clauses(p, q)
}

// --- Token plumbing -------------------------------------------------

@(private)
advance :: proc(p: ^Parser) {
	tok, ok := scanner_next(&p.scanner)
	if !ok {
		p.has_tok = false
		if p.scanner.err.kind != .None && p.err.kind == .None {
			p.err = p.scanner.err
		}
		return
	}
	p.tok = tok
	p.has_tok = true
}

@(private)
fail_at :: proc(p: ^Parser, kind: Error_Kind, tok: Token) {
	if p.err.kind == .None {
		p.err = {kind = kind, offset = tok.offset, line = tok.line, column = tok.column}
	}
}

// fail_here reports an error at the current scanner position (end of
// input reached while a construct was incomplete).
@(private)
fail_here :: proc(p: ^Parser, kind: Error_Kind) {
	if p.err.kind == .None {
		p.err = {
			kind   = kind,
			offset = p.scanner.pos,
			line   = p.scanner.line,
			column = p.scanner.pos - p.scanner.line_start + 1,
		}
	}
}

// fail_current reports at the current token, or at end of input when
// there is none.
@(private)
fail_current :: proc(p: ^Parser, kind: Error_Kind) {
	if p.has_tok {
		fail_at(p, kind, p.tok)
	} else {
		fail_here(p, kind)
	}
}

@(private)
at_keyword :: proc(p: ^Parser, kw: Keyword) -> bool {
	return p.has_tok && p.tok.kind == .Keyword && p.tok.keyword == kw
}

@(private)
at :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	return p.has_tok && p.tok.kind == kind
}

@(private)
token_pos :: proc(tok: Token) -> Position {
	return {offset = tok.offset, line = tok.line, column = tok.column}
}

// --- Prologue -------------------------------------------------------

@(private = "file")
parse_prologue :: proc(p: ^Parser, q: ^Query) {
	for p.err.kind == .None {
		switch {
		case at_keyword(p, .Version):
			// VersionDecl (SPARQL 1.2): a short quoted string.
			advance(p)
			if !at(p, .String_Literal) || p.tok.long_string {
				fail_current(p, .Expected_Version_String)
				return
			}
			q.version = unescape_string_text(p, p.tok)
			if p.err.kind != .None {
				return
			}
			advance(p)
		case at_keyword(p, .Base):
			advance(p)
			if !at(p, .IRI_Ref) {
				fail_current(p, .Expected_IRI)
				return
			}
			// Each BASE resolves against the base in effect before it.
			text := unescape_iri_text(p, p.tok)
			if p.err.kind != .None {
				return
			}
			resolved, ok := iri_resolve(&p.intern, p.base, text, &p.scratch)
			if !ok {
				fail_at(p, .Relative_IRI, p.tok)
				return
			}
			p.base = resolved
			advance(p)
		case at_keyword(p, .Prefix):
			advance(p)
			if !at(p, .PName) || !pname_is_ns(p.tok.text) {
				fail_current(p, .Expected_Prefix_Name)
				return
			}
			prefix_tok := p.tok
			prefix := prefix_tok.text[:len(prefix_tok.text) - 1] // strip ':'
			advance(p)
			if !at(p, .IRI_Ref) {
				fail_current(p, .Expected_IRI)
				return
			}
			expansion := resolve_iri_token(p, p.tok)
			if p.err.kind != .None {
				return
			}
			// Redeclaration replaces; prefix keys borrow the source.
			p.prefixes[prefix] = string(expansion)
			advance(p)
		case:
			return
		}
	}
}

// pname_is_ns reports whether a PName token is a bare PNAME_NS —
// "prefix:" with an empty local part.
@(private = "file")
pname_is_ns :: proc(text: string) -> bool {
	for i in 0 ..< len(text) {
		if text[i] == ':' {
			return i == len(text) - 1
		}
	}
	return false
}

// --- SELECT / datasets / modifiers ---------------------------------

@(private = "file")
parse_select_clause :: proc(p: ^Parser, q: ^Query) {
	advance(p) // SELECT
	if at_keyword(p, .Distinct) {
		q.select_modifier = .Distinct
		advance(p)
	} else if at_keyword(p, .Reduced) {
		q.select_modifier = .Reduced
		advance(p)
	}
	if at(p, .Star) {
		q.select_star = true
		advance(p)
		return
	}
	// (Var | '(' Expression AS Var ')')+
	loop: for p.err.kind == .None {
		switch {
		case at(p, .Var):
			append(&q.projection, Projection{v = var_of(p.tok)})
			advance(p)
		case at(p, .L_Paren):
			advance(p)
			expr := parse_expression(p)
			if p.err.kind != .None {
				destroy_expr(expr, p.allocator)
				return
			}
			if !at_keyword(p, .As) {
				destroy_expr(expr, p.allocator)
				fail_current(p, .Expected_As)
				return
			}
			advance(p)
			if !at(p, .Var) {
				destroy_expr(expr, p.allocator)
				fail_current(p, .Expected_Variable)
				return
			}
			v := var_of(p.tok)
			advance(p)
			if !at(p, .R_Paren) {
				destroy_expr(expr, p.allocator)
				fail_current(p, .Expected_Close_Paren)
				return
			}
			advance(p)
			append(&q.projection, Projection{v = v, expr = expr})
		case:
			break loop
		}
	}
	if len(q.projection) == 0 {
		fail_current(p, .Expected_Projection)
	}
}

@(private = "file")
parse_dataset_clauses :: proc(p: ^Parser, q: ^Query) {
	for p.err.kind == .None && at_keyword(p, .From) {
		pos := token_pos(p.tok)
		advance(p)
		named := false
		if at_keyword(p, .Named) {
			named = true
			advance(p)
		}
		iri, ok := parse_iri(p)
		if !ok {
			return
		}
		append(&q.datasets, Dataset_Clause{iri = iri, named = named, pos = pos})
	}
}

@(private = "file")
parse_solution_modifiers :: proc(p: ^Parser, q: ^Query) {
	if at_keyword(p, .Group) {
		advance(p)
		if !at_keyword(p, .By) {
			fail_current(p, .Expected_Expression)
			return
		}
		advance(p)
		n := 0
		group_loop: for p.err.kind == .None {
			// GroupCondition ::= BuiltInCall | FunctionCall
			//                  | '(' Expression (AS Var)? ')' | Var
			switch {
			case at(p, .Var):
				append(&q.group_by, Group_Condition{expr = var_of(p.tok)})
				advance(p)
				n += 1
			case at(p, .L_Paren):
				advance(p)
				condition := Group_Condition {
					expr = parse_expression(p),
				}
				if p.err.kind != .None {
					destroy_expr(condition.expr, p.allocator)
					return
				}
				if at_keyword(p, .As) {
					advance(p)
					if !at(p, .Var) {
						destroy_expr(condition.expr, p.allocator)
						fail_current(p, .Expected_Variable)
						return
					}
					condition.v = var_of(p.tok)
					condition.has_var = true
					advance(p)
				}
				if !at(p, .R_Paren) {
					destroy_expr(condition.expr, p.allocator)
					fail_current(p, .Expected_Close_Paren)
					return
				}
				advance(p)
				append(&q.group_by, condition)
				n += 1
			case at(p, .IRI_Ref), at(p, .PName),
			     p.has_tok && p.tok.kind == .Keyword && order_constraint_keyword(p.tok.keyword):
				condition := Group_Condition {
					expr = parse_constraint(p),
				}
				if p.err.kind != .None {
					destroy_expr(condition.expr, p.allocator)
					return
				}
				append(&q.group_by, condition)
				n += 1
			case:
				if n == 0 {
					fail_current(p, .Expected_Expression)
					return
				}
				break group_loop
			}
		}
	}
	if at_keyword(p, .Having) {
		advance(p)
		n := 0
		having_loop: for p.err.kind == .None {
			switch {
			case at(p, .L_Paren), at(p, .IRI_Ref), at(p, .PName),
			     p.has_tok && p.tok.kind == .Keyword && order_constraint_keyword(p.tok.keyword):
				condition := parse_constraint(p)
				if p.err.kind != .None {
					destroy_expr(condition, p.allocator)
					return
				}
				append(&q.having, condition)
				n += 1
			case:
				if n == 0 {
					fail_current(p, .Expected_Expression)
					return
				}
				break having_loop
			}
		}
	}
	if at_keyword(p, .Order) {
		advance(p)
		if !at_keyword(p, .By) {
			fail_current(p, .Expected_Variable)
			return
		}
		advance(p)
		n := 0
		order: for p.err.kind == .None {
			// OrderCondition ::= (ASC|DESC) BrackettedExpression
			//                  | Constraint | Var
			switch {
			case at(p, .Var):
				append(&q.order, Order_Condition{expr = var_of(p.tok), direction = .Ascending})
				advance(p)
				n += 1
			case at_keyword(p, .Asc) || at_keyword(p, .Desc):
				direction := Order_Direction.Ascending if p.tok.keyword == .Asc else .Descending
				advance(p)
				expr := parse_bracketted(p)
				if p.err.kind != .None {
					destroy_expr(expr, p.allocator)
					return
				}
				append(&q.order, Order_Condition{expr = expr, direction = direction})
				n += 1
			case at(p, .L_Paren), at(p, .IRI_Ref), at(p, .PName),
			     p.has_tok && p.tok.kind == .Keyword && order_constraint_keyword(p.tok.keyword):
				expr := parse_constraint(p)
				if p.err.kind != .None {
					destroy_expr(expr, p.allocator)
					return
				}
				append(&q.order, Order_Condition{expr = expr, direction = .Ascending})
				n += 1
			case:
				if n == 0 {
					fail_current(p, .Expected_Variable)
					return
				}
				break order
			}
		}
	}
	limit_seen, offset_seen := false, false
	for p.err.kind == .None {
		switch {
		case at_keyword(p, .Limit) && !limit_seen:
			advance(p)
			q.limit = expect_unsigned_integer(p)
			limit_seen = true
		case at_keyword(p, .Offset) && !offset_seen:
			advance(p)
			q.offset = expect_unsigned_integer(p)
			offset_seen = true
		case:
			return
		}
	}
}

// order_constraint_keyword reports whether a keyword can start a
// Constraint (a BuiltInCall form, aggregates included) — as opposed to
// a clause keyword like LIMIT that ends a condition list.
@(private = "file")
order_constraint_keyword :: proc(kw: Keyword) -> bool {
	if kw == .Exists || kw == .Not || kw == .Bound || aggregate_keyword(kw) {
		return true
	}
	_, _, ok := builtin_arity(kw)
	return ok
}

@(private = "file")
expect_unsigned_integer :: proc(p: ^Parser) -> int {
	if !at(p, .Integer) || len(p.tok.text) == 0 || p.tok.text[0] == '+' || p.tok.text[0] == '-' {
		fail_current(p, .Expected_Integer)
		return -1
	}
	value, ok := strconv.parse_int(p.tok.text, 10)
	if !ok || value < 0 {
		fail_at(p, .Expected_Integer, p.tok)
		return -1
	}
	advance(p)
	return value
}

@(private)
var_of :: proc(tok: Token) -> Var {
	return {name = tok.text, pos = token_pos(tok)}
}

// --- Group graph patterns -------------------------------------------

@(private)
parse_group :: proc(p: ^Parser) -> ^Group_Pattern {
	if !at(p, .L_Brace) {
		fail_current(p, .Expected_Group)
		return nil
	}
	if p.depth >= MAX_DEPTH {
		fail_at(p, .Nesting_Too_Deep, p.tok)
		return nil
	}
	p.depth += 1
	defer p.depth -= 1

	g := new(Group_Pattern, p.allocator)
	g.pos = token_pos(p.tok)
	g.elements = make([dynamic]Pattern, p.allocator)
	advance(p) // '{'

	// SubSelect: the group's whole content is a subquery.
	if at_keyword(p, .Select) {
		ss := new(Sub_Select, p.allocator)
		ss.pos = g.pos
		append(&g.elements, Pattern(ss))
		ss.query = parse_sub_select(p)
		if p.err.kind != .None {
			return g
		}
		if !at(p, .R_Brace) {
			fail_current(p, .Unclosed_Group)
			return g
		}
		advance(p)
		return g
	}

	for p.err.kind == .None {
		switch {
		case at(p, .R_Brace):
			advance(p)
			return g
		case starts_triples(p):
			bp := new(Basic_Pattern, p.allocator)
			bp.pos = token_pos(p.tok)
			bp.triples = make([dynamic]Triple_Pattern, p.allocator)
			p.bgp_id += 1
			append(&g.elements, Pattern(bp))
			parse_triples_block(p, bp)
		case at(p, .L_Brace):
			append(&g.elements, parse_group_or_union(p))
			accept_dot(p)
		case at_keyword(p, .Optional):
			o := new(Optional_Pattern, p.allocator)
			o.pos = token_pos(p.tok)
			advance(p)
			o.group = parse_group(p)
			append(&g.elements, Pattern(o))
			accept_dot(p)
		case at_keyword(p, .Graph):
			gp := new(Graph_Pattern, p.allocator)
			gp.pos = token_pos(p.tok)
			advance(p)
			gp.graph = parse_var_or_iri(p)
			if p.err.kind == .None {
				gp.group = parse_group(p)
			}
			append(&g.elements, Pattern(gp))
			accept_dot(p)
		case at_keyword(p, .Filter):
			f := new(Filter_Pattern, p.allocator)
			f.pos = token_pos(p.tok)
			advance(p)
			append(&g.elements, Pattern(f))
			f.condition = parse_constraint(p)
			accept_dot(p)
		case at_keyword(p, .Bind):
			b := new(Bind_Pattern, p.allocator)
			b.pos = token_pos(p.tok)
			advance(p)
			// The BIND node joins the group only after the freshness
			// check below, so the in-scope walk sees its predecessors.
			if !at(p, .L_Paren) {
				append(&g.elements, Pattern(b))
				fail_current(p, .Expected_Expression)
				return g
			}
			advance(p)
			append(&g.elements, Pattern(b))
			b.expr = parse_expression(p)
			if p.err.kind != .None {
				return g
			}
			if !at_keyword(p, .As) {
				fail_current(p, .Expected_As)
				return g
			}
			advance(p)
			if !at(p, .Var) {
				fail_current(p, .Expected_Variable)
				return g
			}
			b.v = var_of(p.tok)
			// §19.8: the BIND target must not already be in scope in
			// this group (the elements before the BIND, which include
			// the just-ended triples block).
			if var_in_scope_of_elements(p, g.elements[:len(g.elements) - 1], b.v.name) {
				fail_at(p, .Variable_In_Scope, p.tok)
				return g
			}
			advance(p)
			if !at(p, .R_Paren) {
				fail_current(p, .Expected_Close_Paren)
				return g
			}
			advance(p)
			accept_dot(p)
		case at_keyword(p, .Minus):
			m := new(Minus_Pattern, p.allocator)
			m.pos = token_pos(p.tok)
			advance(p)
			append(&g.elements, Pattern(m))
			m.group = parse_group(p)
			accept_dot(p)
		case at_keyword(p, .Values):
			append(&g.elements, Pattern(parse_values(p)))
			accept_dot(p)
		case !p.has_tok:
			fail_here(p, .Unclosed_Group)
			return g
		case:
			fail_at(p, .Expected_Pattern, p.tok)
			return g
		}
	}
	return g
}

@(private = "file")
new_query :: proc(p: ^Parser) -> ^Query {
	q := new(Query, p.allocator)
	q.limit = -1
	q.offset = -1
	q.projection = make([dynamic]Projection, p.allocator)
	q.datasets = make([dynamic]Dataset_Clause, p.allocator)
	q.group_by = make([dynamic]Group_Condition, p.allocator)
	q.having = make([dynamic]Expr, p.allocator)
	q.order = make([dynamic]Order_Condition, p.allocator)
	return q
}

// parse_sub_select parses SubSelect: SelectClause WhereClause
// SolutionModifier ValuesClause, with SELECT as the current token.
@(private = "file")
parse_sub_select :: proc(p: ^Parser) -> ^Query {
	sq := new_query(p)
	sq.form = .Select
	parse_select_clause(p, sq)
	if p.err.kind != .None {
		return sq
	}
	if at_keyword(p, .Where) {
		advance(p)
	}
	sq.where_clause = parse_group(p)
	if p.err.kind != .None {
		return sq
	}
	parse_solution_modifiers(p, sq)
	if p.err.kind != .None {
		return sq
	}
	if at_keyword(p, .Values) {
		sq.values = parse_values(p)
	}
	check_query_scopes(p, sq)
	return sq
}

// parse_group_or_union parses GroupGraphPattern (UNION GroupGraphPattern)*
// starting at a '{'.
@(private = "file")
parse_group_or_union :: proc(p: ^Parser) -> Pattern {
	first := parse_group(p)
	if p.err.kind != .None || !at_keyword(p, .Union) {
		return first
	}
	u := new(Union_Pattern, p.allocator)
	u.pos = first != nil ? first.pos : Position{}
	u.alternatives = make([dynamic]^Group_Pattern, p.allocator)
	append(&u.alternatives, first)
	for at_keyword(p, .Union) && p.err.kind == .None {
		advance(p)
		append(&u.alternatives, parse_group(p))
	}
	return u
}

// accept_dot consumes the optional '.' the grammar allows after a
// GraphPatternNotTriples.
@(private = "file")
accept_dot :: proc(p: ^Parser) {
	if at(p, .Dot) {
		advance(p)
	}
}

@(private)
starts_triples :: proc(p: ^Parser) -> bool {
	if !p.has_tok {
		return false
	}
	#partial switch p.tok.kind {
	case .Var, .IRI_Ref, .PName, .Blank_Node_Label, .String_Literal,
	     .Integer, .Decimal, .Double, .Boolean, .Nil, .Anon, .L_Paren, .L_Bracket,
	     .Reified_Open, .Triple_Term_Open:
		return true
	}
	return false
}

@(private)
parse_var_or_iri :: proc(p: ^Parser) -> Pattern_Node {
	if at(p, .Var) {
		v := var_of(p.tok)
		advance(p)
		return v
	}
	iri, ok := parse_iri(p)
	if !ok {
		return nil
	}
	return iri
}

// --- Triple patterns ------------------------------------------------

// parse_triples_block parses TriplesBlock: TriplesSameSubject ('.'
// TriplesBlock?)?, appending expanded triple patterns to bp in
// syntactic order.
@(private = "file")
parse_triples_block :: proc(p: ^Parser, bp: ^Basic_Pattern) {
	for p.err.kind == .None {
		parse_triples_same_subject(p, bp)
		if p.err.kind != .None {
			return
		}
		if !at(p, .Dot) {
			return
		}
		advance(p)
		if !starts_triples(p) {
			return
		}
	}
}

@(private = "file")
parse_triples_same_subject :: proc(p: ^Parser, bp: ^Basic_Pattern) {
	pos := token_pos(p.tok)
	if at(p, .L_Paren) || at(p, .L_Bracket) {
		// TriplesNode PropertyList — the property list may be empty.
		// (A bare ANON '[ ]' is a GraphTerm, not a TriplesNode, and
		// takes the VarOrTerm path with its required property list.)
		subject := parse_triples_node(p, bp)
		if p.err.kind != .None {
			return
		}
		if starts_verb(p) {
			parse_property_list(p, bp, subject, pos)
		}
		return
	}
	if at(p, .Reified_Open) {
		// reifiedTriple PropertyListPath — the list may be empty; the
		// desugared rdf:reifies triple alone is a valid statement.
		subject := parse_reified_triple(p, bp)
		if p.err.kind != .None {
			return
		}
		if starts_verb(p) {
			parse_property_list(p, bp, subject, pos)
		}
		return
	}
	subject := parse_var_or_term(p)
	if p.err.kind != .None {
		return
	}
	if subject == nil {
		fail_current(p, .Expected_Subject)
		return
	}
	if !starts_verb(p) {
		fail_current(p, .Expected_Predicate)
		return
	}
	parse_property_list(p, bp, subject, pos)
}

@(private)
starts_verb :: proc(p: ^Parser) -> bool {
	if at(p, .A) || at(p, .Var) {
		return true
	}
	if p.in_template {
		// Templates take plain verbs only — no property paths.
		return at(p, .IRI_Ref) || at(p, .PName)
	}
	return starts_path(p)
}

// parse_property_list parses PropertyListNotEmpty: Verb ObjectList
// (';' (Verb ObjectList)?)*.
@(private)
parse_property_list :: proc(p: ^Parser, bp: ^Basic_Pattern, subject: Pattern_Node, pos: Position) {
	for p.err.kind == .None {
		predicate := parse_verb(p) if p.in_template else parse_verb_path(p)
		if p.err.kind != .None {
			return
		}
		// ObjectList: Object (',' Object)*.
		for p.err.kind == .None {
			object := parse_graph_node(p, bp)
			if p.err.kind != .None {
				return
			}
			if object == nil {
				fail_current(p, .Expected_Object)
				return
			}
			append(&bp.triples, Triple_Pattern{subject = subject, predicate = predicate, object = object, pos = pos})
			if at(p, .Tilde) || at(p, .Annotation_Open) {
				// A path triple cannot be reified or annotated (sparql12
				// annotated-*-path tests); the stray token errors upstream.
				if _, is_path := predicate.(^Path_Expr); !is_path {
					parse_annotations(p, bp, subject, predicate, object, pos)
					if p.err.kind != .None {
						return
					}
				}
			}
			if !at(p, .Comma) {
				break
			}
			advance(p)
		}
		// ';' continues with another verb; a trailing ';' is allowed.
		if !at(p, .Semicolon) {
			return
		}
		for at(p, .Semicolon) {
			advance(p)
		}
		if !starts_verb(p) {
			return
		}
	}
}

@(private)
parse_verb :: proc(p: ^Parser) -> Pattern_Node {
	switch {
	case at(p, .A):
		advance(p)
		return rdf.RDF_TYPE
	case at(p, .Var):
		v := var_of(p.tok)
		advance(p)
		return v
	case at(p, .IRI_Ref), at(p, .PName):
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		return iri
	}
	fail_current(p, .Expected_Predicate)
	return nil
}

// parse_graph_node parses GraphNode: a variable, a graph term, or a
// nested TriplesNode (whose expansion triples append to bp).
@(private = "file")
parse_graph_node :: proc(p: ^Parser, bp: ^Basic_Pattern) -> Pattern_Node {
	if at(p, .L_Paren) || at(p, .L_Bracket) {
		return parse_triples_node(p, bp)
	}
	if at(p, .Reified_Open) {
		return parse_reified_triple(p, bp)
	}
	return parse_var_or_term(p)
}

// parse_var_or_term parses VarOrTerm — a variable or a GraphTerm. Only
// the tokens that can start one are consumed; anything else returns nil
// with no error so callers report their own production.
@(private)
parse_var_or_term :: proc(p: ^Parser) -> Pattern_Node {
	if !p.has_tok {
		return nil
	}
	#partial switch p.tok.kind {
	case .Var:
		v := var_of(p.tok)
		advance(p)
		return v
	case .IRI_Ref, .PName:
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		return iri
	case .Blank_Node_Label:
		label := unescape_local_text(p, p.tok)
		if p.err.kind != .None {
			return nil
		}
		// §19.6: a blank node label cannot be used in two different
		// basic graph patterns of the same query. CONSTRUCT templates
		// are not BGPs; their labels are template-scoped generators.
		if !p.in_template {
			if first, seen := p.blank_first[label]; seen {
				if first != p.bgp_id {
					fail_at(p, .Blank_Label_Reuse, p.tok)
					return nil
				}
			} else {
				p.blank_first[label] = p.bgp_id
			}
		}
		advance(p)
		return rdf.Blank_Node(label)
	case .String_Literal:
		lit, ok := parse_rdf_literal(p)
		if !ok {
			return nil
		}
		return lit
	case .Integer:
		lit := rdf.literal_typed(p.tok.text, rdf.XSD_INTEGER)
		advance(p)
		return lit
	case .Decimal:
		lit := rdf.literal_typed(p.tok.text, rdf.XSD_DECIMAL)
		advance(p)
		return lit
	case .Double:
		lit := rdf.literal_typed(p.tok.text, rdf.XSD_DOUBLE)
		advance(p)
		return lit
	case .Boolean:
		// Normalized to the canonical lexical forms; the keyword is
		// case-insensitive but xsd:boolean's lexical space is not.
		lexical := "true" if (p.tok.text[0] == 't' || p.tok.text[0] == 'T') else "false"
		advance(p)
		return rdf.literal_typed(lexical, rdf.XSD_BOOLEAN)
	case .Nil:
		advance(p)
		return rdf.RDF_NIL
	case .Anon:
		// A bare '[ ]' term is a fresh blank node.
		advance(p)
		return fresh_blank(p)
	case .Triple_Term_Open:
		return parse_triple_term(p, .Pattern)
	}
	return nil
}

// parse_rdf_literal parses RDFLiteral: String (LANGTAG | '^^' iri)?.
// Shared between graph patterns and expressions.
@(private)
parse_rdf_literal :: proc(p: ^Parser) -> (lit: rdf.Literal, ok: bool) {
	lexical := unescape_string_text(p, p.tok)
	if p.err.kind != .None {
		return {}, false
	}
	advance(p)
	switch {
	case at(p, .Lang_Tag):
		tag := p.tok.text
		// The SPARQL 1.2 direction suffix splits at '--'.
		for i in 0 ..< len(tag) - 1 {
			if tag[i] == '-' && tag[i + 1] == '-' {
				lang, dir_word := tag[:i], tag[i + 2:]
				direction: rdf.Direction
				switch dir_word {
				case "ltr":
					direction = .LTR
				case "rtl":
					direction = .RTL
				case:
					fail_at(p, .Invalid_Direction, p.tok)
					return {}, false
				}
				advance(p)
				return rdf.literal_dir_lang(lexical, lang, direction), true
			}
		}
		advance(p)
		return rdf.literal_lang(lexical, tag), true
	case at(p, .Datatype_Marker):
		advance(p)
		if !at(p, .IRI_Ref) && !at(p, .PName) {
			fail_current(p, .Expected_Datatype)
			return {}, false
		}
		datatype, dt_ok := parse_iri(p)
		if !dt_ok {
			return {}, false
		}
		return rdf.literal_typed(lexical, datatype), true
	}
	return rdf.literal_plain(lexical), true
}

// parse_triples_node parses Collection | BlankNodePropertyList (or the
// ANON token), returning the node that stands for it; the expansion
// triples append to bp.
@(private = "file")
parse_triples_node :: proc(p: ^Parser, bp: ^Basic_Pattern) -> Pattern_Node {
	if p.depth >= MAX_DEPTH {
		fail_at(p, .Nesting_Too_Deep, p.tok)
		return nil
	}
	p.depth += 1
	defer p.depth -= 1

	pos := token_pos(p.tok)
	switch {
	case at(p, .L_Bracket):
		advance(p)
		subject := fresh_blank(p)
		if !starts_verb(p) {
			fail_current(p, .Expected_Predicate)
			return nil
		}
		parse_property_list(p, bp, subject, pos)
		if p.err.kind != .None {
			return nil
		}
		if !at(p, .R_Bracket) {
			fail_current(p, .Unclosed_Property_List)
			return nil
		}
		advance(p)
		return subject

	case at(p, .L_Paren):
		advance(p)
		// The scanner emits NIL for '( )', so a collection here has at
		// least one node.
		head: Pattern_Node
		tail: Pattern_Node
		for p.err.kind == .None && !at(p, .R_Paren) {
			if !p.has_tok {
				fail_here(p, .Unclosed_Collection)
				return nil
			}
			node := parse_graph_node(p, bp)
			if p.err.kind != .None {
				return nil
			}
			if node == nil {
				fail_current(p, .Unclosed_Collection)
				return nil
			}
			cell := fresh_blank(p)
			if head == nil {
				head = cell
			} else {
				append(&bp.triples, Triple_Pattern{subject = tail, predicate = rdf.RDF_REST, object = cell, pos = pos})
			}
			append(&bp.triples, Triple_Pattern{subject = cell, predicate = rdf.RDF_FIRST, object = node, pos = pos})
			tail = cell
		}
		if p.err.kind != .None {
			return nil
		}
		advance(p) // ')'
		append(&bp.triples, Triple_Pattern{subject = tail, predicate = rdf.RDF_REST, object = rdf.RDF_NIL, pos = pos})
		return head
	}
	fail_current(p, .Expected_Object)
	return nil
}

// fresh_blank generates a parser-owned blank node label. The ".b" stem
// cannot collide with user labels: a BLANK_NODE_LABEL can never start
// with '.'.
@(private)
fresh_blank :: proc(p: ^Parser) -> Pattern_Node {
	buf: [24]byte
	buf[0] = '.'
	buf[1] = 'b'
	n := len(strconv.write_int(buf[2:], i64(p.fresh_n), 10))
	p.fresh_n += 1
	return rdf.Blank_Node(rdf.intern(&p.intern, string(buf[:2 + n])))
}

// --- IRIs and lexical materialization -------------------------------

// parse_iri parses iri: IRIREF | PrefixedName, consuming the token.
@(private)
parse_iri :: proc(p: ^Parser) -> (iri: rdf.IRI, ok: bool) {
	switch {
	case at(p, .IRI_Ref):
		iri = resolve_iri_token(p, p.tok)
		if p.err.kind != .None {
			return "", false
		}
		advance(p)
		return iri, true
	case at(p, .PName):
		iri = expand_pname(p, p.tok)
		if p.err.kind != .None {
			return "", false
		}
		advance(p)
		return iri, true
	}
	fail_current(p, .Expected_IRI)
	return "", false
}

// resolve_iri_token materializes an IRIREF token: codepoint escapes
// decoded, then resolved against the base when relative. An absolute,
// escape-free IRIREF borrows the source; everything else is interned.
@(private = "file")
resolve_iri_token :: proc(p: ^Parser, tok: Token) -> rdf.IRI {
	text := unescape_iri_text(p, tok)
	if p.err.kind != .None {
		return ""
	}
	if iri_parse(text).has_scheme {
		return rdf.IRI(text) // absolute: borrowed (or already interned by unescape)
	}
	resolved, ok := iri_resolve(&p.intern, p.base, text, &p.scratch)
	if !ok {
		fail_at(p, .Relative_IRI, tok)
		return ""
	}
	return rdf.IRI(resolved)
}

// expand_pname materializes a PrefixedName token: the declared
// expansion concatenated with the unescaped local part, interned.
@(private = "file")
expand_pname :: proc(p: ^Parser, tok: Token) -> rdf.IRI {
	colon := -1
	for i in 0 ..< len(tok.text) {
		if tok.text[i] == ':' {
			colon = i
			break
		}
	}
	prefix := tok.text[:colon]
	local := tok.text[colon + 1:]
	expansion, declared := p.prefixes[prefix]
	if !declared {
		fail_at(p, .Undefined_Prefix, tok)
		return ""
	}
	if len(local) == 0 {
		return rdf.IRI(expansion)
	}
	clear(&p.unesc)
	append(&p.unesc, expansion)
	if !append_unescaped(p, local, .Local) {
		fail_at(p, .Invalid_Escape, tok)
		return ""
	}
	return rdf.IRI(rdf.intern(&p.intern, string(p.unesc[:])))
}

@(private = "file")
Unescape_Mode :: enum {
	Iri,    // codepoint escapes only
	Text,   // ECHAR + codepoint escapes
	Local,  // PN_LOCAL_ESC + codepoint escapes
}

// unescape_iri_text returns an IRIREF token's text with codepoint
// escapes decoded — borrowed when escape-free, interned otherwise.
@(private = "file")
unescape_iri_text :: proc(p: ^Parser, tok: Token) -> string {
	if !tok.has_escape {
		return tok.text
	}
	clear(&p.unesc)
	if !append_unescaped(p, tok.text, .Iri) {
		fail_at(p, .Invalid_Escape, tok)
		return ""
	}
	return rdf.intern(&p.intern, string(p.unesc[:]))
}

// unescape_string_text returns a string literal's lexical form with
// ECHAR and codepoint escapes decoded.
@(private)
unescape_string_text :: proc(p: ^Parser, tok: Token) -> string {
	if !tok.has_escape {
		return tok.text
	}
	clear(&p.unesc)
	if !append_unescaped(p, tok.text, .Text) {
		fail_at(p, .Invalid_Escape, tok)
		return ""
	}
	return rdf.intern(&p.intern, string(p.unesc[:]))
}

// unescape_local_text returns a blank node label with codepoint escapes
// decoded (labels have no other escape form).
@(private = "file")
unescape_local_text :: proc(p: ^Parser, tok: Token) -> string {
	if !tok.has_escape {
		return tok.text
	}
	clear(&p.unesc)
	if !append_unescaped(p, tok.text, .Local) {
		fail_at(p, .Invalid_Escape, tok)
		return ""
	}
	return rdf.intern(&p.intern, string(p.unesc[:]))
}

// append_unescaped appends text to p.unesc with the mode's escape forms
// decoded: codepoint escapes everywhere, ECHAR in .Text, PN_LOCAL_ESC
// in .Local. The scanner already validated the shapes; false means a
// malformed escape slipped through (defensive, not expected).
@(private = "file")
append_unescaped :: proc(p: ^Parser, text: string, mode: Unescape_Mode) -> bool {
	i := 0
	for i < len(text) {
		c := text[i]
		if c != '\\' {
			append(&p.unesc, c)
			i += 1
			continue
		}
		if i + 1 >= len(text) {
			return false
		}
		e := text[i + 1]
		if e == 'u' || e == 'U' {
			digits := 4 if e == 'u' else 8
			if i + 2 + digits > len(text) {
				return false
			}
			value: u32
			for k in 0 ..< digits {
				d := text[i + 2 + k]
				value <<= 4
				switch {
				case d >= '0' && d <= '9':
					value |= u32(d - '0')
				case d >= 'a' && d <= 'f':
					value |= u32(d - 'a' + 10)
				case d >= 'A' && d <= 'F':
					value |= u32(d - 'A' + 10)
				case:
					return false
				}
			}
			encoded, n := utf8.encode_rune(rune(value))
			append(&p.unesc, ..encoded[:n])
			i += 2 + digits
			continue
		}
		switch mode {
		case .Text:
			switch e {
			case 't':
				append(&p.unesc, '\t')
			case 'b':
				append(&p.unesc, '\b')
			case 'n':
				append(&p.unesc, '\n')
			case 'r':
				append(&p.unesc, '\r')
			case 'f':
				append(&p.unesc, '\f')
			case '"', '\'', '\\':
				append(&p.unesc, e)
			case:
				return false
			}
		case .Local:
			switch e {
			case '_', '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '@', '%':
				append(&p.unesc, e)
			case:
				return false
			}
		case .Iri:
			return false
		}
		i += 2
	}
	return true
}
