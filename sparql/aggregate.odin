// The set functions (SPARQL-T-0015): §18.5.1's aggregates, one
// accumulator per aggregate per group.
//
// An aggregate is fed one value per solution and asked for its answer
// once. Nothing here buffers the group's solutions — COUNT keeps a
// counter, SUM keeps a running total, MIN and MAX keep one term,
// GROUP_CONCAT keeps the string it is building. Only DISTINCT retains
// anything proportional to the group, and only the values it has already
// seen. That is the point of accumulating rather than collecting: a
// GROUP BY over a million solutions costs one accumulator per group, not
// a million rows.
//
// **Errors.** §18.5.1's set functions do not agree on what an error
// does, and the difference is observable, so it is stated per function
// rather than implied:
//
//   - COUNT does not count an error or an unbound value, and still
//     answers. `COUNT(?x)` over solutions where ?x is sometimes unbound
//     is the number of times it was bound.
//   - SAMPLE and GROUP_CONCAT skip them and still answer. A SAMPLE that
//     saw nothing usable is unbound; a GROUP_CONCAT is the empty string.
//   - SUM, AVG, MIN, and MAX are poisoned by one: the aggregate becomes
//     an error, which §18.5's Extend turns into an unbound variable in
//     the answer. That is what `agg-err-01` is: one blank node among a
//     group's numbers, and the group comes back with the key bound and
//     the average absent.
//
// **Store evidence (SPARQL-T-0019).** MIN and MAX over a plain variable
// are a full pass over the group to find the two ends of an order the
// store could have handed over for free: an ordered iterator would make
// them the first and last quads of a range, and a `MIN(?o)` over a
// million solutions a single read. The same iterator is what would let
// ORDER BY on a stored term stream instead of materializing (see
// Plan_Order). Recorded, not built — evaluation has to be correct over
// the match interface as it is today.
//
// **Why the sum is not an f64.** The rest of the engine evaluates
// xsd:decimal as a double and says so (value.odin). An aggregate is
// where that stops being a rounding choice and starts being a wrong
// answer: `SUM` over 1.0, 2.2, 3.5, 2.2, 2.2 is 11.1, and no order of
// f64 additions produces the double nearest 11.1 — every one of them
// lands a bit above, which prints as 11.100000000000001. So the integer
// and decimal rungs accumulate as an exact scaled integer, and the
// result is written from that. A float or a double anywhere in the group
// drops the accumulator to f64, where the tower says the answer is
// approximate anyway.
package sparql

import "base:runtime"

import "core:strings"

import rdf "rdf:rdf"
import record "record:record"

// DECIMAL_MAX_SCALE bounds the fraction digits a division may produce.
// XSD leaves decimal precision to the implementation and asks for at
// least 18 digits, which is what this is.
DECIMAL_MAX_SCALE :: 18

// DECIMAL_LIMIT keeps the exact accumulator inside i128 with room for
// one more scaling step. Crossing it drops the accumulator to f64
// rather than wrapping — a wrong answer must not be reachable by adding
// one more number.
DECIMAL_LIMIT :: i128(1) << 100

// Num_Accum is a running numeric total: exact while the values stay on
// the integer and decimal rungs, f64 once a float or a double joins.
Num_Accum :: struct {
	kind:     Numeric_Kind, // the promoted rung; .None while empty
	exact:    bool,
	unscaled: i128,
	scale:    int,
	number:   f64,
	count:    i64,
}

// num_accum_add folds one value into the total. ok is false when the
// value is not a number, which is what makes SUM and AVG error.
num_accum_add :: proc(a: ^Num_Accum, v: Value) -> (ok: bool) {
	if v.kind != .Numeric {
		return false
	}
	if a.kind == .None {
		a.kind = v.numeric
		a.exact = true
	} else {
		a.kind = promote(a.kind, v.numeric)
	}
	a.count += 1

	if a.exact && a.kind <= .Decimal {
		if unscaled, scale, exact := exact_decimal(v); exact {
			if add_decimal(a, unscaled, scale) {
				return true
			}
		}
	}
	if a.exact {
		a.number = num_accum_number(a^)
		a.exact = false
	}
	a.number += v.number
	return true
}

// num_accum_number is the total as a double, whichever representation it
// is being kept in.
num_accum_number :: proc(a: Num_Accum) -> f64 {
	if !a.exact {
		return a.number
	}
	return f64(a.unscaled) / pow10_f64(a.scale)
}

// num_accum_sum is SUM's answer (§18.5.1.4): the total, or the integer
// zero for a group that contributed no values.
//
// owned is the lexical form the caller must free once the value has been
// turned into a binding — an exact decimal has no home other than the
// literal it is written into.
num_accum_sum :: proc(a: Num_Accum, allocator: runtime.Allocator) -> (v: Value, owned: string) {
	if a.kind == .None {
		return value_integer(0), ""
	}
	if a.exact {
		if a.scale == 0 && a.kind == .Integer {
			return value_integer(i64(a.unscaled)), ""
		}
		return decimal_value(a.unscaled, a.scale, allocator)
	}
	inexact := Value {
		kind     = .Numeric,
		numeric  = a.kind,
		number   = a.number,
		integer  = i64(a.number),
		datatype = numeric_datatype(a.kind),
	}
	return inexact, ""
}

// num_accum_avg is AVG's answer (§18.5.1.7): the total divided by the
// number of values, and the integer zero for an empty group — which the
// specification defines rather than leaves undefined, and which
// `agg-avg-03` pins.
//
// The division follows op:numeric-divide, so a total on the integer rung
// answers as a decimal. An exact total divides exactly when the quotient
// terminates within DECIMAL_MAX_SCALE digits; otherwise it falls back to
// the f64 division, which is the precision the value model offers.
num_accum_avg :: proc(a: Num_Accum, allocator: runtime.Allocator) -> (v: Value, owned: string) {
	if a.kind == .None || a.count == 0 {
		return value_integer(0), ""
	}
	if a.exact {
		if unscaled, scale, ok := divide_decimal(a.unscaled, a.scale, i128(a.count)); ok {
			return decimal_value(unscaled, scale, allocator)
		}
	}
	total, total_owned := num_accum_sum(a, allocator)
	quotient := value_arithmetic(.Divide, total, value_integer(a.count))
	if total_owned != "" {
		delete(total_owned, allocator)
	}
	return quotient, ""
}

// decimal_value writes an exact scaled integer as an xsd:decimal literal
// and interprets it, so the value carries the term it will be bound as.
@(private = "file")
decimal_value :: proc(unscaled: i128, scale: int, allocator: runtime.Allocator) -> (v: Value, owned: string) {
	lexical := decimal_lexical(unscaled, scale, allocator)
	return value_of(rdf.Literal{lexical = lexical, datatype = XSD_DECIMAL}), lexical
}

// decimal_lexical spells a scaled integer. A decimal always shows a
// fraction, so a whole one is written "2.0" — which is both XSD's
// canonical form and what the suites' expected results hold.
@(private = "file")
decimal_lexical :: proc(unscaled: i128, scale: int, allocator: runtime.Allocator) -> string {
	digits: [64]byte
	magnitude := unscaled if unscaled >= 0 else -unscaled
	at := len(digits)
	for at == len(digits) || magnitude > 0 || len(digits) - at <= scale {
		at -= 1
		digits[at] = '0' + u8(magnitude % 10)
		magnitude /= 10
	}
	b := strings.builder_make(allocator)
	if unscaled < 0 {
		strings.write_byte(&b, '-')
	}
	whole := len(digits) - at - scale
	strings.write_string(&b, string(digits[at:at + whole]))
	strings.write_byte(&b, '.')
	if scale == 0 {
		strings.write_byte(&b, '0')
	} else {
		strings.write_string(&b, string(digits[at + whole:]))
	}
	return strings.to_string(b)
}

// exact_decimal reads a value as a scaled integer, when it has one. An
// integer always does; a decimal does when it was read from the store,
// because then it has a lexical form to read. A decimal the query
// computed carries only a double, and says so by answering false.
@(private = "file")
exact_decimal :: proc(v: Value) -> (unscaled: i128, scale: int, ok: bool) {
	#partial switch v.numeric {
	case .Integer:
		return i128(v.integer), 0, true
	case .Decimal:
		if v.term == nil {
			return 0, 0, false
		}
		return parse_decimal_lexical(v.text)
	}
	return 0, 0, false
}

@(private = "file")
parse_decimal_lexical :: proc(lexical: string) -> (unscaled: i128, scale: int, ok: bool) {
	text := lexical
	negative := false
	if len(text) > 0 && (text[0] == '-' || text[0] == '+') {
		negative = text[0] == '-'
		text = text[1:]
	}
	magnitude: i128
	digits, fraction := 0, -1
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '.' {
			if fraction >= 0 {
				return 0, 0, false
			}
			fraction = 0
			continue
		}
		if c < '0' || c > '9' {
			return 0, 0, false
		}
		magnitude = magnitude * 10 + i128(c - '0')
		if magnitude >= DECIMAL_LIMIT {
			return 0, 0, false
		}
		digits += 1
		if fraction >= 0 {
			fraction += 1
		}
	}
	if digits == 0 {
		return 0, 0, false
	}
	return -magnitude if negative else magnitude, max(fraction, 0), true
}

// add_decimal folds a scaled integer into the accumulator, aligning the
// two scales. false means the total would leave the exact range.
@(private = "file")
add_decimal :: proc(a: ^Num_Accum, unscaled: i128, scale: int) -> bool {
	target := max(a.scale, scale)
	if target > DECIMAL_MAX_SCALE {
		return false
	}
	left, left_ok := scale_decimal(a.unscaled, target - a.scale)
	right, right_ok := scale_decimal(unscaled, target - scale)
	if !left_ok || !right_ok {
		return false
	}
	total := left + right
	if total >= DECIMAL_LIMIT || total <= -DECIMAL_LIMIT {
		return false
	}
	a.unscaled = total
	a.scale = target
	return true
}

@(private = "file")
scale_decimal :: proc(unscaled: i128, by: int) -> (out: i128, ok: bool) {
	out = unscaled
	for _ in 0 ..< by {
		if out >= DECIMAL_LIMIT || out <= -DECIMAL_LIMIT {
			return 0, false
		}
		out *= 10
	}
	return out, true
}

// divide_decimal is long division to a terminating quotient. ok is false
// when the quotient does not terminate within DECIMAL_MAX_SCALE digits,
// which is the caller's signal to fall back to floating point rather
// than to hand back a truncation that looks exact.
@(private = "file")
divide_decimal :: proc(unscaled: i128, scale: int, divisor: i128) -> (out: i128, out_scale: int, ok: bool) {
	if divisor == 0 {
		return 0, 0, false
	}
	negative := (unscaled < 0) != (divisor < 0)
	numerator := unscaled if unscaled >= 0 else -unscaled
	denominator := divisor if divisor >= 0 else -divisor

	quotient := numerator / denominator
	remainder := numerator % denominator
	digits := scale
	for remainder != 0 && digits < DECIMAL_MAX_SCALE {
		if quotient >= DECIMAL_LIMIT / 10 {
			return 0, 0, false
		}
		remainder *= 10
		quotient = quotient * 10 + remainder / denominator
		remainder %= denominator
		digits += 1
	}
	if remainder != 0 {
		return 0, 0, false
	}
	return -quotient if negative else quotient, digits, true
}

@(private = "file")
pow10_f64 :: proc(n: int) -> f64 {
	out := 1.0
	for _ in 0 ..< n {
		out *= 10
	}
	return out
}

// Group_State is one group: the IDs its key expressions evaluated to,
// which become the bindings of its answer, and one accumulator per
// aggregate.
Group_State :: struct {
	key_ids: []record.Term_ID,
	accums:  []Agg_Accum,
}

// Agg_Accum is one aggregate's state within one group.
Agg_Accum :: struct {
	op:          Keyword,
	is_distinct: bool,
	star:        bool,
	separator:   string,
	// One error poisons SUM, AVG, MIN, and MAX; see the file header.
	errored:     bool,
	count:       i64,
	num:         Num_Accum,
	// MIN, MAX, and SAMPLE keep a term. It is a copy, because the value
	// it came from is only valid until the next solution is evaluated.
	best:        rdf.Term,
	best_value:  Value,
	has_best:    bool,
	concat:      strings.Builder,
	concat_n:    int,
	// DISTINCT's memory of what it has already folded in.
	seen:        map[string]bool,
	allocator:   runtime.Allocator,
}

// agg_accum_init prepares one aggregate's state for one group. The
// Aggregate is the algebra's and is borrowed; everything the accumulator
// allocates comes from the given allocator.
agg_accum_init :: proc(a: ^Agg_Accum, agg: ^Aggregate, allocator: runtime.Allocator) {
	a.op = agg.op
	a.is_distinct = agg.is_distinct
	a.star = agg.star
	a.separator = agg.separator if agg.has_separator else " "
	a.allocator = allocator
	if agg.op == .Group_Concat {
		a.concat = strings.builder_make(allocator)
	}
	if agg.is_distinct {
		a.seen = make(map[string]bool, allocator)
	}
}

// agg_accum_destroy frees what the accumulator retained: a DISTINCT
// modifier's seen-set, a GROUP_CONCAT's buffer, and the copy of the term
// MIN/MAX/SAMPLE is holding on to.
agg_accum_destroy :: proc(a: ^Agg_Accum) {
	if a.has_best {
		rdf.destroy_term(a.best, a.allocator)
	}
	if a.op == .Group_Concat {
		strings.builder_destroy(&a.concat)
	}
	for key in a.seen {
		delete(key, a.allocator)
	}
	delete(a.seen)
	a^ = {}
}

// agg_accum_row is COUNT(*): the solution itself is the value, so
// DISTINCT compares whole rows rather than one expression's result.
agg_accum_row :: proc(a: ^Agg_Accum, row: []record.Term_ID) {
	if a.is_distinct && !agg_first_sighting(a, row_key(row, a.allocator)) {
		return
	}
	a.count += 1
}

// agg_accum_value folds one solution's value into the aggregate.
agg_accum_value :: proc(a: ^Agg_Accum, v: Value) {
	if a.is_distinct {
		b := strings.builder_make(a.allocator)
		value_key(&b, v)
		if !agg_first_sighting(a, strings.to_string(b)) {
			return
		}
	}
	unusable := v.kind == .Error || v.kind == .Unbound
	#partial switch a.op {
	case .Count:
		if !unusable {
			a.count += 1
		}
	case .Sum, .Avg:
		if unusable || !num_accum_add(&a.num, v) {
			a.errored = true
		}
	case .Min, .Max:
		if unusable {
			a.errored = true
			return
		}
		agg_keep_extreme(a, v, a.op == .Min)
	case .Sample:
		if unusable || a.has_best {
			return
		}
		agg_replace_best(a, v)
	case .Group_Concat:
		if unusable {
			return
		}
		text, owned := value_str(v, a.allocator)
		defer if owned != "" {
			delete(owned, a.allocator)
		}
		if text.kind == .Error {
			return
		}
		if a.concat_n > 0 {
			strings.write_string(&a.concat, a.separator)
		}
		strings.write_string(&a.concat, text.text)
		a.concat_n += 1
	}
}

// agg_first_sighting takes ownership of key and reports whether it is new.
@(private = "file")
agg_first_sighting :: proc(a: ^Agg_Accum, key: string) -> bool {
	if key in a.seen {
		delete(key, a.allocator)
		return false
	}
	a.seen[key] = true
	return true
}

@(private = "file")
agg_keep_extreme :: proc(a: ^Agg_Accum, v: Value, want_smaller: bool) {
	if !a.has_best {
		agg_replace_best(a, v)
		return
	}
	order := value_order(v, a.best_value)
	if (want_smaller && order < 0) || (!want_smaller && order > 0) {
		agg_replace_best(a, v)
	}
}

// agg_replace_best copies the value's term so the winner survives the
// solution it came from — a backend may hand back a term that lives only
// until the next materialization.
@(private = "file")
agg_replace_best :: proc(a: ^Agg_Accum, v: Value) {
	term, rendered := value_to_term(v, a.allocator)
	if !rendered {
		a.errored = true
		return
	}
	if a.has_best {
		rdf.destroy_term(a.best, a.allocator)
	}
	a.best = term
	a.best_value = value_of(term)
	a.best_value.source = v.source
	a.best_value.has_source = v.has_source
	a.has_best = true
}

// agg_accum_value_of is the aggregate's answer. owned is a string the
// caller frees once the value has been turned into a binding.
agg_accum_value_of :: proc(a: ^Agg_Accum, allocator: runtime.Allocator) -> (v: Value, owned: string) {
	if a.errored {
		return ERROR_VALUE, ""
	}
	#partial switch a.op {
	case .Count:
		return value_integer(a.count), ""
	case .Sum:
		return num_accum_sum(a.num, allocator)
	case .Avg:
		return num_accum_avg(a.num, allocator)
	case .Min, .Max, .Sample:
		if !a.has_best {
			return UNBOUND_VALUE, ""
		}
		return a.best_value, ""
	case .Group_Concat:
		return value_simple_string(strings.to_string(a.concat)), ""
	}
	return ERROR_VALUE, ""
}

// value_key writes a value's identity as the RDF term it would be bound
// as. It is what GROUP BY partitions on and what DISTINCT deduplicates
// on, and it deliberately mirrors value_to_term rather than value
// equality: §18.5's Group compares the *terms* the key expressions
// evaluate to, so "1"^^xsd:integer and "1.0"^^xsd:decimal are two
// groups, not one.
// id_key is the same identity for a key that never left the ID space: a
// bare variable's binding. A store's dictionary is injective and the
// engine interns the terms it computes itself, so two equal IDs are one
// term and two different IDs are two — which is exactly what value_key
// establishes the long way round.
id_key :: proc(b: ^strings.Builder, id: record.Term_ID) {
	strings.write_byte(b, 'd')
	raw := id
	bytes := transmute([size_of(record.Term_ID)]u8)raw
	strings.write_bytes(b, bytes[:])
	strings.write_byte(b, 0)
}

// value_key writes a value's identity for a group table or a DISTINCT
// modifier: the long way round, through the term the value would bind.
value_key :: proc(b: ^strings.Builder, v: Value) {
	switch v.kind {
	case .Error, .Unbound:
		strings.write_byte(b, 'u')
	case .IRI:
		strings.write_byte(b, 'i')
		strings.write_string(b, v.text)
	case .Blank_Node:
		strings.write_byte(b, 'b')
		strings.write_string(b, v.text)
	case .Triple:
		strings.write_byte(b, 't')
		term_key(b, v.term)
	case .Simple_String, .Lang_String, .Boolean, .Numeric, .Date_Time, .Date, .Unknown_Literal:
		strings.write_byte(b, 'l')
		literal_key(b, v)
	}
	strings.write_byte(b, 0)
}

@(private = "file")
literal_key :: proc(b: ^strings.Builder, v: Value) {
	if v.term != nil {
		term_key(b, v.term)
		return
	}
	// A value the query computed has no lexical form yet; it gets the one
	// value_to_term would write for it, so a computed number and the same
	// number read from the store land in the same group.
	#partial switch v.kind {
	case .Boolean:
		write_literal_key(b, v.boolean ? "true" : "false", string(XSD_BOOLEAN), "")
	case .Numeric:
		lexical := numeric_lexical(v, b.buf.allocator)
		defer delete(lexical, b.buf.allocator)
		write_literal_key(b, lexical, string(numeric_datatype(v.numeric)), "")
	case .Lang_String:
		write_literal_key(b, v.text, string(rdf.RDF_LANG_STRING), v.language)
	case:
		write_literal_key(b, v.text, string(v.datatype), v.language)
	}
}

// term_key writes an RDF term's identity. It is the key a computed term
// is interned under as well as part of a group's key, and the two have
// to agree: a term that two solutions computed independently must be one
// term, or DISTINCT over it would see two.
@(private)
term_key :: proc(b: ^strings.Builder, term: rdf.Term) {
	switch t in term {
	case rdf.IRI:
		strings.write_byte(b, 'i')
		strings.write_string(b, string(t))
	case rdf.Blank_Node:
		strings.write_byte(b, 'b')
		strings.write_string(b, string(t))
	case rdf.Literal:
		strings.write_byte(b, 'l')
		write_literal_key(b, t.lexical, string(t.datatype), t.language)
	case ^rdf.Triple:
		strings.write_byte(b, 't')
		term_key(b, t.subject)
		term_key(b, t.predicate)
		term_key(b, t.object)
	case nil:
		strings.write_byte(b, 'u')
	}
}

// write_literal_key spells one literal. The language tag is folded
// because a tag's case is not part of the term — "x"@EN and "x"@en are
// one literal, and must be one group.
@(private = "file")
write_literal_key :: proc(b: ^strings.Builder, lexical, datatype, language: string) {
	strings.write_string(b, lexical)
	strings.write_byte(b, 0)
	strings.write_string(b, datatype)
	strings.write_byte(b, 0)
	for i in 0 ..< len(language) {
		c := language[i]
		strings.write_byte(b, c + 32 if c >= 'A' && c <= 'Z' else c)
	}
}
