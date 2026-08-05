// The SSE printer (SPARQL-T-0006): renders an algebra tree in Jena
// ARQ's s-expression notation (`arq.qparse --print op`), the de-facto
// interchange form for SPARQL algebra. Translation tests assert
// against it, and it doubles as the debugging view. Layout matches
// Jena: operators with algebra children open on their own line and
// indent children by two spaces; terms and expressions stay inline.
package sparql

import "core:io"
import "core:strings"

import rdf "rdf:rdf"

// algebra_to_string renders a tree with a trailing newline. The result
// is allocated from the given allocator and owned by the caller.
algebra_to_string :: proc(a: Algebra, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w := strings.to_writer(&b)
	algebra_print(a, w)
	return strings.to_string(b)
}

// algebra_print renders a tree to w with a trailing newline.
algebra_print :: proc(a: Algebra, w: io.Writer) {
	print_op(w, a, 0)
	io.write_byte(w, '\n')
}

@(private = "file")
open_op :: proc(w: io.Writer, indent: int, name: string) {
	for _ in 0 ..< indent {
		io.write_string(w, "  ")
	}
	io.write_byte(w, '(')
	io.write_string(w, name)
}

@(private = "file")
print_op :: proc(w: io.Writer, a: Algebra, indent: int) {
	switch v in a {
	case ^Alg_BGP:
		open_op(w, indent, "bgp")
		for t in v.triples {
			io.write_string(w, " (triple ")
			print_node(w, t.subject)
			io.write_byte(w, ' ')
			print_node(w, t.predicate)
			io.write_byte(w, ' ')
			print_node(w, t.object)
			io.write_byte(w, ')')
		}
		io.write_byte(w, ')')
	case ^Alg_Path:
		open_op(w, indent, "path ")
		print_node(w, v.subject)
		io.write_byte(w, ' ')
		print_path(w, v.path)
		io.write_byte(w, ' ')
		print_node(w, v.object)
		io.write_byte(w, ')')
	case ^Alg_Join:
		print_binary_op(w, "join", v.left, v.right, indent)
	case ^Alg_Left_Join:
		open_op(w, indent, "leftjoin")
		io.write_byte(w, '\n')
		print_op(w, v.left, indent + 1)
		io.write_byte(w, '\n')
		print_op(w, v.right, indent + 1)
		if len(v.conditions) > 0 {
			io.write_byte(w, '\n')
			for _ in 0 ..< indent + 1 {
				io.write_string(w, "  ")
			}
			if len(v.conditions) == 1 {
				print_expr(w, v.conditions[0])
			} else {
				io.write_string(w, "(exprlist")
				for condition in v.conditions {
					io.write_byte(w, ' ')
					print_expr(w, condition)
				}
				io.write_byte(w, ')')
			}
		}
		io.write_byte(w, ')')
	case ^Alg_Filter:
		open_op(w, indent, "filter ")
		if len(v.conditions) == 1 {
			print_expr(w, v.conditions[0])
		} else {
			io.write_string(w, "(exprlist")
			for condition in v.conditions {
				io.write_byte(w, ' ')
				print_expr(w, condition)
			}
			io.write_byte(w, ')')
		}
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Union:
		print_binary_op(w, "union", v.left, v.right, indent)
	case ^Alg_Minus:
		print_binary_op(w, "minus", v.left, v.right, indent)
	case ^Alg_Graph:
		open_op(w, indent, "graph ")
		print_node(w, v.graph)
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Extend:
		open_op(w, indent, "extend (")
		for binding, i in v.bindings {
			if i > 0 {
				io.write_byte(w, ' ')
			}
			io.write_byte(w, '(')
			print_var(w, binding.v)
			io.write_byte(w, ' ')
			print_expr(w, binding.expr)
			io.write_byte(w, ')')
		}
		io.write_byte(w, ')')
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Group:
		open_op(w, indent, "group (")
		for condition, i in v.by {
			if i > 0 {
				io.write_byte(w, ' ')
			}
			print_group_condition(w, condition)
		}
		io.write_string(w, ") (")
		for binding, i in v.aggregates {
			if i > 0 {
				io.write_byte(w, ' ')
			}
			io.write_byte(w, '(')
			print_var(w, binding.v)
			io.write_byte(w, ' ')
			print_expr(w, binding.expr)
			io.write_byte(w, ')')
		}
		io.write_byte(w, ')')
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Order:
		open_op(w, indent, "order (")
		for condition, i in v.conditions {
			if i > 0 {
				io.write_byte(w, ' ')
			}
			if condition.direction == .Descending {
				io.write_string(w, "(desc ")
				print_expr(w, condition.expr)
				io.write_byte(w, ')')
			} else {
				print_expr(w, condition.expr)
			}
		}
		io.write_byte(w, ')')
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Project:
		open_op(w, indent, "project (")
		for projected, i in v.vars {
			if i > 0 {
				io.write_byte(w, ' ')
			}
			print_var(w, projected)
		}
		io.write_byte(w, ')')
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Distinct:
		open_op(w, indent, "distinct")
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Reduced:
		open_op(w, indent, "reduced")
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Slice:
		open_op(w, indent, "slice ")
		if v.start < 0 {
			io.write_byte(w, '_')
		} else {
			io.write_int(w, v.start)
		}
		io.write_byte(w, ' ')
		if v.length < 0 {
			io.write_byte(w, '_')
		} else {
			io.write_int(w, v.length)
		}
		io.write_byte(w, '\n')
		print_op(w, v.input, indent + 1)
		io.write_byte(w, ')')
	case ^Alg_Table:
		if v.unit {
			open_op(w, indent, "table unit)")
			return
		}
		open_op(w, indent, "table (vars")
		for table_var in v.vars {
			io.write_byte(w, ' ')
			print_var(w, table_var)
		}
		io.write_byte(w, ')')
		for row in v.rows {
			io.write_byte(w, '\n')
			for _ in 0 ..< indent + 1 {
				io.write_string(w, "  ")
			}
			io.write_string(w, "(row")
			for cell, i in row {
				if cell == nil { // UNDEF: unbound cells are omitted
					continue
				}
				io.write_string(w, " [")
				print_var(w, v.vars[i])
				io.write_byte(w, ' ')
				print_node(w, cell)
				io.write_byte(w, ']')
			}
			io.write_byte(w, ')')
		}
		io.write_byte(w, ')')
	}
}

@(private = "file")
print_binary_op :: proc(w: io.Writer, name: string, left, right: Algebra, indent: int) {
	open_op(w, indent, name)
	io.write_byte(w, '\n')
	print_op(w, left, indent + 1)
	io.write_byte(w, '\n')
	print_op(w, right, indent + 1)
	io.write_byte(w, ')')
}

@(private = "file")
print_group_condition :: proc(w: io.Writer, condition: Group_Condition) {
	if condition.has_var {
		io.write_byte(w, '(')
		print_var(w, condition.v)
		io.write_byte(w, ' ')
		print_expr(w, condition.expr)
		io.write_byte(w, ')')
		return
	}
	print_expr(w, condition.expr)
}

// print_path renders a path expression: link IRIs bare, composites as
// (seq …)/(alt …) folded binary left-associative the way ARQ prints
// them, (reverse p), (path* p), (path+ p), (path? p), and
// (notoneof …) for negated property sets.
@(private = "file")
print_path :: proc(w: io.Writer, path: ^Path_Expr) {
	switch path.op {
	case .Link:
		print_iri(w, path.iri)
	case .Sequence:
		print_path_fold(w, "seq", path.children[:])
	case .Alternative:
		print_path_fold(w, "alt", path.children[:])
	case .Inverse:
		io.write_string(w, "(reverse ")
		print_path(w, path.children[0])
		io.write_byte(w, ')')
	case .Zero_Or_More:
		io.write_string(w, "(path* ")
		print_path(w, path.children[0])
		io.write_byte(w, ')')
	case .One_Or_More:
		io.write_string(w, "(path+ ")
		print_path(w, path.children[0])
		io.write_byte(w, ')')
	case .Zero_Or_One:
		io.write_string(w, "(path? ")
		print_path(w, path.children[0])
		io.write_byte(w, ')')
	case .Negated_Set:
		io.write_string(w, "(notoneof")
		for member in path.children {
			io.write_byte(w, ' ')
			print_path(w, member)
		}
		io.write_byte(w, ')')
	}
}

// print_path_fold prints an n-ary sequence/alternative as ARQ's nested
// binary form: (seq (seq a b) c).
@(private = "file")
print_path_fold :: proc(w: io.Writer, name: string, parts: []^Path_Expr) {
	if len(parts) == 1 {
		print_path(w, parts[0])
		return
	}
	io.write_byte(w, '(')
	io.write_string(w, name)
	io.write_byte(w, ' ')
	print_path_fold(w, name, parts[:len(parts) - 1])
	io.write_byte(w, ' ')
	print_path(w, parts[len(parts) - 1])
	io.write_byte(w, ')')
}

// print_expr renders an expression inline in SSE.
@(private)
print_expr :: proc(w: io.Writer, e: Expr) {
	switch v in e {
	case ^Binary_Expr:
		io.write_byte(w, '(')
		io.write_string(w, binary_op_name(v.op))
		io.write_byte(w, ' ')
		print_expr(w, v.left)
		io.write_byte(w, ' ')
		print_expr(w, v.right)
		io.write_byte(w, ')')
	case ^Unary_Expr:
		io.write_byte(w, '(')
		switch v.op {
		case .Not:
			io.write_byte(w, '!')
		case .Plus:
			io.write_byte(w, '+')
		case .Minus:
			io.write_byte(w, '-')
		}
		io.write_byte(w, ' ')
		print_expr(w, v.operand)
		io.write_byte(w, ')')
	case ^Builtin_Call:
		io.write_byte(w, '(')
		io.write_string(w, builtin_sse_name(v.builtin))
		for arg in v.args {
			io.write_byte(w, ' ')
			print_expr(w, arg)
		}
		io.write_byte(w, ')')
	case ^Function_Call:
		io.write_byte(w, '(')
		print_iri(w, v.iri)
		for arg in v.args {
			io.write_byte(w, ' ')
			print_expr(w, arg)
		}
		io.write_byte(w, ')')
	case ^In_Expr:
		io.write_string(w, "(notin " if v.negated else "(in ")
		print_expr(w, v.value)
		for item in v.list {
			io.write_byte(w, ' ')
			print_expr(w, item)
		}
		io.write_byte(w, ')')
	case ^Exists_Expr:
		io.write_string(w, "(notexists " if v.negated else "(exists ")
		if v.algebra != nil {
			print_op(w, v.algebra, 0)
		} else {
			// Untranslated EXISTS (printing a raw parse): the pattern is
			// not algebra yet.
			io.write_string(w, "<group>")
		}
		io.write_byte(w, ')')
	case ^Aggregate:
		io.write_byte(w, '(')
		io.write_string(w, aggregate_sse_name(v.op))
		if v.is_distinct {
			io.write_string(w, " distinct")
		}
		if v.op == .Group_Concat && v.has_separator {
			io.write_string(w, " (separator ")
			print_string_lexical(w, v.separator)
			io.write_byte(w, ')')
		}
		if !v.star && v.expr != nil {
			io.write_byte(w, ' ')
			print_expr(w, v.expr)
		}
		io.write_byte(w, ')')
	case Var:
		print_var(w, v)
	case rdf.IRI:
		print_iri(w, v)
	case rdf.Literal:
		print_literal(w, v)
	}
}

@(private = "file")
print_node :: proc(w: io.Writer, node: Pattern_Node) {
	switch v in node {
	case rdf.IRI:
		print_iri(w, v)
	case rdf.Blank_Node:
		io.write_string(w, "_:")
		io.write_string(w, string(v))
	case rdf.Literal:
		print_literal(w, v)
	case Var:
		print_var(w, v)
	case ^Path_Expr:
		print_path(w, v)
	}
}

@(private = "file")
print_var :: proc(w: io.Writer, v: Var) {
	io.write_byte(w, '?')
	io.write_string(w, v.name)
}

@(private = "file")
print_iri :: proc(w: io.Writer, iri: rdf.IRI) {
	io.write_byte(w, '<')
	io.write_string(w, string(iri))
	io.write_byte(w, '>')
}

// print_literal follows ARQ: the four numeric/boolean XSD types with
// their lexical form bare, language-tagged and plain strings quoted,
// anything else quoted with its datatype.
@(private = "file")
print_literal :: proc(w: io.Writer, lit: rdf.Literal) {
	switch lit.datatype {
	case rdf.XSD_INTEGER, rdf.XSD_DECIMAL, rdf.XSD_DOUBLE, rdf.XSD_BOOLEAN:
		io.write_string(w, lit.lexical)
		return
	}
	print_string_lexical(w, lit.lexical)
	if lit.language != "" {
		io.write_byte(w, '@')
		io.write_string(w, lit.language)
		if lit.direction == .LTR {
			io.write_string(w, "--ltr")
		} else if lit.direction == .RTL {
			io.write_string(w, "--rtl")
		}
		return
	}
	if lit.datatype != rdf.XSD_STRING {
		io.write_string(w, "^^")
		print_iri(w, lit.datatype)
	}
}

@(private = "file")
print_string_lexical :: proc(w: io.Writer, s: string) {
	io.write_byte(w, '"')
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
		case '"':
			io.write_string(w, "\\\"")
		case '\\':
			io.write_string(w, "\\\\")
		case '\n':
			io.write_string(w, "\\n")
		case '\r':
			io.write_string(w, "\\r")
		case '\t':
			io.write_string(w, "\\t")
		case:
			io.write_byte(w, c)
		}
	}
	io.write_byte(w, '"')
}

@(private = "file")
binary_op_name :: proc(op: Binary_Op) -> string {
	switch op {
	case .Or:
		return "||"
	case .And:
		return "&&"
	case .Eq:
		return "="
	case .Ne:
		return "!="
	case .Lt:
		return "<"
	case .Gt:
		return ">"
	case .Le:
		return "<="
	case .Ge:
		return ">="
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	}
	return "?"
}

@(private = "file")
aggregate_sse_name :: proc(kw: Keyword) -> string {
	#partial switch kw {
	case .Count:
		return "count"
	case .Sum:
		return "sum"
	case .Min:
		return "min"
	case .Max:
		return "max"
	case .Avg:
		return "avg"
	case .Sample:
		return "sample"
	case .Group_Concat:
		return "group_concat"
	}
	return "aggregate"
}

// builtin_sse_name maps a built-in to ARQ's SSE tag. Most are the
// lowercase keyword; the is*/sameTerm family keeps ARQ's camelCase.
@(private = "file")
builtin_sse_name :: proc(kw: Keyword) -> string {
	#partial switch kw {
	case .Str:
		return "str"
	case .Lang:
		return "lang"
	case .Langmatches:
		return "langmatches"
	case .Datatype:
		return "datatype"
	case .Bound:
		return "bound"
	case .Iri:
		return "iri"
	case .Uri:
		return "uri"
	case .Bnode:
		return "bnode"
	case .Rand:
		return "rand"
	case .Abs:
		return "abs"
	case .Ceil:
		return "ceil"
	case .Floor:
		return "floor"
	case .Round:
		return "round"
	case .Concat:
		return "concat"
	case .Strlen:
		return "strlen"
	case .Ucase:
		return "ucase"
	case .Lcase:
		return "lcase"
	case .Encode_For_Uri:
		return "encode_for_uri"
	case .Contains:
		return "contains"
	case .Strstarts:
		return "strstarts"
	case .Strends:
		return "strends"
	case .Strbefore:
		return "strbefore"
	case .Strafter:
		return "strafter"
	case .Year:
		return "year"
	case .Month:
		return "month"
	case .Day:
		return "day"
	case .Hours:
		return "hours"
	case .Minutes:
		return "minutes"
	case .Seconds:
		return "seconds"
	case .Timezone:
		return "timezone"
	case .Tz:
		return "tz"
	case .Now:
		return "now"
	case .Uuid:
		return "uuid"
	case .Struuid:
		return "struuid"
	case .Md5:
		return "md5"
	case .Sha1:
		return "sha1"
	case .Sha256:
		return "sha256"
	case .Sha384:
		return "sha384"
	case .Sha512:
		return "sha512"
	case .Coalesce:
		return "coalesce"
	case .If:
		return "if"
	case .Strlang:
		return "strlang"
	case .Strdt:
		return "strdt"
	case .Same_Term:
		return "sameTerm"
	case .Is_Iri:
		return "isIRI"
	case .Is_Uri:
		return "isURI"
	case .Is_Blank:
		return "isBlank"
	case .Is_Literal:
		return "isLiteral"
	case .Is_Numeric:
		return "isNumeric"
	case .Regex:
		return "regex"
	case .Substr:
		return "substr"
	case .Replace:
		return "replace"
	case .Triple:
		return "triple"
	case .Subject:
		return "subject"
	case .Predicate:
		return "predicate"
	case .Object:
		return "object"
	case .Is_Triple:
		return "isTriple"
	case .Lang_Dir:
		return "langdir"
	case .Str_Lang_Dir:
		return "strlangdir"
	case .Has_Lang:
		return "haslang"
	case .Has_Lang_Dir:
		return "haslangdir"
	}
	return "builtin"
}
