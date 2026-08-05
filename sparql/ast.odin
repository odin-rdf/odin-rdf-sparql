// The abstract syntax tree the query parser produces: a faithful
// representation of the query's syntax, prior to §18.2 algebra
// translation (which arrives with SPARQL-T-0007). Terms reuse rdf.Term's
// component types from the parser collection as-is — no Term_ID appears
// anywhere at this layer; binding terms to store IDs is the evaluation
// initiative's concern.
//
// Ownership: all nodes and their dynamic arrays are allocated from the
// parser's allocator and freed by parser_destroy. Strings inside terms
// either borrow the caller-owned query text or are owned by the
// parser's intern table — the AST itself never owns a string.
package sparql

import rdf "rdf:rdf"

// Position locates a construct in the query text for error reporting
// and later scope diagnostics. Line and column are 1-based; column is
// in bytes.
Position :: struct {
	offset: int,
	line:   int,
	column: int,
}

// A query variable (?name or $name); the two sigils are one namespace.
Var :: struct {
	name: string,
	pos:  Position,
}

// Pattern_Node is one position of a triple pattern: an RDF term or a
// variable. The rdf.Term component types are flattened in rather than
// nested as a union-in-union so call sites switch over one level.
// ^Path_Expr appears only in predicate position (a composite property
// path; a plain-IRI path stays rdf.IRI). SPARQL 1.2 triple terms join
// the union with SPARQL-T-0008.
Pattern_Node :: union {
	rdf.IRI,
	rdf.Blank_Node,
	rdf.Literal,
	Var,
	^Path_Expr,
}

Path_Op :: enum {
	Link, // iri (or 'a'); the iri field
	Sequence, // children joined by '/'
	Alternative, // children joined by '|'
	Inverse, // '^' child
	Zero_Or_More, // child '*'
	One_Or_More, // child '+'
	Zero_Or_One, // child '?'
	Negated_Set, // '!' of Link/Inverse-of-Link children
}

// Path_Expr is one node of a property-path expression. Link carries
// the iri; every other op carries children (one for Inverse and the
// modifiers, two or more for Sequence/Alternative, one or more Link or
// Inverse-of-Link members for Negated_Set).
Path_Expr :: struct {
	op:       Path_Op,
	iri:      rdf.IRI, // Link only
	children: [dynamic]^Path_Expr,
	pos:      Position,
}

Triple_Pattern :: struct {
	subject:   Pattern_Node,
	predicate: Pattern_Node,
	object:    Pattern_Node,
	pos:       Position,
}

// Basic_Pattern is a TriplesBlock: the syntactic unit that becomes a
// BGP under §18.2, and the scope unit for blank-node label reuse.
Basic_Pattern :: struct {
	triples: [dynamic]Triple_Pattern,
	pos:     Position,
}

Group_Pattern :: struct {
	elements: [dynamic]Pattern,
	pos:      Position,
}

Optional_Pattern :: struct {
	group: ^Group_Pattern,
	pos:   Position,
}

Union_Pattern :: struct {
	alternatives: [dynamic]^Group_Pattern, // always 2 or more
	pos:          Position,
}

Graph_Pattern :: struct {
	graph: Pattern_Node, // rdf.IRI or Var
	group: ^Group_Pattern,
	pos:   Position,
}

Filter_Pattern :: struct {
	condition: Expr,
	pos:       Position,
}

Bind_Pattern :: struct {
	expr: Expr,
	v:    Var,
	pos:  Position,
}

Minus_Pattern :: struct {
	group: ^Group_Pattern,
	pos:   Position,
}

// Values_Pattern is a VALUES data block, inline in a group or trailing
// on the whole query. A nil Pattern_Node cell is UNDEF. Every row's
// arity equals len(vars) — the parser enforces it.
Values_Pattern :: struct {
	vars: [dynamic]Var,
	rows: [dynamic][dynamic]Pattern_Node,
	pos:  Position,
}

// Sub_Select is a subquery: '{' SELECT … '}' as a group graph pattern.
Sub_Select :: struct {
	query: ^Query,
	pos:   Position,
}

// Pattern is one element of a group graph pattern. SERVICE is out of
// scope for the engine (vision: no federation).
Pattern :: union {
	^Basic_Pattern,
	^Group_Pattern,
	^Optional_Pattern,
	^Union_Pattern,
	^Graph_Pattern,
	^Filter_Pattern,
	^Bind_Pattern,
	^Minus_Pattern,
	^Values_Pattern,
	^Sub_Select,
}

Query_Form :: enum {
	Select,
	Ask,
	Construct,
	Describe,
}

Select_Modifier :: enum {
	None,
	Distinct,
	Reduced,
}

Dataset_Clause :: struct {
	iri:   rdf.IRI,
	named: bool, // FROM NAMED as opposed to FROM
	pos:   Position,
}

Order_Direction :: enum {
	Ascending,
	Descending,
}

Order_Condition :: struct {
	expr:      Expr, // a bare Var, a bracketted expression, or a Constraint call
	direction: Order_Direction,
}

// Projection is one SELECT clause entry: a bare variable (expr nil) or
// an `(expr AS ?var)` binding.
Projection :: struct {
	v:    Var,
	expr: Expr, // nil for a bare variable
}

// Group_Condition is one GROUP BY entry: a variable, a Constraint
// call, or '(' Expression (AS Var)? ')'.
Group_Condition :: struct {
	expr:    Expr,
	v:       Var, // the AS binding; name == "" when absent
	has_var: bool,
}

// Query is a parsed SPARQL query (or SubSelect, which reuses the type
// with only the SELECT-relevant fields populated).
Query :: struct {
	form:            Query_Form,
	select_modifier: Select_Modifier,
	select_star:     bool, // SELECT * or DESCRIBE *
	projection:      [dynamic]Projection, // SELECT only
	template:        ^Basic_Pattern, // CONSTRUCT only
	construct_where: bool, // CONSTRUCT WHERE shorthand: template doubles as pattern
	describe:        [dynamic]Pattern_Node, // DESCRIBE targets (IRIs and vars)
	datasets:        [dynamic]Dataset_Clause,
	where_clause:    ^Group_Pattern, // nil for DESCRIBE without WHERE and CONSTRUCT WHERE
	group_by:        [dynamic]Group_Condition,
	having:          [dynamic]Expr,
	order:           [dynamic]Order_Condition,
	limit:           int, // -1 when absent
	offset:          int, // -1 when absent
	values:          ^Values_Pattern, // trailing VALUES clause; nil when absent
}

// destroy_query frees a query tree's nodes and arrays. Strings are not
// touched: they are either borrowed from the source or owned by the
// parser's intern table (freed with it). Called by parser_destroy.
destroy_query :: proc(q: ^Query, allocator := context.allocator) {
	if q == nil {
		return
	}
	for projection in q.projection {
		destroy_expr(projection.expr, allocator)
	}
	delete(q.projection)
	if q.template != nil {
		destroy_basic(q.template, allocator)
	}
	for target in q.describe {
		destroy_pattern_node(target, allocator)
	}
	delete(q.describe)
	delete(q.datasets)
	for condition in q.group_by {
		destroy_expr(condition.expr, allocator)
	}
	delete(q.group_by)
	for condition in q.having {
		destroy_expr(condition, allocator)
	}
	delete(q.having)
	for condition in q.order {
		destroy_expr(condition.expr, allocator)
	}
	delete(q.order)
	destroy_group(q.where_clause, allocator)
	if q.values != nil {
		destroy_values(q.values, allocator)
	}
	free(q, allocator)
}

@(private)
destroy_basic :: proc(bp: ^Basic_Pattern, allocator := context.allocator) {
	for tp in bp.triples {
		destroy_pattern_node(tp.subject, allocator)
		destroy_pattern_node(tp.predicate, allocator)
		destroy_pattern_node(tp.object, allocator)
	}
	delete(bp.triples)
	free(bp, allocator)
}

@(private)
destroy_pattern_node :: proc(node: Pattern_Node, allocator := context.allocator) {
	if path, is_path := node.(^Path_Expr); is_path {
		destroy_path(path, allocator)
	}
}

@(private)
destroy_path :: proc(path: ^Path_Expr, allocator := context.allocator) {
	if path == nil {
		return
	}
	for child in path.children {
		destroy_path(child, allocator)
	}
	delete(path.children)
	free(path, allocator)
}

@(private)
destroy_values :: proc(v: ^Values_Pattern, allocator := context.allocator) {
	delete(v.vars)
	for row in v.rows {
		delete(row)
	}
	delete(v.rows)
	free(v, allocator)
}

@(private)
destroy_group :: proc(g: ^Group_Pattern, allocator := context.allocator) {
	if g == nil {
		return
	}
	for element in g.elements {
		destroy_pattern(element, allocator)
	}
	delete(g.elements)
	free(g, allocator)
}

@(private)
destroy_pattern :: proc(pat: Pattern, allocator := context.allocator) {
	switch v in pat {
	case ^Basic_Pattern:
		destroy_basic(v, allocator)
	case ^Group_Pattern:
		destroy_group(v, allocator)
	case ^Optional_Pattern:
		destroy_group(v.group, allocator)
		free(v, allocator)
	case ^Union_Pattern:
		for alternative in v.alternatives {
			destroy_group(alternative, allocator)
		}
		delete(v.alternatives)
		free(v, allocator)
	case ^Graph_Pattern:
		destroy_group(v.group, allocator)
		free(v, allocator)
	case ^Filter_Pattern:
		destroy_expr(v.condition, allocator)
		free(v, allocator)
	case ^Bind_Pattern:
		destroy_expr(v.expr, allocator)
		free(v, allocator)
	case ^Minus_Pattern:
		destroy_group(v.group, allocator)
		free(v, allocator)
	case ^Values_Pattern:
		destroy_values(v, allocator)
	case ^Sub_Select:
		destroy_query(v.query, allocator)
		free(v, allocator)
	}
}
