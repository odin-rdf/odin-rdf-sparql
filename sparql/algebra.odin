// The SPARQL algebra (SPARQL-T-0006): the operator tree §18 defines
// and the §18.2 translation (SPARQL-T-0007) produces. This is the
// contract the evaluation initiative consumes — evaluation walks this
// tree and nothing else.
//
// Ownership: algebra nodes and their dynamic arrays are allocated from
// the parser's allocator and freed by destroy_algebra. Terms (Var,
// rdf.IRI, rdf.Literal, …) are values whose strings belong to the
// parse — borrowed from the query text or owned by the parser's intern
// table — and Expr trees referenced by algebra nodes are owned by
// whoever built them (the AST for expressions lifted out of it, the
// translation for ones it synthesizes; the translation tracks which).
// destroy_algebra therefore frees the operator tree only, never an
// Expr — the translation's destroy handles those exactly once.
package sparql

// Alg_Triple is one triple pattern of a BGP. Predicates here are
// always simple (Var or rdf.IRI); composite paths translate to
// Alg_Path operators instead.
Alg_Triple :: struct {
	subject:   Pattern_Node,
	predicate: Pattern_Node,
	object:    Pattern_Node,
}

// Alg_BGP is a basic graph pattern: the join-of-triple-patterns leaf
// the store's match interface evaluates directly.
Alg_BGP :: struct {
	triples: [dynamic]Alg_Triple,
}

// Alg_Path is a triple pattern whose predicate is a composite property
// path (§18.4 translation output for the path forms that do not
// simplify to plain triples).
Alg_Path :: struct {
	subject: Pattern_Node,
	path:    ^Path_Expr,
	object:  Pattern_Node,
}

// Alg_Join is the binary Join(left, right) of §18.5.
Alg_Join :: struct {
	left, right: Algebra,
}

// Alg_Left_Join is LeftJoin(left, right, expr) — OPTIONAL, with the
// filter condition hoisted per §18.2.2.3. condition is nil when the
// OPTIONAL carried no filter.
Alg_Left_Join :: struct {
	left, right: Algebra,
	condition:   Expr,
}

// Alg_Filter is Filter(conditions, input). Multiple collected FILTERs
// stay separate here (printed as an exprlist), preserving the
// grammar's grouping for the evaluator.
Alg_Filter :: struct {
	conditions: [dynamic]Expr,
	input:      Algebra,
}

// Alg_Union is the binary Union of §18.5; n-way unions are
// left-leaning chains, as the translation builds them.
Alg_Union :: struct {
	left, right: Algebra,
}

// Alg_Minus is Minus(left, right).
Alg_Minus :: struct {
	left, right: Algebra,
}

// Alg_Graph is Graph(graph, input) — graph is a Var or rdf.IRI.
Alg_Graph :: struct {
	graph: Pattern_Node,
	input: Algebra,
}

// Alg_Binding is one (variable, expression) pair of an Extend or a
// Group's aggregate list.
Alg_Binding :: struct {
	v:    Var,
	expr: Expr,
}

// Alg_Extend is Extend(bindings, input) — BIND and projection
// expressions. Bindings apply in order; each may reference earlier
// ones.
Alg_Extend :: struct {
	bindings: [dynamic]Alg_Binding,
	input:    Algebra,
}

// Alg_Group is Group(by, aggregates, input) per §18.5.1: the grouping
// keys and the aggregate expressions computed per group, each bound to
// a translation-generated variable (named ".0", ".1", … — impossible
// as user syntax) that Extend layers above then reference.
Alg_Group :: struct {
	by:         [dynamic]Group_Condition,
	aggregates: [dynamic]Alg_Binding, // expr is always ^Aggregate
	input:      Algebra,
}

// Alg_Order is OrderBy(conditions, input).
Alg_Order :: struct {
	conditions: [dynamic]Order_Condition,
	input:      Algebra,
}

// Alg_Project is Project(vars, input).
Alg_Project :: struct {
	vars:  [dynamic]Var,
	input: Algebra,
}

// Alg_Distinct is Distinct(input).
Alg_Distinct :: struct {
	input: Algebra,
}

// Alg_Reduced is Reduced(input).
Alg_Reduced :: struct {
	input: Algebra,
}

// Alg_Slice is Slice(start, length, input) — OFFSET and LIMIT; -1
// means absent.
Alg_Slice :: struct {
	start:  int,
	length: int,
	input:  Algebra,
}

// Alg_Table is an inline solution sequence: VALUES data, or the unit
// table (the empty group pattern's identity element) when unit is
// set. A nil cell is UNDEF.
Alg_Table :: struct {
	unit: bool,
	vars: [dynamic]Var,
	rows: [dynamic][dynamic]Pattern_Node,
}

// Algebra is one operator of the §18 tree. The zero value (nil) is
// not a valid operator; the translation of an empty group is the unit
// Alg_Table.
Algebra :: union {
	^Alg_BGP,
	^Alg_Path,
	^Alg_Join,
	^Alg_Left_Join,
	^Alg_Filter,
	^Alg_Union,
	^Alg_Minus,
	^Alg_Graph,
	^Alg_Extend,
	^Alg_Group,
	^Alg_Order,
	^Alg_Project,
	^Alg_Distinct,
	^Alg_Reduced,
	^Alg_Slice,
	^Alg_Table,
}

// destroy_algebra frees the operator tree and its arrays. Expr trees
// and term strings are not touched — see the package ownership note.
destroy_algebra :: proc(a: Algebra, allocator := context.allocator) {
	switch v in a {
	case ^Alg_BGP:
		delete(v.triples)
		free(v, allocator)
	case ^Alg_Path:
		free(v, allocator)
	case ^Alg_Join:
		destroy_algebra(v.left, allocator)
		destroy_algebra(v.right, allocator)
		free(v, allocator)
	case ^Alg_Left_Join:
		destroy_algebra(v.left, allocator)
		destroy_algebra(v.right, allocator)
		free(v, allocator)
	case ^Alg_Filter:
		delete(v.conditions)
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Union:
		destroy_algebra(v.left, allocator)
		destroy_algebra(v.right, allocator)
		free(v, allocator)
	case ^Alg_Minus:
		destroy_algebra(v.left, allocator)
		destroy_algebra(v.right, allocator)
		free(v, allocator)
	case ^Alg_Graph:
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Extend:
		delete(v.bindings)
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Group:
		delete(v.by)
		delete(v.aggregates)
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Order:
		delete(v.conditions)
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Project:
		delete(v.vars)
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Distinct:
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Reduced:
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Slice:
		destroy_algebra(v.input, allocator)
		free(v, allocator)
	case ^Alg_Table:
		delete(v.vars)
		for row in v.rows {
			delete(row)
		}
		delete(v.rows)
		free(v, allocator)
	}
}
