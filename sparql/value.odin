// The expression value model (SPARQL-T-0012).
//
// Matching happens over Term_IDs; expressions do not. `?a + ?b` needs to
// know that "1"^^xsd:integer and "1.0"^^xsd:decimal are the same number,
// and no comparison of IDs will tell it that. So an expression works on
// Values: a term interpreted according to its datatype, with the lexical
// form parsed once.
//
// This is the materialization boundary the initiative's architecture
// names. Term_IDs come out of the store, `value_of` turns one into a
// Value, and everything above — comparison, arithmetic, effective
// boolean value — works on Values. Nothing below this file has ever seen
// an RDF term.
//
// Three things about the design are worth stating, because they are what
// the specification demands rather than what convenience would suggest.
//
// **A type error is a value.** SPARQL does not stop on a type error; it
// propagates one, and specific operators recover from it (`||` can still
// be true, FILTER treats it as false). So `.Error` is a Value_Kind, not
// a return code, and only the operators the spec names look at it.
//
// **An unparseable literal is not an error yet.** `"abc"^^xsd:integer` is
// a perfectly good RDF term and a perfectly good binding; it only errors
// when something tries to do arithmetic on it. It is classified as an
// unknown-value literal here, and the error appears at the operator.
//
// **Values remember their term.** DATATYPE, STR, and sameTerm ask about
// the RDF term, not the value, and `=` falls back to term comparison for
// datatypes it does not understand. Dropping the term after parsing
// would make those unanswerable.
package sparql

import "base:runtime"

import "core:math"
import "core:strconv"
import "core:strings"

import rdf "rdf:rdf"
import store "store:store"

XSD :: "http://www.w3.org/2001/XMLSchema#"
XSD_STRING :: rdf.IRI(XSD + "string")
XSD_BOOLEAN :: rdf.IRI(XSD + "boolean")
XSD_INTEGER :: rdf.IRI(XSD + "integer")
XSD_DECIMAL :: rdf.IRI(XSD + "decimal")
XSD_FLOAT :: rdf.IRI(XSD + "float")
XSD_DOUBLE :: rdf.IRI(XSD + "double")
XSD_DATE_TIME :: rdf.IRI(XSD + "dateTime")
XSD_DATE :: rdf.IRI(XSD + "date")

// Value_Kind is what an expression sees. Simple_String covers both the
// plain literal and xsd:string, which SPARQL 1.1 treats as the same
// thing; Unknown_Literal is a literal whose datatype this engine does
// not interpret, or one whose lexical form does not parse — both behave
// the same way, which is to say term-comparable and nothing else.
Value_Kind :: enum {
	Error,
	Unbound,
	IRI,
	Blank_Node,
	Triple,
	Simple_String,
	Lang_String,
	Boolean,
	Numeric,
	Date_Time,
	// xsd:date is its own kind rather than a dateTime at midnight: the
	// two are different types, so they are ordered against their own
	// kind and comparing one to the other is a type error, which is
	// what the open-world date tests check.
	Date,
	Unknown_Literal,
}

// Numeric_Kind is the rung of the numeric tower a value sits on. The
// order matters: promotion takes the higher of two operands, so these
// are declared in promotion order and compared as integers.
Numeric_Kind :: enum {
	None,
	Integer,
	Decimal,
	Float,
	Double,
}

// Date_Time is a parsed xsd:dateTime, kept as its fields plus the offset
// in minutes. has_tz records whether the lexical form carried one; a
// dateTime without a timezone is compared as if it were UTC, which is
// the implicit-timezone choice the family makes and states rather than
// leaving to chance.
Date_Time :: struct {
	year:    int,
	month:   int,
	day:     int,
	hour:    int,
	minute:  int,
	second:  f64,
	offset:  int,
	has_tz:  bool,
	seconds: f64, // the instant, for comparison
}

Value :: struct {
	kind:     Value_Kind,
	// The store ID this value was read from, when it was read from one.
	// A solution row holds IDs, so binding a variable to an expression
	// result needs the ID back — see bindable_id in exec.odin.
	source:     store.Term_ID,
	has_source: bool,
	numeric:  Numeric_Kind,
	term:     rdf.Term, // the RDF term this came from, where there is one
	integer:  i64,
	number:   f64,
	boolean:  bool,
	text:     string, // lexical form, or an IRI's string
	language: string,
	datatype: rdf.IRI,
	datetime: Date_Time,
}

ERROR_VALUE :: Value {
	kind = .Error,
}
UNBOUND_VALUE :: Value {
	kind = .Unbound,
}

value_boolean :: proc(b: bool) -> Value {
	return Value{kind = .Boolean, boolean = b, datatype = XSD_BOOLEAN}
}

value_integer :: proc(n: i64) -> Value {
	return Value{kind = .Numeric, numeric = .Integer, integer = n, number = f64(n), datatype = XSD_INTEGER}
}

value_double :: proc(x: f64) -> Value {
	return Value{kind = .Numeric, numeric = .Double, number = x, datatype = XSD_DOUBLE}
}

// value_simple_string, value_lang_string, and value_blank_node build
// the results the §17 function library returns. text is borrowed: a
// computed one lives in the evaluation context's scratch until the
// value has been rendered into a binding (see expr_own_text).
value_simple_string :: proc(text: string) -> Value {
	return Value{kind = .Simple_String, text = text, datatype = XSD_STRING}
}

value_lang_string :: proc(text: string, language: string) -> Value {
	return Value{kind = .Lang_String, text = text, language = language, datatype = rdf.RDF_LANG_STRING}
}

value_blank_node :: proc(label: string) -> Value {
	return Value{kind = .Blank_Node, text = label}
}

value_is_error :: proc(v: Value) -> bool {
	return v.kind == .Error
}

// value_of interprets an RDF term. This is the one place a term becomes
// a value; everything else in the expression engine works on the result.
value_of :: proc(term: rdf.Term) -> Value {
	switch v in term {
	case rdf.IRI:
		return Value{kind = .IRI, term = term, text = string(v)}
	case rdf.Blank_Node:
		return Value{kind = .Blank_Node, term = term, text = string(v)}
	case ^rdf.Triple:
		return Value{kind = .Triple, term = term}
	case rdf.Literal:
		return value_of_literal(v, term)
	case nil:
		return UNBOUND_VALUE
	}
	return ERROR_VALUE
}

@(private = "file")
value_of_literal :: proc(lit: rdf.Literal, term: rdf.Term) -> Value {
	out := Value {
		term     = term,
		text     = lit.lexical,
		language = lit.language,
		datatype = lit.datatype,
	}
	if lit.language != "" {
		out.kind = .Lang_String
		return out
	}
	switch lit.datatype {
	case XSD_STRING:
		out.kind = .Simple_String
		return out
	case XSD_BOOLEAN:
		// An unparseable boolean is an ill-typed literal, not an error:
		// it is only an error when something asks for its value.
		switch lit.lexical {
		case "true", "1":
			out.kind = .Boolean
			out.boolean = true
		case "false", "0":
			out.kind = .Boolean
			out.boolean = false
		case:
			out.kind = .Unknown_Literal
		}
		return out
	case XSD_DATE_TIME:
		if parsed, ok := parse_date_time(lit.lexical); ok {
			out.kind = .Date_Time
			out.datetime = parsed
		} else {
			out.kind = .Unknown_Literal
		}
		return out
	case XSD_DATE:
		if parsed, ok := parse_date(lit.lexical); ok {
			out.kind = .Date
			out.datetime = parsed
		} else {
			out.kind = .Unknown_Literal
		}
		return out
	}
	if numeric := numeric_kind_of(lit.datatype); numeric != .None {
		if fill_numeric(&out, lit.lexical, numeric) {
			return out
		}
		out.kind = .Unknown_Literal
		return out
	}
	out.kind = .Unknown_Literal
	return out
}

// numeric_kind_of maps a datatype IRI to its rung of the numeric tower.
// The derived integer types (xsd:byte, xsd:short, …) are integers for
// promotion purposes, which is what the type-promotion suite checks;
// their identity survives in the value's datatype, so DATATYPE still
// answers with the datatype the term was written with.
@(private = "file")
numeric_kind_of :: proc(datatype: rdf.IRI) -> Numeric_Kind {
	if !strings.has_prefix(string(datatype), XSD) {
		return .None
	}
	switch string(datatype)[len(XSD):] {
	case "integer",
	     "long",
	     "int",
	     "short",
	     "byte",
	     "nonPositiveInteger",
	     "negativeInteger",
	     "nonNegativeInteger",
	     "positiveInteger",
	     "unsignedLong",
	     "unsignedInt",
	     "unsignedShort",
	     "unsignedByte":
		return .Integer
	case "decimal":
		return .Decimal
	case "float":
		return .Float
	case "double":
		return .Double
	}
	return .None
}

@(private = "file")
fill_numeric :: proc(out: ^Value, lexical: string, kind: Numeric_Kind) -> bool {
	out.kind = .Numeric
	out.numeric = kind
	if kind == .Integer {
		n, ok := strconv.parse_i64_of_base(strings.trim_space(lexical), 10)
		if !ok {
			return false
		}
		out.integer = n
		out.number = f64(n)
		return true
	}
	trimmed := strings.trim_space(lexical)
	if !valid_numeric_lexical(trimmed, kind) {
		return false
	}
	x, ok := strconv.parse_f64(trimmed)
	if !ok {
		return false
	}
	out.number = x
	out.integer = i64(x)
	return true
}

// valid_numeric_lexical rejects lexical forms strconv would accept but
// XSD does not — "1e5" is not an xsd:decimal, and hexadecimal is not any
// of these. Accepting them would make an ill-typed literal look like a
// number, and the open-world tests are precisely about not doing that.
@(private = "file")
valid_numeric_lexical :: proc(s: string, kind: Numeric_Kind) -> bool {
	if s == "" {
		return false
	}
	body := s
	if body[0] == '+' || body[0] == '-' {
		body = body[1:]
	}
	if body == "" {
		return false
	}
	if kind == .Decimal {
		// [0-9]* '.'? [0-9]* with at least one digit and no exponent.
		digits, dots := 0, 0
		for c in body {
			switch {
			case c >= '0' && c <= '9':
				digits += 1
			case c == '.':
				dots += 1
			case:
				return false
			}
		}
		return digits > 0 && dots <= 1
	}
	// float and double additionally allow an exponent and the special
	// values XSD spells in capitals.
	switch body {
	case "INF", "NaN":
		return true
	}
	digits, dots, exponents := 0, 0, 0
	for i := 0; i < len(body); i += 1 {
		c := body[i]
		switch {
		case c >= '0' && c <= '9':
			digits += 1
		case c == '.':
			dots += 1
		case c == 'e' || c == 'E':
			exponents += 1
			if i + 1 < len(body) && (body[i + 1] == '+' || body[i + 1] == '-') {
				i += 1
			}
		case:
			return false
		}
	}
	return digits > 0 && dots <= 1 && exponents <= 1
}

// parse_date reads the xsd:date lexical form by completing it to a
// dateTime at midnight — the same fields, so the same comparison, while
// the kind keeps the two types apart.
parse_date :: proc(lexical: string) -> (dt: Date_Time, ok: bool) {
	s := strings.trim_space(lexical)
	// The date part is a fixed width — yyyy-mm-dd, one longer for a
	// negative year — and whatever follows is the timezone. Scanning
	// backwards for a sign instead would find the date's own hyphens.
	date_len := 11 if strings.has_prefix(s, "-") else 10
	if len(s) < date_len {
		return {}, false
	}
	completed := strings.concatenate({s[:date_len], "T00:00:00", s[date_len:]}, context.temp_allocator)
	return parse_date_time(completed)
}

// parse_date_time reads the xsd:dateTime lexical form. seconds is filled
// with the instant so comparison is one subtraction.
parse_date_time :: proc(lexical: string) -> (dt: Date_Time, ok: bool) {
	s := strings.trim_space(lexical)
	negative_year := false
	if strings.has_prefix(s, "-") {
		negative_year = true
		s = s[1:]
	}
	// yyyy-mm-ddThh:mm:ss[.fff][Z|(+|-)hh:mm]
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':' {
		return {}, false
	}
	dt.year = int_field(s[0:4]) or_return
	dt.month = int_field(s[5:7]) or_return
	dt.day = int_field(s[8:10]) or_return
	dt.hour = int_field(s[11:13]) or_return
	dt.minute = int_field(s[14:16]) or_return
	if negative_year {
		dt.year = -dt.year
	}

	rest := s[17:]
	seconds_end := 0
	for seconds_end < len(rest) && (rest[seconds_end] == '.' || (rest[seconds_end] >= '0' && rest[seconds_end] <= '9')) {
		seconds_end += 1
	}
	if seconds_end == 0 {
		return {}, false
	}
	dt.second = strconv.parse_f64(rest[:seconds_end]) or_return
	zone := rest[seconds_end:]
	switch {
	case zone == "":
	// No timezone; treated as UTC when compared. See Date_Time.
	case zone == "Z":
		dt.has_tz = true
	case len(zone) == 6 && (zone[0] == '+' || zone[0] == '-') && zone[3] == ':':
		hours := int_field(zone[1:3]) or_return
		minutes := int_field(zone[4:6]) or_return
		dt.offset = hours * 60 + minutes
		if zone[0] == '-' {
			dt.offset = -dt.offset
		}
		dt.has_tz = true
	case:
		return {}, false
	}

	dt.seconds = f64(days_from_civil(dt.year, dt.month, dt.day)) * 86400
	dt.seconds += f64(dt.hour) * 3600 + f64(dt.minute) * 60 + dt.second
	dt.seconds -= f64(dt.offset) * 60
	return dt, true
}

@(private = "file")
int_field :: proc(s: string) -> (n: int, ok: bool) {
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	value := strconv.parse_int(s) or_return
	return value, true
}

// days_from_civil is Howard Hinnant's civil-to-days algorithm: days
// since 1970-01-01 for a proleptic Gregorian date. Written out rather
// than taken from core:time because it must accept the years outside
// time.Time's range that XSD permits.
@(private = "file")
days_from_civil :: proc(y, m, d: int) -> int {
	year := y
	year -= 1 if m <= 2 else 0
	era := (year if year >= 0 else year - 399) / 400
	year_of_era := year - era * 400
	day_of_year := (153 * (m + (-3 if m > 2 else 9)) + 2) / 5 + d - 1
	day_of_era := year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
	return era * 146097 + day_of_era - 719468
}

// promote returns the rung two numeric operands meet on. The tower is
// integer < decimal < float < double (§17.3), so promotion is a max.
@(private)
promote :: proc(a, b: Numeric_Kind) -> Numeric_Kind {
	return a if a > b else b
}

// numeric_compare orders two numeric values. Integers compare as
// integers so large values that f64 cannot represent exactly still
// compare correctly; anything mixed goes through f64, which is the
// precision this engine offers for decimals (documented rather than
// silently assumed).
@(private = "file")
numeric_compare :: proc(a, b: Value) -> (order: int, ok: bool) {
	if a.numeric == .Integer && b.numeric == .Integer {
		switch {
		case a.integer < b.integer:
			return -1, true
		case a.integer > b.integer:
			return +1, true
		}
		return 0, true
	}
	x, y := a.number, b.number
	if math.is_nan(x) || math.is_nan(y) {
		// NaN is unordered and not equal to anything, including itself.
		return 0, false
	}
	switch {
	case x < y:
		return -1, true
	case x > y:
		return +1, true
	}
	return 0, true
}

// value_compare orders two values where SPARQL defines an order:
// numerics, strings, booleans, and dateTimes, each against its own kind.
// ok is false when the pair has no defined order — which the relational
// operators turn into a type error.
value_compare :: proc(a, b: Value) -> (order: int, ok: bool) {
	if a.kind == .Numeric && b.kind == .Numeric {
		return numeric_compare(a, b)
	}
	if is_string_kind(a) && is_string_kind(b) {
		// Only plain strings are ordered against each other; a
		// language-tagged string is ordered only against one with the
		// same tag, and never against a plain string.
		if a.kind != b.kind {
			return 0, false
		}
		if a.kind == .Lang_String && !strings.equal_fold(a.language, b.language) {
			return 0, false
		}
		return text_compare(a.text, b.text), true
	}
	if a.kind == .Boolean && b.kind == .Boolean {
		if a.boolean == b.boolean {
			return 0, true
		}
		return -1 if !a.boolean else +1, true
	}
	if (a.kind == .Date_Time && b.kind == .Date_Time) || (a.kind == .Date && b.kind == .Date) {
		return compare_instants(a.datetime, b.datetime)
	}
	return 0, false
}

// compare_instants orders two dateTimes or dates under XSD's partial
// order. A value written without a timezone does not denote one instant
// but any instant within ±14 hours of it — the range of legal
// timezones — so it compares definitely against a timezoned value only
// when the whole window falls on one side. Overlapping windows are
// *indeterminate*, which is a type error rather than a false.
//
// This is what the DAWG date tests are testing, and it is not the rule a
// reasonable person would guess: `"2006-08-23"^^xsd:date` compared to
// `"2006-08-23Z"^^xsd:date` is indeterminate (the windows overlap),
// while the same comparison against `"2001-01-01Z"^^xsd:date` is a
// definite inequality (years apart, no overlap possible).
@(private = "file")
compare_instants :: proc(a, b: Date_Time) -> (order: int, ok: bool) {
	if a.has_tz == b.has_tz {
		switch {
		case a.seconds < b.seconds:
			return -1, true
		case a.seconds > b.seconds:
			return +1, true
		}
		return 0, true
	}
	MAX_TIMEZONE_SECONDS :: f64(14 * 3600)
	a_low, a_high := a.seconds, a.seconds
	b_low, b_high := b.seconds, b.seconds
	if !a.has_tz {
		a_low -= MAX_TIMEZONE_SECONDS
		a_high += MAX_TIMEZONE_SECONDS
	} else {
		b_low -= MAX_TIMEZONE_SECONDS
		b_high += MAX_TIMEZONE_SECONDS
	}
	if a_high < b_low {
		return -1, true
	}
	if a_low > b_high {
		return +1, true
	}
	return 0, false
}

@(private = "file")
is_string_kind :: proc(v: Value) -> bool {
	return v.kind == .Simple_String || v.kind == .Lang_String
}

// text_compare orders two strings by codepoint, which is what SPARQL's
// default collation asks for — UTF-8's byte order and codepoint order
// agree, so a byte comparison is a codepoint comparison.
//
// It exists instead of strings.compare because that one is wrong for a
// pair of empty strings. It reaches runtime.memory_compare, which
// answers from the pointers before it looks at the length:
//
//	case x == y:   return 0
//	case x == nil: return -1
//
// Two zero-length strings whose data pointers differ — one a slice of
// the query text, one a compile-time constant — therefore compare as
// *unequal*, and `FILTER(lang(?v) = "")` silently matched nothing.
// core:bytes.compare guards the case; runtime.string_cmp does not.
text_compare :: proc(a, b: string) -> int {
	shared := min(len(a), len(b))
	for i in 0 ..< shared {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else +1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else +1
}

// value_equal implements `=` (§17.4.1.7 RDFterm-equal, extended by the
// operator table). The three outcomes are the point: two values can be
// equal, known to be unequal, or *not comparable* — and the last is a
// type error, not false. Returning false there would make
// `FILTER(?a != ?b)` quietly true for literals the engine does not
// understand, which is exactly what the open-world tests catch.
value_equal :: proc(a, b: Value) -> (equal: bool, ok: bool) {
	if a.kind == .Error || b.kind == .Error || a.kind == .Unbound || b.kind == .Unbound {
		return false, false
	}
	if order, comparable := value_compare(a, b); comparable {
		return order == 0, true
	}
	// Outside the value space, RDF term identity decides — when it can.
	if a.kind == .IRI && b.kind == .IRI {
		return a.text == b.text, true
	}
	if a.kind == .Blank_Node && b.kind == .Blank_Node {
		return a.text == b.text, true
	}
	if a.kind == .Triple && b.kind == .Triple {
		return triple_equal(a.term, b.term)
	}

	if is_literal_kind(a) && is_literal_kind(b) {
		// A language tag is a term-level distinction that holds whatever
		// the literals mean: a language-tagged literal is never the same
		// as one without a tag, even when nothing is known about the
		// other's datatype. The open-world suite is built around exactly
		// this line — `"xyz"@en != "xyz"^^xsd:integer` is definitely
		// true, while `"xyz" != "xyz"^^xsd:integer` is a type error,
		// because there the ill-typed literal could denote anything.
		a_tagged := a.kind == .Lang_String
		b_tagged := b.kind == .Lang_String
		if a_tagged != b_tagged {
			return false, true
		}
		if a_tagged {
			// Both tagged, and value_compare declined — so the tags
			// differ, or the lexical forms do. Either way, different
			// literals. (Tags compare case-insensitively: "xyz"@en and
			// "xyz"@EN are one literal, and value_compare said so.)
			return false, true
		}
		if terms_identical(a, b) {
			return true, true
		}
		// Same type, and the comparison above declined: the values are
		// not merely different, they are *indeterminate* — the partially
		// timezoned dates are the case that exists. An indeterminate
		// comparison is a type error, not a false.
		if a.kind == b.kind && in_value_space(a) {
			return false, false
		}
		// Two literals whose datatypes the engine both understands are
		// genuinely unequal — a number is not a string, a date is not a
		// dateTime. If either is ill-typed or of an unknown datatype, its
		// value is unknown, and an unknown value cannot be shown
		// different from anything.
		if in_value_space(a) && in_value_space(b) {
			return false, true
		}
		return false, false
	}

	// A literal is not an IRI and not a blank node, an IRI is not a
	// blank node: all definite inequalities, whatever the literal means.
	return false, true
}

// triple_equal is `=` over two triple terms: component-wise, by value.
// Two triple terms are equal when all three components are equal, and
// unequal as soon as one is definitely unequal — so
// `<<( :a :b 1 )>> = <<( :a :b 1.0 )>>` is true where sameTerm is false,
// which is exactly what the 1.2 suite's `op-2` pins.
//
// An error in a component is only decisive when nothing else already
// decided: a pair with one definitely-unequal component is unequal
// whatever the engine can or cannot say about the others.
@(private = "file")
triple_equal :: proc(a, b: rdf.Term) -> (equal: bool, ok: bool) {
	left, left_is_triple := a.(^rdf.Triple)
	right, right_is_triple := b.(^rdf.Triple)
	if !left_is_triple || !right_is_triple || left == nil || right == nil {
		return false, false
	}
	comparable := true
	for component, i in ([3]rdf.Term{left.subject, left.predicate, left.object}) {
		other := ([3]rdf.Term{right.subject, right.predicate, right.object})[i]
		same, decided := value_equal(value_of(component), value_of(other))
		if !decided {
			comparable = false
			continue
		}
		if !same {
			return false, true
		}
	}
	return comparable, comparable
}

@(private = "file")
is_literal_kind :: proc(v: Value) -> bool {
	switch v.kind {
	case .Simple_String, .Lang_String, .Boolean, .Numeric, .Date_Time, .Date, .Unknown_Literal:
		return true
	case .Error, .Unbound, .IRI, .Blank_Node, .Triple:
		return false
	}
	return false
}

// in_value_space reports whether the engine interprets a literal's
// datatype — that is, whether it can say what the literal *means* rather
// than only what it says.
@(private = "file")
in_value_space :: proc(v: Value) -> bool {
	switch v.kind {
	case .Simple_String, .Lang_String, .Boolean, .Numeric, .Date_Time, .Date:
		return true
	case .Error, .Unbound, .IRI, .Blank_Node, .Triple, .Unknown_Literal:
		return false
	}
	return false
}

@(private = "file")
terms_identical :: proc(a, b: Value) -> bool {
	return a.text == b.text && a.datatype == b.datatype && strings.equal_fold(a.language, b.language)
}

// value_same_term is sameTerm: RDF term identity, with no value
// interpretation at all. "1"^^xsd:integer and "01"^^xsd:integer are the
// same number and different terms.
value_same_term :: proc(a, b: Value) -> bool {
	if a.kind == .Error || b.kind == .Error || a.kind == .Unbound || b.kind == .Unbound {
		return false
	}
	if is_literal_kind(a) != is_literal_kind(b) {
		return false
	}
	if is_literal_kind(a) {
		return terms_identical(a, b)
	}
	if a.kind != b.kind {
		return false
	}
	if a.kind == .Triple {
		return rdf.equal_term(a.term, b.term)
	}
	return a.text == b.text
}

// effective_boolean_value is §17.2.2. ok is false for a type error,
// which is what a FILTER turns into "drop the row" and `||` may still
// recover from.
effective_boolean_value :: proc(v: Value) -> (result: bool, ok: bool) {
	#partial switch v.kind {
	case .Boolean:
		return v.boolean, true
	case .Simple_String:
		return len(v.text) > 0, true
	case .Numeric:
		if math.is_nan(v.number) {
			return false, true
		}
		if v.numeric == .Integer {
			return v.integer != 0, true
		}
		return v.number != 0, true
	}
	// Everything else — an IRI, a blank node, a language-tagged string,
	// an ill-typed literal, an unbound variable — has no effective
	// boolean value.
	return false, false
}

// Arith_Op is the arithmetic the numeric operators share.
Arith_Op :: enum {
	Add,
	Subtract,
	Multiply,
	Divide,
}

// value_arithmetic applies a numeric operator with §17.3 promotion. The
// result's datatype is the promoted rung — which is what the
// type-promotion suite asserts through `datatype(?l + ?r)`.
value_arithmetic :: proc(op: Arith_Op, a, b: Value) -> Value {
	if a.kind != .Numeric || b.kind != .Numeric {
		return ERROR_VALUE
	}
	kind := promote(a.numeric, b.numeric)
	// Integer division yields a decimal (op:numeric-divide), the one
	// place the result is not simply the promoted operand type.
	if op == .Divide && kind == .Integer {
		kind = .Decimal
	}

	if kind == .Integer {
		x, y := a.integer, b.integer
		out: i64
		switch op {
		case .Add:
			out = x + y
		case .Subtract:
			out = x - y
		case .Multiply:
			out = x * y
		case .Divide:
			return ERROR_VALUE // unreachable: promoted to decimal above
		}
		return Value{kind = .Numeric, numeric = .Integer, integer = out, number = f64(out), datatype = XSD_INTEGER}
	}

	x, y := a.number, b.number
	out: f64
	switch op {
	case .Add:
		out = x + y
	case .Subtract:
		out = x - y
	case .Multiply:
		out = x * y
	case .Divide:
		// Dividing an exact type by zero is an error; the floating
		// types have infinities and say so instead.
		if y == 0 && kind == .Decimal {
			return ERROR_VALUE
		}
		out = x / y
	}
	return Value {
		kind = .Numeric,
		numeric = kind,
		number = out,
		integer = i64(out),
		datatype = numeric_datatype(kind),
	}
}

value_negate :: proc(v: Value) -> Value {
	if v.kind != .Numeric {
		return ERROR_VALUE
	}
	out := v
	out.term = nil
	// The negated value is a different value from the one that was read,
	// so it must not keep the ID that one came from — carrying it would
	// bind a variable to the un-negated term.
	out.source = store.UNBOUND
	out.has_source = false
	out.integer = -v.integer
	out.number = -v.number
	out.datatype = numeric_datatype(v.numeric)
	return out
}

numeric_datatype :: proc(kind: Numeric_Kind) -> rdf.IRI {
	switch kind {
	case .Integer:
		return XSD_INTEGER
	case .Decimal:
		return XSD_DECIMAL
	case .Float:
		return XSD_FLOAT
	case .Double:
		return XSD_DOUBLE
	case .None:
		return ""
	}
	return ""
}

// value_datatype is the DATATYPE function: the datatype IRI of a
// literal, an error for anything else. It answers with the datatype the
// term carries, not the rung it was promoted to — `datatype("1"^^xsd:byte)`
// is xsd:byte even though arithmetic on it happens as an integer.
value_datatype :: proc(v: Value) -> Value {
	if !is_literal_kind(v) {
		return ERROR_VALUE
	}
	if v.kind == .Lang_String {
		return Value{kind = .IRI, text = string(rdf.RDF_LANG_STRING)}
	}
	datatype := v.datatype
	if datatype == "" {
		datatype = XSD_STRING
	}
	return Value{kind = .IRI, text = string(datatype)}
}

// value_str is the STR function: the lexical form of a literal or the
// string of an IRI, as a simple literal.
//
// A value read from the store answers with the lexical form its term
// carries — STR("01"^^xsd:integer) is "01", not "1". A value the query
// *computed* has no term and so no lexical form yet, and gets one from
// number_text; see the note there on why that is not the same rendering
// value_to_term uses.
value_str :: proc(v: Value, allocator := context.allocator) -> (result: Value, owned: string) {
	#partial switch v.kind {
	case .Error, .Unbound, .Blank_Node, .Triple:
		return ERROR_VALUE, ""
	case .IRI:
		return value_simple_string(v.text), ""
	case .Numeric:
		if v.term == nil {
			text := number_text(v, allocator)
			return value_simple_string(text), text
		}
	case .Boolean:
		if v.term == nil {
			return value_simple_string(v.boolean ? "true" : "false"), ""
		}
	}
	return value_simple_string(v.text), ""
}

// number_text writes a number the way a *string* should show it, which
// is not the way a *literal* should spell it — the two differ, and the
// suites pin both.
//
// value_to_term needs a canonical lexical form for the datatype it is
// about to write ("0.0"^^xsd:decimal, "1.0E0"^^xsd:double), because the
// result has to be a well-formed literal of that type. STR and the
// xsd:string cast are producing text, and the DAWG's cast-string
// expectations pin that text as the plain shortest form: xsd:string of
// the decimal 0.0 is "0", of the double 0E1 is "0", of the float 1.25
// is "1.25". Exponent notation returns only for magnitudes where the
// plain form would be hundreds of digits long.
//
// The caller owns the returned string.
number_text :: proc(v: Value, allocator := context.allocator) -> string {
	buf: [64]byte
	if v.numeric == .Integer {
		return strings.clone(strconv.write_int(buf[:], v.integer, 10), allocator)
	}
	return strings.clone(strip_plus(strconv.write_float(buf[:], v.number, 'g', -1, 64)), allocator)
}

// value_lang is the LANG function: a literal's language tag, or the
// empty string for one without.
value_lang :: proc(v: Value) -> Value {
	if !is_literal_kind(v) {
		return ERROR_VALUE
	}
	return Value{kind = .Simple_String, text = v.language, datatype = XSD_STRING}
}

// langmatches implements §17.4.1.6: a basic-language-range match, where
// "*" matches any non-empty tag and a range matches a tag that equals it
// or extends it at a subtag boundary.
langmatches :: proc(tag, range: string) -> bool {
	if range == "*" {
		return tag != ""
	}
	if len(tag) < len(range) {
		return false
	}
	if !strings.equal_fold(tag[:len(range)], range) {
		return false
	}
	return len(tag) == len(range) || tag[len(range)] == '-'
}

// value_to_term renders a computed value back into an RDF term, in the
// datatype's canonical lexical form. Needed by BIND: a solution row
// holds term IDs, so a value the store has never seen has to become a
// term before it can be bound to a variable.
//
// The caller owns the returned term.
value_to_term :: proc(v: Value, allocator := context.allocator) -> (term: rdf.Term, ok: bool) {
	if v.kind == .Error || v.kind == .Unbound {
		return nil, false
	}
	// A value that already stands for a term is rendered as *that* term.
	// Canonicalizing it instead would answer with a different term than
	// the one the query named: STRDT("1", xsd:byte) must not come back as
	// "1"^^xsd:integer, and a date or an uninterpreted datatype has no
	// canonical form this engine could write.
	if v.term != nil {
		return rdf.clone_term(v.term, allocator), true
	}
	#partial switch v.kind {
	case .IRI:
		return rdf.IRI(strings.clone(v.text, allocator)), true
	case .Blank_Node:
		return rdf.Blank_Node(strings.clone(v.text, allocator)), true
	case .Boolean:
		return owned_literal(v.boolean ? "true" : "false", XSD_BOOLEAN, "", allocator), true
	case .Simple_String:
		return owned_literal(v.text, XSD_STRING, "", allocator), true
	case .Lang_String:
		return owned_literal(v.text, rdf.RDF_LANG_STRING, v.language, allocator), true
	case .Numeric:
		lexical := numeric_lexical(v, allocator)
		defer delete(lexical, allocator)
		return owned_literal(lexical, numeric_datatype(v.numeric), "", allocator), true
	}
	// A kind with neither a term nor a canonical form — a date or an
	// uninterpreted datatype that was somehow computed rather than read.
	// There is nothing to write, so the binding does not happen.
	return nil, false
}

// owned_literal builds a literal that owns every string in it —
// including the datatype IRI, which is otherwise a compile-time constant.
// rdf.destroy_term frees all three, so a term that borrows any of them
// cannot be destroyed, and a computed term must be destroyable: it is
// held for the life of the query and released with it.
@(private = "file")
owned_literal :: proc(lexical: string, datatype: rdf.IRI, language: string, allocator: runtime.Allocator) -> rdf.Term {
	return rdf.Literal {
		lexical = strings.clone(lexical, allocator),
		datatype = rdf.IRI(strings.clone(string(datatype), allocator)),
		language = strings.clone(language, allocator),
	}
}

// numeric_lexical writes a number in its datatype's canonical form.
// xsd:double and xsd:float use exponent notation, which is what the
// expected results of the operator suites are written in.
numeric_lexical :: proc(v: Value, allocator: runtime.Allocator) -> string {
	buf: [64]byte
	switch v.numeric {
	case .Integer:
		return strings.clone(strconv.write_int(buf[:], v.integer, 10), allocator)
	case .Decimal:
		text := strip_plus(strconv.write_float(buf[:], v.number, 'f', -1, 64))
		if !strings.contains(text, ".") {
			return strings.concatenate({text, ".0"}, allocator)
		}
		return strings.clone(text, allocator)
	case .Float, .Double:
		return strings.clone(strip_plus(strconv.write_float(buf[:], v.number, 'E', -1, 64)), allocator)
	case .None:
	}
	return strings.clone("", allocator)
}

@(private = "file")
strip_plus :: proc(s: string) -> string {
	if len(s) > 0 && s[0] == '+' {
		return s[1:]
	}
	return s
}
