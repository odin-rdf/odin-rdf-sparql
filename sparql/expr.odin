// The expression AST (SPARQL-T-0004): operators and call forms as the
// grammar shapes them, with no evaluation semantics — type promotion,
// error-as-unbound, and the function library's behavior belong to the
// evaluation initiative. Built-ins are identified by the scanner's
// Keyword enum; custom functions by IRI.
package sparql

import rdf "rdf:rdf"

Binary_Op :: enum {
	Or, // ||
	And, // &&
	Eq,
	Ne,
	Lt,
	Gt,
	Le,
	Ge,
	Add,
	Sub,
	Mul,
	Div,
}

Unary_Op :: enum {
	Not, // !
	Plus,
	Minus,
}

Binary_Expr :: struct {
	op:          Binary_Op,
	left, right: Expr,
	pos:         Position,
}

Unary_Expr :: struct {
	op:      Unary_Op,
	operand: Expr,
	pos:     Position,
}

// Builtin_Call is a call of one of the grammar's named built-ins
// (BuiltInCall minus EXISTS, which has its own node). Arity is checked
// at parse time where the grammar fixes it, so downstream code can
// index args by position.
Builtin_Call :: struct {
	builtin: Keyword,
	args:    [dynamic]Expr,
	pos:     Position,
}

// Function_Call is a custom function: an IRI applied to an argument
// list, optionally with DISTINCT (meaningful only to extension
// aggregates; carried through as parsed).
Function_Call :: struct {
	iri:      rdf.IRI,
	args:     [dynamic]Expr,
	is_distinct: bool,
	pos:      Position,
}

// In_Expr is `value IN (list)` or `value NOT IN (list)`.
In_Expr :: struct {
	value:   Expr,
	list:    [dynamic]Expr,
	negated: bool,
	pos:     Position,
}

// Exists_Expr is EXISTS/NOT EXISTS over a group graph pattern. The
// parser fills group; the §18.2 translation (SPARQL-T-0007) fills
// algebra with the translated pattern, which the printer and the
// evaluator use.
Exists_Expr :: struct {
	group:   ^Group_Pattern,
	algebra: Algebra, // nil until translated
	negated: bool,
	pos:     Position,
}

// Aggregate is COUNT/SUM/MIN/MAX/AVG/SAMPLE/GROUP_CONCAT. star marks
// COUNT(*); separator applies to GROUP_CONCAT only (default " " when
// has_separator is false).
Aggregate :: struct {
	op:            Keyword,
	is_distinct:   bool,
	star:          bool, // COUNT(*): expr is nil
	expr:          Expr,
	separator:     string,
	has_separator: bool,
	pos:           Position,
}

// Expr is an expression tree node. Terms appear directly: variables,
// IRIs (an iriOrFunction without arguments), and literals — blank
// nodes cannot occur in expressions.
Expr :: union {
	^Binary_Expr,
	^Unary_Expr,
	^Builtin_Call,
	^Function_Call,
	^In_Expr,
	^Exists_Expr,
	^Aggregate,
	Var,
	rdf.IRI,
	rdf.Literal,
}

@(private)
destroy_expr :: proc(e: Expr, allocator := context.allocator) {
	switch v in e {
	case ^Binary_Expr:
		destroy_expr(v.left, allocator)
		destroy_expr(v.right, allocator)
		free(v, allocator)
	case ^Unary_Expr:
		destroy_expr(v.operand, allocator)
		free(v, allocator)
	case ^Builtin_Call:
		for arg in v.args {
			destroy_expr(arg, allocator)
		}
		delete(v.args)
		free(v, allocator)
	case ^Function_Call:
		for arg in v.args {
			destroy_expr(arg, allocator)
		}
		delete(v.args)
		free(v, allocator)
	case ^In_Expr:
		destroy_expr(v.value, allocator)
		for item in v.list {
			destroy_expr(item, allocator)
		}
		delete(v.list)
		free(v, allocator)
	case ^Exists_Expr:
		destroy_group(v.group, allocator)
		destroy_algebra(v.algebra, allocator)
		free(v, allocator)
	case ^Aggregate:
		destroy_expr(v.expr, allocator)
		free(v, allocator)
	case Var, rdf.IRI, rdf.Literal:
	// Terms own nothing at this layer.
	}
}
