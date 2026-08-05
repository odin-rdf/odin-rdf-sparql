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
// SPARQL 1.2 triple terms join the union with SPARQL-T-0008.
Pattern_Node :: union {
	rdf.IRI,
	rdf.Blank_Node,
	rdf.Literal,
	Var,
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

// Pattern is one element of a group graph pattern. FILTER/BIND arrive
// with SPARQL-T-0004; MINUS, SERVICE, VALUES, and subqueries with
// SPARQL-T-0005.
Pattern :: union {
	^Basic_Pattern,
	^Group_Pattern,
	^Optional_Pattern,
	^Union_Pattern,
	^Graph_Pattern,
}

Query_Form :: enum {
	Select,
	Ask,
	// Construct and Describe arrive with SPARQL-T-0005.
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

// Order_Condition holds a variable for now; general expressions arrive
// with SPARQL-T-0004 and widen this in place.
Order_Condition :: struct {
	v:         Var,
	direction: Order_Direction,
}

// Query is a parsed SPARQL query. GROUP BY/HAVING and the remaining
// query forms arrive with later tasks and extend this struct.
Query :: struct {
	form:            Query_Form,
	select_modifier: Select_Modifier,
	select_star:     bool,
	projection:      [dynamic]Var, // empty when select_star or form == .Ask
	datasets:        [dynamic]Dataset_Clause,
	where_clause:           ^Group_Pattern,
	order:           [dynamic]Order_Condition,
	limit:           int, // -1 when absent
	offset:          int, // -1 when absent
}

// destroy_query frees a query tree's nodes and arrays. Strings are not
// touched: they are either borrowed from the source or owned by the
// parser's intern table (freed with it). Called by parser_destroy.
destroy_query :: proc(q: ^Query, allocator := context.allocator) {
	if q == nil {
		return
	}
	delete(q.projection)
	delete(q.datasets)
	delete(q.order)
	destroy_group(q.where_clause, allocator)
	free(q, allocator)
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
		delete(v.triples)
		free(v, allocator)
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
	}
}
