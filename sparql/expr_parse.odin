// Expression parsing (SPARQL-T-0004): the classic precedence ladder,
// one proc per level of the grammar's Expression chain, plus the call
// forms (built-ins by Keyword, custom functions by IRI, EXISTS over a
// group). Aggregate call productions (COUNT …) arrive with
// SPARQL-T-0005 alongside GROUP BY.
package sparql

import rdf "rdf:rdf"

// parse_expression parses Expression ::= ConditionalOrExpression.
// Nil with p.err set on failure.
@(private)
parse_expression :: proc(p: ^Parser) -> Expr {
	if p.depth >= MAX_DEPTH {
		fail_current(p, .Nesting_Too_Deep)
		return nil
	}
	p.depth += 1
	defer p.depth -= 1
	return parse_or_expr(p)
}

@(private = "file")
parse_or_expr :: proc(p: ^Parser) -> Expr {
	left := parse_and_expr(p)
	for p.err.kind == .None && at(p, .Or) {
		pos := token_pos(p.tok)
		advance(p)
		right := parse_and_expr(p)
		left = binary(p, .Or, left, right, pos)
	}
	return left
}

@(private = "file")
parse_and_expr :: proc(p: ^Parser) -> Expr {
	left := parse_relational_expr(p)
	for p.err.kind == .None && at(p, .And) {
		pos := token_pos(p.tok)
		advance(p)
		right := parse_relational_expr(p)
		left = binary(p, .And, left, right, pos)
	}
	return left
}

// parse_relational_expr parses RelationalExpression: a numeric
// expression optionally followed by ONE comparison, IN, or NOT IN —
// relational operators do not chain.
@(private = "file")
parse_relational_expr :: proc(p: ^Parser) -> Expr {
	left := parse_additive_expr(p)
	if p.err.kind != .None || !p.has_tok {
		return left
	}
	op: Binary_Op
	#partial switch p.tok.kind {
	case .Eq:
		op = .Eq
	case .Ne:
		op = .Ne
	case .Lt:
		op = .Lt
	case .Gt:
		op = .Gt
	case .Le:
		op = .Le
	case .Ge:
		op = .Ge
	case .Keyword:
		#partial switch p.tok.keyword {
		case .In:
			return parse_in_expr(p, left, false)
		case .Not:
			advance(p)
			if !at_keyword(p, .In) {
				fail_current(p, .Expected_Expression)
				return left
			}
			return parse_in_expr(p, left, true)
		case:
			return left
		}
		return left
	case:
		return left
	}
	pos := token_pos(p.tok)
	advance(p)
	right := parse_additive_expr(p)
	return binary(p, op, left, right, pos)
}

// parse_in_expr parses (NOT)? IN ExpressionList, with the IN token
// current on entry.
@(private = "file")
parse_in_expr :: proc(p: ^Parser, value: Expr, negated: bool) -> Expr {
	pos := token_pos(p.tok)
	advance(p) // IN
	e := new(In_Expr, p.allocator)
	e.value = value
	e.negated = negated
	e.pos = pos
	e.list = make([dynamic]Expr, p.allocator)
	parse_expression_list(p, &e.list)
	return e
}

// parse_expression_list parses ExpressionList ::= NIL | '(' Expression
// (',' Expression)* ')'.
@(private = "file")
parse_expression_list :: proc(p: ^Parser, out: ^[dynamic]Expr) {
	if at(p, .Nil) {
		advance(p)
		return
	}
	if !at(p, .L_Paren) {
		fail_current(p, .Expected_Expression)
		return
	}
	advance(p)
	for p.err.kind == .None {
		append(out, parse_expression(p))
		if at(p, .Comma) {
			advance(p)
			continue
		}
		break
	}
	if p.err.kind != .None {
		return
	}
	if !at(p, .R_Paren) {
		fail_current(p, .Expected_Close_Paren)
		return
	}
	advance(p)
}

@(private = "file")
parse_additive_expr :: proc(p: ^Parser) -> Expr {
	left := parse_multiplicative_expr(p)
	for p.err.kind == .None && p.has_tok {
		#partial switch p.tok.kind {
		case .Plus:
			pos := token_pos(p.tok)
			advance(p)
			left = binary(p, .Add, left, parse_multiplicative_expr(p), pos)
		case .Minus:
			pos := token_pos(p.tok)
			advance(p)
			left = binary(p, .Sub, left, parse_multiplicative_expr(p), pos)
		case .Integer, .Decimal, .Double:
			// The grammar's signed-literal shorthand: `?x+2` scans as a
			// NumericLiteralPositive and means addition; `*`/`/` chains
			// bind to the literal first (`?x+2*3` is ?x + (2*3)).
			if len(p.tok.text) == 0 || (p.tok.text[0] != '+' && p.tok.text[0] != '-') {
				return left
			}
			pos := token_pos(p.tok)
			op := Binary_Op.Add if p.tok.text[0] == '+' else Binary_Op.Sub
			operand := Expr(numeric_literal(p.tok.kind, p.tok.text[1:]))
			advance(p)
			for p.err.kind == .None && (at(p, .Star) || at(p, .Slash)) {
				mul_op := Binary_Op.Mul if p.tok.kind == .Star else Binary_Op.Div
				mul_pos := token_pos(p.tok)
				advance(p)
				operand = binary(p, mul_op, operand, parse_unary_expr(p), mul_pos)
			}
			left = binary(p, op, left, operand, pos)
		case:
			return left
		}
	}
	return left
}

@(private = "file")
parse_multiplicative_expr :: proc(p: ^Parser) -> Expr {
	left := parse_unary_expr(p)
	for p.err.kind == .None && (at(p, .Star) || at(p, .Slash)) {
		op := Binary_Op.Mul if p.tok.kind == .Star else Binary_Op.Div
		pos := token_pos(p.tok)
		advance(p)
		left = binary(p, op, left, parse_unary_expr(p), pos)
	}
	return left
}

@(private = "file")
parse_unary_expr :: proc(p: ^Parser) -> Expr {
	if !p.has_tok {
		fail_here(p, .Expected_Expression)
		return nil
	}
	op: Unary_Op
	#partial switch p.tok.kind {
	case .Bang:
		op = .Not
	case .Plus:
		op = .Plus
	case .Minus:
		op = .Minus
	case:
		return parse_primary_expr(p)
	}
	pos := token_pos(p.tok)
	advance(p)
	e := new(Unary_Expr, p.allocator)
	e.op = op
	e.pos = pos
	e.operand = parse_unary_expr(p)
	return e
}

@(private = "file")
parse_primary_expr :: proc(p: ^Parser) -> Expr {
	if !p.has_tok {
		fail_here(p, .Expected_Expression)
		return nil
	}
	#partial switch p.tok.kind {
	case .L_Paren:
		return parse_bracketted(p)
	case .Var:
		v := var_of(p.tok)
		advance(p)
		return v
	case .IRI_Ref, .PName:
		return parse_iri_or_function(p)
	case .String_Literal:
		lit, ok := parse_rdf_literal(p)
		if !ok {
			return nil
		}
		return lit
	case .Integer:
		lit := numeric_literal(.Integer, p.tok.text)
		advance(p)
		return lit
	case .Decimal:
		lit := numeric_literal(.Decimal, p.tok.text)
		advance(p)
		return lit
	case .Double:
		lit := numeric_literal(.Double, p.tok.text)
		advance(p)
		return lit
	case .Boolean:
		lexical := "true" if (p.tok.text[0] == 't' || p.tok.text[0] == 'T') else "false"
		advance(p)
		return rdf.literal_typed(lexical, rdf.XSD_BOOLEAN)
	case .Keyword:
		return parse_builtin_expr(p)
	}
	fail_at(p, .Expected_Expression, p.tok)
	return nil
}

// parse_bracketted parses BrackettedExpression ::= '(' Expression ')'.
@(private)
parse_bracketted :: proc(p: ^Parser) -> Expr {
	if !at(p, .L_Paren) {
		fail_current(p, .Expected_Expression)
		return nil
	}
	advance(p)
	e := parse_expression(p)
	if p.err.kind != .None {
		return e
	}
	if !at(p, .R_Paren) {
		fail_current(p, .Expected_Close_Paren)
		return e
	}
	advance(p)
	return e
}

// parse_iri_or_function parses iriOrFunction: an IRI, optionally
// applied to an argument list.
@(private = "file")
parse_iri_or_function :: proc(p: ^Parser) -> Expr {
	pos := token_pos(p.tok)
	iri, ok := parse_iri(p)
	if !ok {
		return nil
	}
	if !at(p, .Nil) && !at(p, .L_Paren) {
		return iri
	}
	f := new(Function_Call, p.allocator)
	f.iri = iri
	f.pos = pos
	f.args = make([dynamic]Expr, p.allocator)
	f.is_distinct = parse_arg_list(p, &f.args, true)
	return f
}

// parse_arg_list parses ArgList ::= NIL | '(' 'DISTINCT'? Expression
// (',' Expression)* ')', returning whether DISTINCT was present.
@(private = "file")
parse_arg_list :: proc(p: ^Parser, out: ^[dynamic]Expr, allow_distinct: bool) -> (is_distinct: bool) {
	if at(p, .Nil) {
		advance(p)
		return false
	}
	advance(p) // '(' — callers dispatched on it
	if allow_distinct && at_keyword(p, .Distinct) {
		is_distinct = true
		advance(p)
	}
	for p.err.kind == .None {
		append(out, parse_expression(p))
		if at(p, .Comma) {
			advance(p)
			continue
		}
		break
	}
	if p.err.kind != .None {
		return
	}
	if !at(p, .R_Paren) {
		fail_current(p, .Expected_Close_Paren)
		return
	}
	advance(p)
	return
}

// parse_builtin_expr parses the keyword-headed BuiltInCall forms:
// EXISTS / NOT EXISTS, BOUND's variable-only argument, and the named
// built-ins with their arities.
@(private)
parse_builtin_expr :: proc(p: ^Parser) -> Expr {
	kw_tok := p.tok
	pos := token_pos(kw_tok)
	#partial switch kw_tok.keyword {
	case .Exists:
		advance(p)
		return exists_expr(p, pos, false)
	case .Not:
		advance(p)
		if !at_keyword(p, .Exists) {
			fail_current(p, .Expected_Expression)
			return nil
		}
		advance(p)
		return exists_expr(p, pos, true)
	case .Bound:
		advance(p)
		if !at(p, .L_Paren) {
			fail_current(p, .Expected_Expression)
			return nil
		}
		advance(p)
		if !at(p, .Var) {
			fail_current(p, .Expected_Variable)
			return nil
		}
		v := var_of(p.tok)
		advance(p)
		if !at(p, .R_Paren) {
			fail_current(p, .Expected_Close_Paren)
			return nil
		}
		advance(p)
		call := new(Builtin_Call, p.allocator)
		call.builtin = .Bound
		call.pos = pos
		call.args = make([dynamic]Expr, p.allocator)
		append(&call.args, Expr(v))
		return call
	}

	min_arity, max_arity, is_builtin := builtin_arity(kw_tok.keyword)
	if !is_builtin {
		// An aggregate (SPARQL-T-0005) or a clause keyword out of place.
		fail_at(p, .Expected_Expression, kw_tok)
		return nil
	}
	advance(p)
	if !at(p, .Nil) && !at(p, .L_Paren) {
		fail_current(p, .Expected_Expression)
		return nil
	}
	call := new(Builtin_Call, p.allocator)
	call.builtin = kw_tok.keyword
	call.pos = pos
	call.args = make([dynamic]Expr, p.allocator)
	if at(p, .Nil) {
		advance(p)
	} else {
		advance(p) // '('
		if !at(p, .R_Paren) {
			for p.err.kind == .None {
				append(&call.args, parse_expression(p))
				if at(p, .Comma) {
					advance(p)
					continue
				}
				break
			}
		}
		if p.err.kind != .None {
			return call
		}
		if !at(p, .R_Paren) {
			fail_current(p, .Expected_Close_Paren)
			return call
		}
		advance(p)
	}
	if len(call.args) < min_arity || (max_arity >= 0 && len(call.args) > max_arity) {
		fail_at(p, .Wrong_Arity, kw_tok)
	}
	return call
}

@(private = "file")
exists_expr :: proc(p: ^Parser, pos: Position, negated: bool) -> Expr {
	e := new(Exists_Expr, p.allocator)
	e.pos = pos
	e.negated = negated
	e.group = parse_group(p)
	return e
}

// builtin_arity returns the grammar-fixed argument counts of a
// built-in (max -1 means unbounded). ok is false for keywords that are
// not expression built-ins.
@(private)
builtin_arity :: proc(kw: Keyword) -> (min_arity, max_arity: int, ok: bool) {
	#partial switch kw {
	case .Rand, .Now, .Uuid, .Struuid:
		return 0, 0, true
	case .Bnode:
		return 0, 1, true
	case .Str, .Lang, .Datatype, .Iri, .Uri, .Abs, .Ceil, .Floor, .Round,
	     .Strlen, .Ucase, .Lcase, .Encode_For_Uri, .Year, .Month, .Day,
	     .Hours, .Minutes, .Seconds, .Timezone, .Tz, .Md5, .Sha1, .Sha256,
	     .Sha384, .Sha512, .Is_Iri, .Is_Uri, .Is_Blank, .Is_Literal,
	     .Is_Numeric, .Subject, .Predicate, .Object, .Is_Triple,
	     .Lang_Dir, .Has_Lang, .Has_Lang_Dir:
		return 1, 1, true
	case .Langmatches, .Contains, .Strstarts, .Strends, .Strbefore,
	     .Strafter, .Strlang, .Strdt, .Same_Term:
		return 2, 2, true
	case .Regex, .Substr:
		return 2, 3, true
	case .If, .Triple, .Str_Lang_Dir:
		return 3, 3, true
	case .Replace:
		return 3, 4, true
	case .Concat, .Coalesce:
		return 0, -1, true
	}
	return 0, 0, false
}

// parse_constraint parses Constraint ::= BrackettedExpression |
// BuiltInCall | FunctionCall (the FILTER and ORDER BY condition form).
@(private)
parse_constraint :: proc(p: ^Parser) -> Expr {
	if !p.has_tok {
		fail_here(p, .Expected_Expression)
		return nil
	}
	#partial switch p.tok.kind {
	case .L_Paren:
		return parse_bracketted(p)
	case .Keyword:
		return parse_builtin_expr(p)
	case .IRI_Ref, .PName:
		// FunctionCall requires an argument list here.
		pos := token_pos(p.tok)
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		if !at(p, .Nil) && !at(p, .L_Paren) {
			fail_current(p, .Expected_Expression)
			return nil
		}
		f := new(Function_Call, p.allocator)
		f.iri = iri
		f.pos = pos
		f.args = make([dynamic]Expr, p.allocator)
		f.is_distinct = parse_arg_list(p, &f.args, true)
		return f
	}
	fail_at(p, .Expected_Expression, p.tok)
	return nil
}

@(private = "file")
binary :: proc(p: ^Parser, op: Binary_Op, left, right: Expr, pos: Position) -> Expr {
	e := new(Binary_Expr, p.allocator)
	e.op = op
	e.left = left
	e.right = right
	e.pos = pos
	return e
}

// numeric_literal builds the typed literal for a numeric token kind.
@(private)
numeric_literal :: proc(kind: Token_Kind, lexical: string) -> rdf.Literal {
	#partial switch kind {
	case .Integer:
		return rdf.literal_typed(lexical, rdf.XSD_INTEGER)
	case .Decimal:
		return rdf.literal_typed(lexical, rdf.XSD_DECIMAL)
	case:
		return rdf.literal_typed(lexical, rdf.XSD_DOUBLE)
	}
}
