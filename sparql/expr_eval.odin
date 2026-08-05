// Expression evaluation (SPARQL-T-0012): an expression tree from the
// parser, a solution row, and the store's dictionary, in — a Value out.
//
// The awkward part of SPARQL expressions is not the operators, it is
// what happens when they are given something they do not understand.
// SPARQL does not stop: it produces a type error, propagates it, and
// then specific operators recover from it. `||` is true if *either* side
// is true even when the other errored; `&&` is false if either side is
// false; FILTER treats an error like a false. Getting that wrong does
// not crash anything, it just quietly returns the wrong rows — which is
// why the three-valued cases have their own tests and their own suite
// directories.
//
// Variables are read from the solution row, so evaluating an expression
// means materializing the terms it mentions and nothing else. Terms come
// back through a Term_Loader, a procedure pointer: it is called once per
// variable occurrence per solution, not per matched quad, and the
// SPARQL-T-0011 spike measured indirect calls at that frequency as free.
// The loader says whether the term it returned is owned, because the two
// backends differ — memstore borrows from its dictionary, kvstore builds
// the term — and an owned one is released when the evaluation ends.
package sparql

import "base:runtime"

import rdf "rdf:rdf"
import store "store:store"

// Term_Loader materializes a term ID. owned=true means the term was
// allocated for this call and the caller releases it.
Term_Loader :: #type proc(
	data: rawptr,
	id: store.Term_ID,
	allocator: runtime.Allocator,
) -> (
	term: rdf.Term,
	owned: bool,
)

// Expr_Context is everything an expression needs beyond its own tree.
// row is repointed at each solution; scratch collects the terms the
// loader allocated for the current evaluation.
Expr_Context :: struct {
	slots:     ^Var_Slots,
	row:       []store.Term_ID,
	load:      Term_Loader,
	load_data: rawptr,
	scratch:   [dynamic]rdf.Term,
	allocator: runtime.Allocator,
}

expr_context_init :: proc(
	ctx: ^Expr_Context,
	slots: ^Var_Slots,
	load: Term_Loader,
	load_data: rawptr,
	allocator := context.allocator,
) {
	ctx.slots = slots
	ctx.load = load
	ctx.load_data = load_data
	ctx.allocator = allocator
	ctx.scratch = make([dynamic]rdf.Term, allocator)
}

expr_context_destroy :: proc(ctx: ^Expr_Context) {
	expr_context_release(ctx)
	delete(ctx.scratch)
	ctx^ = {}
}

// expr_context_release frees the terms materialized during one
// evaluation. Called after each condition, so a filter over a million
// solutions holds one solution's worth of terms at a time.
expr_context_release :: proc(ctx: ^Expr_Context) {
	for term in ctx.scratch {
		rdf.destroy_term(term, ctx.allocator)
	}
	clear(&ctx.scratch)
}

// expr_eval evaluates an expression against the context's current row.
// It never fails: an operator that cannot proceed returns a type-error
// Value, which its caller either recovers from or passes on.
expr_eval :: proc(ctx: ^Expr_Context, e: Expr) -> Value {
	switch v in e {
	case Var:
		return var_value(ctx, v.name)
	case rdf.IRI:
		return Value{kind = .IRI, text = string(v)}
	case rdf.Literal:
		return value_of(v)
	case ^Binary_Expr:
		return eval_binary(ctx, v)
	case ^Unary_Expr:
		return eval_unary(ctx, v)
	case ^In_Expr:
		return eval_in(ctx, v)
	case ^Builtin_Call:
		return eval_builtin(ctx, v)
	case ^Function_Call, ^Exists_Expr, ^Aggregate, ^Triple_Term:
	// Refused at plan time (expr_check); reaching here would be a bug
	// in that check rather than a query the engine should answer.
	}
	return ERROR_VALUE
}

@(private = "file")
var_value :: proc(ctx: ^Expr_Context, name: string) -> Value {
	slot, found := var_slot_lookup(ctx.slots, name)
	if !found || slot >= len(ctx.row) {
		// A variable the pattern never mentions is unbound, not an
		// error — BOUND(?nowhere) must be able to say false.
		return UNBOUND_VALUE
	}
	id := ctx.row[slot]
	if id == store.UNBOUND {
		return UNBOUND_VALUE
	}
	term, owned := ctx.load(ctx.load_data, id, ctx.allocator)
	if owned {
		append(&ctx.scratch, term)
	}
	return value_of(term)
}

@(private = "file")
eval_binary :: proc(ctx: ^Expr_Context, e: ^Binary_Expr) -> Value {
	// The logical operators evaluate lazily-ish: both sides are needed
	// only because either may supply the deciding truth value even when
	// the other errors (§17.2.1's truth tables).
	if e.op == .Or || e.op == .And {
		left, left_ok := effective_boolean_value(expr_eval(ctx, e.left))
		if e.op == .Or && left_ok && left {
			return value_boolean(true)
		}
		if e.op == .And && left_ok && !left {
			return value_boolean(false)
		}
		right, right_ok := effective_boolean_value(expr_eval(ctx, e.right))
		if e.op == .Or {
			if right_ok && right {
				return value_boolean(true)
			}
			if left_ok && right_ok {
				return value_boolean(false)
			}
			return ERROR_VALUE
		}
		if right_ok && !right {
			return value_boolean(false)
		}
		if left_ok && right_ok {
			return value_boolean(true)
		}
		return ERROR_VALUE
	}

	left := expr_eval(ctx, e.left)
	right := expr_eval(ctx, e.right)
	if left.kind == .Error || right.kind == .Error {
		return ERROR_VALUE
	}

	#partial switch e.op {
	case .Eq, .Ne:
		equal, ok := value_equal(left, right)
		if !ok {
			return ERROR_VALUE
		}
		return value_boolean(equal if e.op == .Eq else !equal)
	case .Lt, .Gt, .Le, .Ge:
		order, ok := value_compare(left, right)
		if !ok {
			return ERROR_VALUE
		}
		switch e.op {
		case .Lt:
			return value_boolean(order < 0)
		case .Gt:
			return value_boolean(order > 0)
		case .Le:
			return value_boolean(order <= 0)
		case .Ge:
			return value_boolean(order >= 0)
		case .Or, .And, .Eq, .Ne, .Add, .Sub, .Mul, .Div:
		}
	case .Add:
		return value_arithmetic(.Add, left, right)
	case .Sub:
		return value_arithmetic(.Subtract, left, right)
	case .Mul:
		return value_arithmetic(.Multiply, left, right)
	case .Div:
		return value_arithmetic(.Divide, left, right)
	}
	return ERROR_VALUE
}

@(private = "file")
eval_unary :: proc(ctx: ^Expr_Context, e: ^Unary_Expr) -> Value {
	operand := expr_eval(ctx, e.operand)
	switch e.op {
	case .Not:
		b, ok := effective_boolean_value(operand)
		if !ok {
			return ERROR_VALUE
		}
		return value_boolean(!b)
	case .Plus:
		if operand.kind != .Numeric {
			return ERROR_VALUE
		}
		return operand
	case .Minus:
		return value_negate(operand)
	}
	return ERROR_VALUE
}

// eval_in is `x IN (a, b, …)`. It is `x = a || x = b || …`, and so it
// inherits `||`'s error recovery: a match anywhere wins even if another
// comparison errored, and only an all-false-with-an-error result is an
// error.
@(private = "file")
eval_in :: proc(ctx: ^Expr_Context, e: ^In_Expr) -> Value {
	subject := expr_eval(ctx, e.value)
	if subject.kind == .Error {
		return ERROR_VALUE
	}
	errored := false
	for item in e.list {
		candidate := expr_eval(ctx, item)
		if candidate.kind == .Error {
			errored = true
			continue
		}
		equal, ok := value_equal(subject, candidate)
		if !ok {
			errored = true
			continue
		}
		if equal {
			return value_boolean(!e.negated)
		}
	}
	if errored {
		return ERROR_VALUE
	}
	return value_boolean(e.negated)
}

@(private = "file")
eval_builtin :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	#partial switch e.builtin {
	case .Bound:
		// BOUND asks about the binding, not the value, so its argument
		// is not evaluated in the ordinary way — an unbound variable
		// must reach it as "unbound" rather than as an error.
		if len(e.args) != 1 {
			return ERROR_VALUE
		}
		variable, is_var := e.args[0].(Var)
		if !is_var {
			return ERROR_VALUE
		}
		slot, found := var_slot_lookup(ctx.slots, variable.name)
		if !found || slot >= len(ctx.row) {
			return value_boolean(false)
		}
		return value_boolean(ctx.row[slot] != store.UNBOUND)
	}

	if len(e.args) == 0 {
		return ERROR_VALUE
	}
	first := expr_eval(ctx, e.args[0])
	if first.kind == .Error {
		return ERROR_VALUE
	}

	#partial switch e.builtin {
	case .Datatype:
		return value_datatype(first)
	case .Str:
		return value_str(first)
	case .Lang:
		return value_lang(first)
	case .Is_Iri, .Is_Uri:
		return kind_test(first, .IRI)
	case .Is_Blank:
		return kind_test(first, .Blank_Node)
	case .Is_Literal:
		if first.kind == .Unbound {
			return ERROR_VALUE
		}
		switch first.kind {
		case .Simple_String, .Lang_String, .Boolean, .Numeric, .Date_Time, .Date, .Unknown_Literal:
			return value_boolean(true)
		case .Error, .Unbound, .IRI, .Blank_Node, .Triple:
			return value_boolean(false)
		}
		return value_boolean(false)
	case .Is_Numeric:
		if first.kind == .Unbound {
			return ERROR_VALUE
		}
		return value_boolean(first.kind == .Numeric)
	case .Same_Term:
		if len(e.args) != 2 {
			return ERROR_VALUE
		}
		second := expr_eval(ctx, e.args[1])
		if second.kind == .Error || first.kind == .Unbound || second.kind == .Unbound {
			return ERROR_VALUE
		}
		return value_boolean(value_same_term(first, second))
	case .Langmatches:
		if len(e.args) != 2 {
			return ERROR_VALUE
		}
		second := expr_eval(ctx, e.args[1])
		if second.kind == .Error {
			return ERROR_VALUE
		}
		if first.kind != .Simple_String || second.kind != .Simple_String {
			return ERROR_VALUE
		}
		return value_boolean(langmatches(first.text, second.text))
	}
	return ERROR_VALUE
}

@(private = "file")
kind_test :: proc(v: Value, kind: Value_Kind) -> Value {
	if v.kind == .Unbound || v.kind == .Error {
		return ERROR_VALUE
	}
	return value_boolean(v.kind == kind)
}

// expr_check walks an expression at plan time and names the first
// construct this engine cannot evaluate. Refusing here rather than
// returning a type error at runtime is the difference between "the
// engine does not implement REGEX" and "your filter matched nothing".
expr_check :: proc(b: ^Plan_Builder, e: Expr) -> bool {
	switch v in e {
	case Var, rdf.IRI, rdf.Literal:
		return true
	case ^Binary_Expr:
		return expr_check(b, v.left) && expr_check(b, v.right)
	case ^Unary_Expr:
		return expr_check(b, v.operand)
	case ^In_Expr:
		if !expr_check(b, v.value) {
			return false
		}
		for item in v.list {
			if !expr_check(b, item) {
				return false
			}
		}
		return true
	case ^Builtin_Call:
		#partial switch v.builtin {
		case .Bound,
		     .Datatype,
		     .Str,
		     .Lang,
		     .Langmatches,
		     .Same_Term,
		     .Is_Iri,
		     .Is_Uri,
		     .Is_Blank,
		     .Is_Literal,
		     .Is_Numeric:
			for arg in v.args {
				if !expr_check(b, arg) {
					return false
				}
			}
			return true
		}
		b.unsupported = "built-in function"
		return false
	case ^Function_Call:
		b.unsupported = "extension function"
	case ^Exists_Expr:
		b.unsupported = "EXISTS"
	case ^Aggregate:
		b.unsupported = "aggregate"
	case ^Triple_Term:
		b.unsupported = "triple-term expression"
	case nil:
		b.unsupported = "empty expression"
	}
	return false
}
