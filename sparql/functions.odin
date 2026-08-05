// The §17 built-in function library (SPARQL-T-0014): one dispatch from
// the parser's Keyword to an implementation over the T-0012 value
// model, plus the §17.5 XSD casts, which arrive as ordinary function
// calls on an XSD IRI rather than as built-ins.
//
// Three things shape this file more than the individual functions do.
//
// **Most functions are strict, and a few deliberately are not.** The
// common shape is: evaluate the arguments, and if any is a type error
// the call is a type error. But COALESCE exists precisely to swallow
// one, IF must not evaluate the branch it does not take, BOUND asks
// about a binding rather than a value, and CONCAT of nothing is the
// empty string rather than an arity error. Those five are handled
// before the strict path, which is why eval_builtin has two halves.
//
// **String functions are about language tags, not about strings.**
// §17.4.3.1's argument-compatibility rule is the whole content of
// STRSTARTS, STRENDS, CONTAINS, STRBEFORE, and STRAFTER: two arguments
// are compatible when the second is plain, or when both carry the same
// tag — and an incompatible pair is an error, not a false. The
// derived-tag rules then say which functions carry the tag through
// (SUBSTR, REPLACE, UCASE, STRBEFORE on a hit) and which flatten to a
// plain literal (ENCODE_FOR_URI, the hashes, STRBEFORE on a miss).
// Getting these wrong produces answers that look right and are not,
// which is why they have their own tests.
//
// **Four functions are not pure**, and each keeps its state in the
// query's evaluation context rather than in a global: NOW is one
// instant for the whole query (§17.4.5.1), BNODE returns the same node
// for the same string within one solution mapping and a different one
// across solutions (§17.4.2.2), and RAND and UUID draw from a
// per-query generator. A global would make two concurrent queries share
// a counter and make NOW drift mid-query.
package sparql

import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import crypto_hash "core:crypto/hash"
import rdf "rdf:rdf"
import store "store:store"

XSD_DAY_TIME_DURATION :: rdf.IRI(XSD + "dayTimeDuration")

// Odin cannot index a string constant, so the hex alphabets are
// variables. ENCODE_FOR_URI's percent-escapes are uppercase (RFC 3986
// prefers it) and the hash digests are lowercase (what every expected
// result in the suites is written in).
@(private = "file")
HEX_UPPER := "0123456789ABCDEF"
@(private = "file")
HEX_LOWER := "0123456789abcdef"

// eval_builtin applies one BuiltInCall. It never fails: an argument it
// cannot use produces a type-error Value, which the caller recovers
// from or passes on.
eval_builtin :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	// The forms that do not simply evaluate every argument first.
	#partial switch e.builtin {
	case .Bound:
		return eval_bound(ctx, e)
	case .Coalesce:
		return eval_coalesce(ctx, e)
	case .If:
		return eval_if(ctx, e)
	case .Concat:
		return eval_concat(ctx, e)
	case .Bnode:
		return eval_bnode(ctx, e)
	case .Now:
		return ctx.now
	case .Rand:
		return value_double(expr_random(ctx))
	case .Uuid:
		return eval_uuid(ctx, iri = true)
	case .Struuid:
		return eval_uuid(ctx, iri = false)
	}

	if len(e.args) == 0 {
		return ERROR_VALUE
	}
	first := expr_eval(ctx, e.args[0])
	if first.kind == .Error {
		return ERROR_VALUE
	}

	// The one-argument functions.
	#partial switch e.builtin {
	case .Datatype:
		return value_datatype(first)
	case .Str:
		text, owned := value_str(first, ctx.allocator)
		if owned != "" {
			expr_adopt_text(ctx, owned)
		}
		return text
	case .Lang:
		return value_lang(first)
	case .Is_Iri, .Is_Uri:
		return kind_test(first, .IRI)
	case .Is_Blank:
		return kind_test(first, .Blank_Node)
	case .Is_Triple:
		return kind_test(first, .Triple)
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
	case .Iri, .Uri:
		return eval_iri(ctx, first)
	case .Strlen:
		text, string_ok := string_operand(first)
		if !string_ok {
			return ERROR_VALUE
		}
		return value_integer(i64(utf8.rune_count_in_string(text)))
	case .Ucase:
		return eval_case(ctx, first, upper = true)
	case .Lcase:
		return eval_case(ctx, first, upper = false)
	case .Encode_For_Uri:
		return eval_encode_for_uri(ctx, first)
	case .Abs, .Ceil, .Floor, .Round:
		return eval_numeric_unary(e.builtin, first)
	case .Year, .Month, .Day, .Hours, .Minutes, .Seconds, .Timezone, .Tz:
		return eval_datetime_accessor(ctx, e.builtin, first)
	case .Md5, .Sha1, .Sha256, .Sha384, .Sha512:
		return eval_hash(ctx, e.builtin, first)
	case .Subject, .Predicate, .Object:
		return eval_triple_accessor(e.builtin, first)
	}

	// Everything left takes at least two arguments.
	if len(e.args) < 2 {
		return ERROR_VALUE
	}
	second := expr_eval(ctx, e.args[1])
	if second.kind == .Error {
		return ERROR_VALUE
	}

	#partial switch e.builtin {
	case .Same_Term:
		if first.kind == .Unbound || second.kind == .Unbound {
			return ERROR_VALUE
		}
		return value_boolean(value_same_term(first, second))
	case .Langmatches:
		if first.kind != .Simple_String || second.kind != .Simple_String {
			return ERROR_VALUE
		}
		return value_boolean(langmatches(first.text, second.text))
	case .Contains, .Strstarts, .Strends:
		return eval_string_test(e.builtin, first, second)
	case .Strbefore, .Strafter:
		return eval_string_split(ctx, e.builtin, first, second)
	case .Strdt:
		return eval_strdt(ctx, first, second)
	case .Strlang:
		return eval_strlang(ctx, first, second)
	case .Substr:
		return eval_substr(ctx, e, first, second)
	case .Regex:
		return eval_regex(ctx, e, first, second)
	case .Replace:
		return eval_replace(ctx, e, first, second)
	case .Triple:
		return eval_triple_constructor(ctx, e, first, second)
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

// BOUND asks about the binding, not the value, so its argument is not
// evaluated in the ordinary way — an unbound variable must reach it as
// "unbound" rather than as an error.
@(private = "file")
eval_bound :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
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

// COALESCE (§17.4.1.3) is the one function whose contract is to absorb
// errors: it returns the first argument that evaluates without one, and
// is itself an error only when every argument raised one. An unbound
// variable raises one, which is what makes COALESCE(?x, -1) a default.
@(private = "file")
eval_coalesce :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	for arg in e.args {
		value := expr_eval(ctx, arg)
		if value.kind == .Error || value.kind == .Unbound {
			continue
		}
		return value
	}
	return ERROR_VALUE
}

// IF (§17.4.1.2) evaluates the condition and then exactly one branch —
// evaluating both would make IF(1/0, false, true) an error rather than
// true, and IF's whole purpose is to guard the branch it does not take.
@(private = "file")
eval_if :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	if len(e.args) != 3 {
		return ERROR_VALUE
	}
	condition, defined := effective_boolean_value(expr_eval(ctx, e.args[0]))
	if !defined {
		return ERROR_VALUE
	}
	return expr_eval(ctx, e.args[1] if condition else e.args[2])
}

// CONCAT (§17.4.3.12) takes any number of string literals, including
// none. The result carries a language tag only when every argument
// carried the same one; otherwise it is a plain literal, even if some
// arguments were tagged.
@(private = "file")
eval_concat :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	b := strings.builder_make(ctx.allocator)
	language := ""
	uniform := true
	for arg, i in e.args {
		value := expr_eval(ctx, arg)
		text, ok := string_operand(value)
		if !ok {
			strings.builder_destroy(&b)
			return ERROR_VALUE
		}
		strings.write_string(&b, text)
		tag := value.language if value.kind == .Lang_String else ""
		if i == 0 {
			language = tag
		} else if !strings.equal_fold(language, tag) {
			uniform = false
		}
	}
	text := expr_adopt_text(ctx, strings.to_string(b))
	if uniform && language != "" {
		return value_lang_string(text, expr_own_text(ctx, language))
	}
	return value_simple_string(text)
}

// BNODE (§17.4.2.2) makes a node distinct from every node in the data
// and from the nodes other solutions made. With an argument, the same
// string yields the same node within one solution mapping — which is
// what expr_context_new_solution resets.
@(private = "file")
eval_bnode :: proc(ctx: ^Expr_Context, e: ^Builtin_Call) -> Value {
	if len(e.args) == 0 {
		// Every call is a distinct node, so the label need only outlive
		// this evaluation.
		return value_blank_node(expr_adopt_text(ctx, expr_fresh_blank(ctx)))
	}
	if len(e.args) != 1 {
		return ERROR_VALUE
	}
	value := expr_eval(ctx, e.args[0])
	if value.kind != .Simple_String {
		return ERROR_VALUE
	}
	for entry in ctx.bnodes {
		if entry.key == value.text {
			return value_blank_node(entry.label)
		}
	}
	label := expr_fresh_blank(ctx)
	append(&ctx.bnodes, Bnode_Binding{key = strings.clone(value.text, ctx.allocator), label = label})
	return value_blank_node(label)
}

@(private = "file")
eval_uuid :: proc(ctx: ^Expr_Context, iri: bool) -> Value {
	text := expr_uuid_string(ctx)
	if !iri {
		return value_simple_string(text)
	}
	return Value{kind = .IRI, text = expr_adopt_text(ctx, strings.concatenate({"urn:uuid:", text}, ctx.allocator))}
}

// IRI (§17.4.2.8) resolves a relative reference against the query's
// base IRI, which is why the base has to reach evaluation at all. An
// IRI argument is already absolute — the parser resolved it — and comes
// back unchanged.
@(private = "file")
eval_iri :: proc(ctx: ^Expr_Context, v: Value) -> Value {
	if v.kind == .IRI {
		// Unchanged, source and all: IRI(?x) on an IRI already bound is
		// the identity, and keeping the store ID saves rendering the term
		// and looking it up again.
		return v
	}
	if v.kind != .Simple_String {
		return ERROR_VALUE
	}
	scratch: Resolve_Scratch
	defer resolve_scratch_destroy(&scratch)
	resolved, ok := iri_resolve_build(ctx.base, v.text, &scratch)
	if !ok {
		// A relative reference with no base established. §17.4.2.8 leaves
		// this implementation-defined; an error is the honest answer,
		// since the function cannot produce the IRI it was asked for.
		return ERROR_VALUE
	}
	return Value{kind = .IRI, text = expr_own_text(ctx, resolved)}
}

// STRDT (§17.4.2.9) builds a literal with the given datatype. The
// lexical form is not validated: "abc"^^xsd:integer is a perfectly good
// RDF term, and only an operator that needs its value errors on it
// (see value.odin's header).
@(private = "file")
eval_strdt :: proc(ctx: ^Expr_Context, lexical, datatype: Value) -> Value {
	if lexical.kind != .Simple_String || datatype.kind != .IRI {
		return ERROR_VALUE
	}
	return expr_literal(ctx, lexical.text, rdf.IRI(datatype.text), "")
}

// STRLANG (§17.4.2.10) builds a language-tagged literal. An empty tag
// would produce a literal RDF cannot represent, so it is an error.
@(private = "file")
eval_strlang :: proc(ctx: ^Expr_Context, lexical, tag: Value) -> Value {
	if lexical.kind != .Simple_String || tag.kind != .Simple_String || tag.text == "" {
		return ERROR_VALUE
	}
	return expr_literal(ctx, lexical.text, rdf.RDF_LANG_STRING, tag.text)
}

@(private = "file")
eval_case :: proc(ctx: ^Expr_Context, v: Value, upper: bool) -> Value {
	text, ok := string_operand(v)
	if !ok {
		return ERROR_VALUE
	}
	b := strings.builder_make(ctx.allocator)
	for r in text {
		strings.write_rune(&b, unicode.to_upper(r) if upper else unicode.to_lower(r))
	}
	return derived_string(ctx, v, expr_adopt_text(ctx, strings.to_string(b)))
}

// ENCODE_FOR_URI (§17.4.3.11) percent-encodes everything outside RFC
// 3986's unreserved set, over the UTF-8 bytes. The result is a plain
// literal whatever the argument was: an encoded IRI component is not
// text in a language.
@(private = "file")
eval_encode_for_uri :: proc(ctx: ^Expr_Context, v: Value) -> Value {
	text, ok := string_operand(v)
	if !ok {
		return ERROR_VALUE
	}
	b := strings.builder_make(ctx.allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX_UPPER[c >> 4])
			strings.write_byte(&b, HEX_UPPER[c & 0xF])
		}
	}
	return value_simple_string(expr_adopt_text(ctx, strings.to_string(b)))
}

// eval_string_test is CONTAINS, STRSTARTS, and STRENDS: a boolean over
// a compatible pair (§17.4.3.1). Comparison is by codepoint, so the
// byte-level test below is also the character-level one.
@(private = "file")
eval_string_test :: proc(op: Keyword, a, b: Value) -> Value {
	if !strings_compatible(a, b) {
		return ERROR_VALUE
	}
	#partial switch op {
	case .Contains:
		return value_boolean(strings.contains(a.text, b.text))
	case .Strstarts:
		return value_boolean(strings.has_prefix(a.text, b.text))
	case .Strends:
		return value_boolean(strings.has_suffix(a.text, b.text))
	}
	return ERROR_VALUE
}

// eval_string_split is STRBEFORE and STRAFTER (§17.4.3.14/15). The
// asymmetry in the result's language tag is the spec's, not an
// oversight: a hit carries the first argument's tag through, and a miss
// returns a *plain* empty literal — so strbefore("abc"@en,"z") is ""
// and strbefore("abc"@en,"") is ""@en.
@(private = "file")
eval_string_split :: proc(ctx: ^Expr_Context, op: Keyword, a, b: Value) -> Value {
	if !strings_compatible(a, b) {
		return ERROR_VALUE
	}
	at := strings.index(a.text, b.text)
	if at < 0 {
		return value_simple_string("")
	}
	if op == .Strbefore {
		return derived_string(ctx, a, a.text[:at])
	}
	return derived_string(ctx, a, a.text[at + len(b.text):])
}

// SUBSTR (§17.4.3.3) is XPath's fn:substring: positions are 1-based and
// counted in codepoints, the arguments are rounded, and a range that
// runs off either end is clipped rather than being an error.
@(private = "file")
eval_substr :: proc(ctx: ^Expr_Context, e: ^Builtin_Call, source, start: Value) -> Value {
	text, ok := string_operand(source)
	if !ok || start.kind != .Numeric {
		return ERROR_VALUE
	}
	from := round_half_up(start.number)
	to := math.inf_f64(1)
	if len(e.args) >= 3 {
		length := expr_eval(ctx, e.args[2])
		if length.kind != .Numeric {
			return ERROR_VALUE
		}
		if math.is_nan(length.number) {
			return derived_string(ctx, source, "")
		}
		to = from + round_half_up(length.number)
	}
	if math.is_nan(from) {
		return derived_string(ctx, source, "")
	}

	b := strings.builder_make(ctx.allocator)
	position := f64(1)
	for r in text {
		if position >= from && position < to {
			strings.write_rune(&b, r)
		}
		position += 1
	}
	return derived_string(ctx, source, expr_adopt_text(ctx, strings.to_string(b)))
}

// round_half_up is XPath's fn:round — ties go to positive infinity, so
// round(-1.5) is -1 and not -2.
@(private = "file")
round_half_up :: proc(x: f64) -> f64 {
	if math.is_nan(x) || math.is_inf(x) {
		return x
	}
	return math.floor(x + 0.5)
}

// eval_numeric_unary is ABS, CEIL, FLOOR, and ROUND (§17.4.4). Each
// answers in its argument's type: the ceiling of a decimal is a
// decimal, not an integer.
@(private = "file")
eval_numeric_unary :: proc(op: Keyword, v: Value) -> Value {
	if v.kind != .Numeric {
		return ERROR_VALUE
	}
	if v.numeric == .Integer {
		out := v.integer
		if op == .Abs && out < 0 {
			out = -out
		}
		return Value {
			kind = .Numeric,
			numeric = .Integer,
			integer = out,
			number = f64(out),
			datatype = XSD_INTEGER,
		}
	}
	x := v.number
	#partial switch op {
	case .Abs:
		x = math.abs(x)
	case .Ceil:
		x = math.ceil(x)
	case .Floor:
		x = math.floor(x)
	case .Round:
		x = round_half_up(x)
	case:
		return ERROR_VALUE
	}
	return Value {
		kind = .Numeric,
		numeric = v.numeric,
		number = x,
		integer = i64(x),
		datatype = numeric_datatype(v.numeric),
	}
}

// eval_datetime_accessor is §17.4.5's YEAR through TZ. The fields are
// read as the lexical form wrote them, not normalized to UTC — HOURS of
// "2010-12-21T15:38:02-08:00" is 15, which is what makes TIMEZONE and
// TZ meaningful alongside them.
@(private = "file")
eval_datetime_accessor :: proc(ctx: ^Expr_Context, op: Keyword, v: Value) -> Value {
	if v.kind != .Date_Time && v.kind != .Date {
		return ERROR_VALUE
	}
	dt := v.datetime
	#partial switch op {
	case .Year:
		return value_integer(i64(dt.year))
	case .Month:
		return value_integer(i64(dt.month))
	case .Day:
		return value_integer(i64(dt.day))
	case .Hours:
		return value_integer(i64(dt.hour))
	case .Minutes:
		return value_integer(i64(dt.minute))
	case .Seconds:
		// xsd:decimal, because a dateTime's seconds field may be
		// fractional.
		return Value {
			kind = .Numeric,
			numeric = .Decimal,
			number = dt.second,
			integer = i64(dt.second),
			datatype = XSD_DECIMAL,
		}
	case .Timezone:
		// An xsd:dayTimeDuration, and an error rather than an empty one
		// when the value has no timezone: there is no duration to name.
		if !dt.has_tz {
			return ERROR_VALUE
		}
		return expr_literal(ctx, duration_lexical(ctx, dt.offset), XSD_DAY_TIME_DURATION, "")
	case .Tz:
		// A simple literal, and the empty string when there is none —
		// TZ reports the lexical form's timezone, and "absent" is one of
		// its answers.
		if !dt.has_tz {
			return value_simple_string("")
		}
		return value_simple_string(timezone_lexical(ctx, dt.offset))
	}
	return ERROR_VALUE
}

// duration_lexical writes an offset in minutes as an
// xsd:dayTimeDuration: "PT0S" for UTC, "-PT8H" for -08:00.
@(private = "file")
duration_lexical :: proc(ctx: ^Expr_Context, offset: int) -> string {
	if offset == 0 {
		return "PT0S"
	}
	b := strings.builder_make(ctx.allocator)
	magnitude := offset
	if magnitude < 0 {
		strings.write_byte(&b, '-')
		magnitude = -magnitude
	}
	strings.write_string(&b, "PT")
	if hours := magnitude / 60; hours > 0 {
		strings.write_int(&b, hours)
		strings.write_byte(&b, 'H')
	}
	if minutes := magnitude % 60; minutes > 0 {
		strings.write_int(&b, minutes)
		strings.write_byte(&b, 'M')
	}
	return expr_adopt_text(ctx, strings.to_string(b))
}

// timezone_lexical writes an offset the way a dateTime's lexical form
// does. Zero is "Z" rather than "+00:00": the two denote one timezone,
// and Z is its canonical spelling.
@(private = "file")
timezone_lexical :: proc(ctx: ^Expr_Context, offset: int) -> string {
	if offset == 0 {
		return "Z"
	}
	b := strings.builder_make(ctx.allocator)
	magnitude := offset
	strings.write_byte(&b, '+' if offset > 0 else '-')
	if magnitude < 0 {
		magnitude = -magnitude
	}
	write_two_digits(&b, magnitude / 60)
	strings.write_byte(&b, ':')
	write_two_digits(&b, magnitude % 60)
	return expr_adopt_text(ctx, strings.to_string(b))
}

@(private = "file")
write_two_digits :: proc(b: ^strings.Builder, n: int) {
	if n < 10 {
		strings.write_byte(b, '0')
	}
	strings.write_int(b, n)
}

// eval_hash is §17.4.6, over core:crypto. The digest is written as
// lowercase hex, which is the form the spec's examples and every
// expected result use.
@(private = "file")
eval_hash :: proc(ctx: ^Expr_Context, op: Keyword, v: Value) -> Value {
	if v.kind != .Simple_String {
		return ERROR_VALUE
	}
	algorithm: crypto_hash.Algorithm
	#partial switch op {
	case .Md5:
		algorithm = .Insecure_MD5
	case .Sha1:
		algorithm = .Insecure_SHA1
	case .Sha256:
		algorithm = .SHA256
	case .Sha384:
		algorithm = .SHA384
	case .Sha512:
		algorithm = .SHA512
	case:
		return ERROR_VALUE
	}
	digest := crypto_hash.hash_string(algorithm, v.text, context.temp_allocator)
	b := strings.builder_make(ctx.allocator)
	for octet in digest {
		strings.write_byte(&b, HEX_LOWER[octet >> 4])
		strings.write_byte(&b, HEX_LOWER[octet & 0xF])
	}
	return value_simple_string(expr_adopt_text(ctx, strings.to_string(b)))
}

// eval_regex is REGEX (§17.4.3.14). The compiled pattern is cached on
// the context: the pattern is a constant in every real query, and
// recompiling it once per solution would make a filter over a large
// result set quadratic in the pattern.
@(private = "file")
eval_regex :: proc(ctx: ^Expr_Context, e: ^Builtin_Call, text, pattern: Value) -> Value {
	subject, subject_ok := string_operand(text)
	if !subject_ok || pattern.kind != .Simple_String {
		return ERROR_VALUE
	}
	flags := ""
	if len(e.args) >= 3 {
		flags_value := expr_eval(ctx, e.args[2])
		if flags_value.kind != .Simple_String {
			return ERROR_VALUE
		}
		flags = flags_value.text
	}
	rx, ok := expr_regex(ctx, pattern.text, flags)
	if !ok {
		return ERROR_VALUE
	}
	matched, ran := regex_matches(rx, subject, ctx.allocator)
	if !ran {
		return ERROR_VALUE
	}
	return value_boolean(matched)
}

// eval_replace is REPLACE (§17.4.3.15). The result keeps the subject's
// language tag, so replacing inside "Français"@fr stays French.
@(private = "file")
eval_replace :: proc(ctx: ^Expr_Context, e: ^Builtin_Call, text, pattern: Value) -> Value {
	subject, subject_ok := string_operand(text)
	if !subject_ok || pattern.kind != .Simple_String || len(e.args) < 3 {
		return ERROR_VALUE
	}
	replacement := expr_eval(ctx, e.args[2])
	if replacement.kind != .Simple_String {
		return ERROR_VALUE
	}
	flags := ""
	if len(e.args) >= 4 {
		flags_value := expr_eval(ctx, e.args[3])
		if flags_value.kind != .Simple_String {
			return ERROR_VALUE
		}
		flags = flags_value.text
	}
	rx, ok := expr_regex(ctx, pattern.text, flags)
	if !ok {
		return ERROR_VALUE
	}
	result, ran := regex_replace(rx, subject, replacement.text, ctx.allocator)
	if !ran {
		delete(result, ctx.allocator)
		return ERROR_VALUE
	}
	return derived_string(ctx, text, expr_adopt_text(ctx, result))
}

// eval_triple_accessor is SUBJECT/PREDICATE/OBJECT (SPARQL 1.2): the
// components of a triple term.
@(private = "file")
eval_triple_accessor :: proc(op: Keyword, v: Value) -> Value {
	if v.kind != .Triple {
		return ERROR_VALUE
	}
	triple, is_triple := v.term.(^rdf.Triple)
	if !is_triple || triple == nil {
		return ERROR_VALUE
	}
	#partial switch op {
	case .Subject:
		return value_of(triple.subject)
	case .Predicate:
		return value_of(triple.predicate)
	case .Object:
		return value_of(triple.object)
	}
	return ERROR_VALUE
}

// TRIPLE(s, p, o) builds a triple term. The node is held in the
// evaluation scratch, so it survives long enough to be rendered into a
// binding and no longer.
@(private = "file")
eval_triple_constructor :: proc(ctx: ^Expr_Context, e: ^Builtin_Call, subject, predicate: Value) -> Value {
	if len(e.args) != 3 {
		return ERROR_VALUE
	}
	return build_triple_value(ctx, subject, predicate, expr_eval(ctx, e.args[2]))
}

// build_triple_value is the construction TRIPLE(s, p, o) and SPARQL
// 1.2's `<<( s p o )>>` written as an expression both perform: the same
// term, and the same refusals — a subject that is not a resource, a
// predicate that is not an IRI, an argument that is unbound or errored.
@(private)
build_triple_value :: proc(ctx: ^Expr_Context, subject, predicate, object: Value) -> Value {
	if object.kind == .Error || object.kind == .Unbound {
		return ERROR_VALUE
	}
	if subject.kind == .Error || predicate.kind == .Error {
		return ERROR_VALUE
	}
	if subject.kind == .Unbound || predicate.kind == .Unbound || predicate.kind != .IRI {
		return ERROR_VALUE
	}
	// RDF 1.2 admits a triple term as an object and nowhere else, so a
	// triple term in the subject position is an error rather than a
	// nested term — which is what `triple-on-triple-terms` pins.
	#partial switch subject.kind {
	case .IRI, .Blank_Node:
	case:
		return ERROR_VALUE
	}
	s, s_ok := value_to_term(subject, ctx.allocator)
	p, p_ok := value_to_term(predicate, ctx.allocator)
	o, o_ok := value_to_term(object, ctx.allocator)
	if !s_ok || !p_ok || !o_ok {
		rdf.destroy_term(s, ctx.allocator)
		rdf.destroy_term(p, ctx.allocator)
		rdf.destroy_term(o, ctx.allocator)
		return ERROR_VALUE
	}
	node := new(rdf.Triple, ctx.allocator)
	node^ = rdf.Triple {
		subject   = s,
		predicate = p,
		object    = o,
	}
	term := rdf.Term(node)
	append(&ctx.scratch, term)
	return Value{kind = .Triple, term = term}
}

// string_operand extracts the text of a string literal — plain,
// xsd:string, or language-tagged. It is the argument type most of §17.4
// names, and rejecting everything else here is what makes STRLEN(42) an
// error rather than 2.
@(private = "file")
string_operand :: proc(v: Value) -> (text: string, ok: bool) {
	if v.kind == .Simple_String || v.kind == .Lang_String {
		return v.text, true
	}
	return "", false
}

// strings_compatible is §17.4.3.1. Two string arguments are compatible
// when the second is plain — it then says nothing about language — or
// when both carry the same tag. A plain first argument and a tagged
// second are *not* compatible, which is why STRBEFORE("abc","b"@cy) is
// an error rather than a miss.
@(private = "file")
strings_compatible :: proc(a, b: Value) -> bool {
	if _, a_ok := string_operand(a); !a_ok {
		return false
	}
	if _, b_ok := string_operand(b); !b_ok {
		return false
	}
	if b.kind == .Simple_String {
		return true
	}
	return a.kind == .Lang_String && strings.equal_fold(a.language, b.language)
}

// derived_string builds a result that inherits its source's language
// tag — the rule §17.4.3.1 gives for SUBSTR, UCASE, LCASE, REPLACE, and
// STRBEFORE/STRAFTER on a hit.
@(private = "file")
derived_string :: proc(ctx: ^Expr_Context, source: Value, text: string) -> Value {
	if source.kind == .Lang_String {
		return value_lang_string(text, source.language)
	}
	return value_simple_string(text)
}

// eval_cast applies a §17.5 cast. The casts arrive as function calls on
// an XSD IRI rather than as built-ins, because that is how the grammar
// spells them.
//
// The lexical checking is not written out here: a cast from a string
// asks value_of to interpret the lexical form *as the target datatype*,
// which is the same code that decides whether a literal read from the
// store is in its value space. So "1.5" cannot become an xsd:integer
// for exactly the reason "1.5"^^xsd:integer is an ill-typed literal,
// and the two can never disagree.
eval_cast :: proc(ctx: ^Expr_Context, target: rdf.IRI, v: Value) -> Value {
	if v.kind == .Error || v.kind == .Unbound {
		return ERROR_VALUE
	}
	if target == XSD_STRING {
		return cast_to_string(ctx, v)
	}
	source_text: string
	#partial switch v.kind {
	case .Simple_String:
		source_text = v.text
	case .Boolean:
		return cast_from_boolean(ctx, target, v)
	case .Numeric:
		return cast_from_numeric(ctx, target, v)
	case .Date_Time:
		if target == XSD_DATE_TIME {
			return v
		}
		return ERROR_VALUE
	case:
		return ERROR_VALUE
	}
	// A cast from a string is a re-reading of its lexical form.
	if !cast_target_known(target) {
		return ERROR_VALUE
	}
	reread := value_of(rdf.Literal{lexical = source_text, datatype = target})
	if reread.kind == .Unknown_Literal {
		return ERROR_VALUE
	}
	return expr_literal(ctx, source_text, target, "")
}

@(private = "file")
cast_to_string :: proc(ctx: ^Expr_Context, v: Value) -> Value {
	#partial switch v.kind {
	case .IRI:
		// §17.5 admits an IRI as the one non-literal cast source: an IRI
		// has a lexical form and casting it is how a query gets at it.
		return value_simple_string(v.text)
	case .Simple_String:
		return value_simple_string(v.text)
	case .Boolean:
		return value_simple_string(v.boolean ? "true" : "false")
	case .Numeric:
		// The cast's text is the plain rendering, not the literal's
		// canonical lexical form — see number_text.
		return value_simple_string(expr_adopt_text(ctx, number_text(v, ctx.allocator)))
	case .Date_Time, .Date:
		return value_simple_string(v.text)
	}
	return ERROR_VALUE
}

@(private = "file")
cast_from_boolean :: proc(ctx: ^Expr_Context, target: rdf.IRI, v: Value) -> Value {
	switch target {
	case XSD_BOOLEAN:
		return value_boolean(v.boolean)
	case XSD_INTEGER:
		return value_integer(v.boolean ? 1 : 0)
	case XSD_DECIMAL, XSD_FLOAT, XSD_DOUBLE:
		return numeric_value(target, v.boolean ? 1 : 0)
	}
	return ERROR_VALUE
}

@(private = "file")
cast_from_numeric :: proc(ctx: ^Expr_Context, target: rdf.IRI, v: Value) -> Value {
	switch target {
	case XSD_BOOLEAN:
		if v.numeric == .Integer {
			return value_boolean(v.integer != 0)
		}
		return value_boolean(v.number != 0 && !math.is_nan(v.number))
	case XSD_INTEGER:
		if v.numeric == .Integer {
			return value_integer(v.integer)
		}
		if math.is_nan(v.number) || math.is_inf(v.number) {
			// There is no integer to truncate to.
			return ERROR_VALUE
		}
		// Truncation towards zero, which is what the cast table's
		// xs:integer row means and what -7.875 -> -7 checks.
		return value_integer(i64(v.number))
	case XSD_DECIMAL, XSD_FLOAT, XSD_DOUBLE:
		return numeric_value(target, v.number)
	}
	return ERROR_VALUE
}

@(private = "file")
numeric_value :: proc(datatype: rdf.IRI, x: f64) -> Value {
	kind := Numeric_Kind.Decimal
	switch datatype {
	case XSD_FLOAT:
		kind = .Float
	case XSD_DOUBLE:
		kind = .Double
	}
	return Value{kind = .Numeric, numeric = kind, number = x, integer = i64(x), datatype = datatype}
}

@(private = "file")
cast_target_known :: proc(target: rdf.IRI) -> bool {
	switch target {
	case XSD_STRING, XSD_BOOLEAN, XSD_INTEGER, XSD_DECIMAL, XSD_FLOAT, XSD_DOUBLE, XSD_DATE_TIME, XSD_DATE:
		return true
	}
	return false
}

// cast_iri reports whether a function call names a §17.5 cast rather
// than an extension function the engine does not have.
cast_iri :: proc(iri: rdf.IRI) -> bool {
	return cast_target_known(iri)
}

// builtin_implemented is what plan building consults to refuse a query
// rather than answer it wrongly. It is a list and not a default-true
// check on purpose: a built-in added to the grammar and forgotten here
// must show up as "the engine does not implement it", never as a filter
// that quietly matched nothing.
//
// The four absentees are SPARQL 1.2's base-direction functions —
// LANGDIR, STRLANGDIR, hasLANG, hasLANGDIR — which the grammar parses
// and SPARQL-T-0018 evaluates alongside the rest of the 1.2 surface.
builtin_implemented :: proc(kw: Keyword) -> bool {
	#partial switch kw {
	case .Str,
	     .Lang,
	     .Langmatches,
	     .Datatype,
	     .Bound,
	     .Iri,
	     .Uri,
	     .Bnode,
	     .Rand,
	     .Abs,
	     .Ceil,
	     .Floor,
	     .Round,
	     .Concat,
	     .Strlen,
	     .Ucase,
	     .Lcase,
	     .Encode_For_Uri,
	     .Contains,
	     .Strstarts,
	     .Strends,
	     .Strbefore,
	     .Strafter,
	     .Year,
	     .Month,
	     .Day,
	     .Hours,
	     .Minutes,
	     .Seconds,
	     .Timezone,
	     .Tz,
	     .Now,
	     .Uuid,
	     .Struuid,
	     .Md5,
	     .Sha1,
	     .Sha256,
	     .Sha384,
	     .Sha512,
	     .Coalesce,
	     .If,
	     .Strlang,
	     .Strdt,
	     .Same_Term,
	     .Is_Iri,
	     .Is_Uri,
	     .Is_Blank,
	     .Is_Literal,
	     .Is_Numeric,
	     .Regex,
	     .Substr,
	     .Replace,
	     .Triple,
	     .Subject,
	     .Predicate,
	     .Object,
	     .Is_Triple:
		return true
	}
	return false
}
