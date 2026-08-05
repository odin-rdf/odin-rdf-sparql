package sparql

import "core:math"
import "core:testing"

import rdf "rdf:rdf"

// The value model's own tests, taken from the specification's operator
// tables rather than from what the suites happen to exercise. The suites
// are the oracle for whole queries; these pin the pieces, so a
// regression says which rule broke instead of which test failed.

@(private = "file")
lit :: proc(lexical: string, datatype: rdf.IRI) -> Value {
	return value_of(rdf.literal_typed(lexical, datatype))
}

@(private = "file")
plain :: proc(lexical: string) -> Value {
	return value_of(rdf.literal_plain(lexical))
}

@(test)
test_numeric_promotion_follows_the_tower :: proc(t: ^testing.T) {
	// §17.3: integer < decimal < float < double, and a binary operator
	// yields the higher of its operands' types.
	integer := lit("2", XSD_INTEGER)
	decimal := lit("2.5", XSD_DECIMAL)
	double := lit("2.5e0", XSD_DOUBLE)

	testing.expect(t, value_arithmetic(.Add, integer, integer).datatype == XSD_INTEGER, "integer + integer")
	testing.expect(t, value_arithmetic(.Add, integer, decimal).datatype == XSD_DECIMAL, "integer + decimal")
	testing.expect(t, value_arithmetic(.Add, decimal, double).datatype == XSD_DOUBLE, "decimal + double")

	// A derived integer type promotes as an integer while keeping its
	// own identity for DATATYPE — the distinction the type-promotion
	// suite is built on.
	short := lit("3", rdf.IRI(XSD + "short"))
	testing.expect(t, short.kind == .Numeric && short.numeric == .Integer, "xsd:short is an integer")
	testing.expect(t, value_datatype(short).text == XSD + "short", "DATATYPE keeps the written datatype")
	testing.expect(t, value_arithmetic(.Add, short, short).datatype == XSD_INTEGER, "shorts add as integers")
}

@(test)
test_integer_division_yields_decimal :: proc(t: ^testing.T) {
	// The one arithmetic result that is not the promoted operand type
	// (op:numeric-divide).
	one := lit("1", XSD_INTEGER)
	two := lit("2", XSD_INTEGER)
	quotient := value_arithmetic(.Divide, one, two)
	testing.expect(t, quotient.datatype == XSD_DECIMAL, "integer / integer is a decimal")
	testing.expect(t, quotient.number == 0.5, "1/2 is 0.5, not 0")

	zero := lit("0", XSD_INTEGER)
	testing.expect(t, value_is_error(value_arithmetic(.Divide, one, zero)), "dividing an exact type by zero errors")

	// The floating types have infinities and use them instead.
	double_one := lit("1", XSD_DOUBLE)
	double_zero := lit("0", XSD_DOUBLE)
	infinite := value_arithmetic(.Divide, double_one, double_zero)
	testing.expect(t, !value_is_error(infinite), "double division by zero is not an error")
	testing.expect(t, math.is_inf(infinite.number), "it is an infinity")
}

@(test)
test_effective_boolean_value :: proc(t: ^testing.T) {
	// §17.2.2, case by case.
	Case :: struct {
		value:    Value,
		expected: bool,
		defined:  bool,
		what:     string,
	}
	cases := [?]Case {
		{lit("true", XSD_BOOLEAN), true, true, "true"},
		{lit("false", XSD_BOOLEAN), false, true, "false"},
		{plain(""), false, true, "the empty string"},
		{plain("x"), true, true, "a non-empty string"},
		{lit("0", XSD_INTEGER), false, true, "zero"},
		{lit("-3", XSD_INTEGER), true, true, "a non-zero integer"},
		{lit("0.0", XSD_DOUBLE), false, true, "zero as a double"},
		{lit("NaN", XSD_DOUBLE), false, true, "NaN"},
		{value_of(rdf.IRI("http://example/x")), false, false, "an IRI"},
		{lit("abc", XSD_INTEGER), false, false, "an ill-typed literal"},
		{UNBOUND_VALUE, false, false, "an unbound variable"},
		{value_of(rdf.literal_lang("x", "en")), false, false, "a language-tagged string"},
	}
	for c in cases {
		result, ok := effective_boolean_value(c.value)
		testing.expectf(t, ok == c.defined, "%s: expected defined=%v", c.what, c.defined)
		if c.defined {
			testing.expectf(t, result == c.expected, "%s: expected %v", c.what, c.expected)
		}
	}
}

@(test)
test_equality_across_the_value_space :: proc(t: ^testing.T) {
	// Three outcomes, not two: equal, definitely unequal, and
	// indeterminate. The last is a type error, and conflating it with
	// "unequal" is the bug the open-world suite exists to catch.
	Case :: struct {
		a, b:     Value,
		expected: bool,
		defined:  bool,
		what:     string,
	}
	cases := [?]Case {
		{lit("1", XSD_INTEGER), lit("1.0", XSD_DECIMAL), true, true, "1 = 1.0 across the tower"},
		{plain("xyz"), lit("xyz", XSD_STRING), true, true, "a plain literal is an xsd:string"},
		{plain("xyz"), value_of(rdf.literal_lang("xyz", "en")), false, true, "a tag makes a different literal"},
		{
			value_of(rdf.literal_lang("xyz", "en")),
			value_of(rdf.literal_lang("xyz", "EN")),
			true,
			true,
			"language tags compare case-insensitively",
		},
		{
			value_of(rdf.literal_lang("xyz", "en")),
			lit("xyz", XSD_INTEGER),
			false,
			true,
			"a tagged literal is never an untagged one, whatever the untagged one means",
		},
		{plain("xyz"), lit("xyz", XSD_INTEGER), false, false, "an ill-typed literal's value is unknown"},
		{lit("xyz", XSD_INTEGER), lit("xyz", XSD_INTEGER), true, true, "identical terms are equal regardless"},
		{plain("xyz"), value_of(rdf.IRI("http://example/xyz")), false, true, "a literal is not an IRI"},
		{
			value_of(rdf.IRI("http://example/a")),
			value_of(rdf.IRI("http://example/b")),
			false,
			true,
			"different IRIs",
		},
	}
	for c in cases {
		equal, ok := value_equal(c.a, c.b)
		testing.expectf(t, ok == c.defined, "%s: expected defined=%v, got %v", c.what, c.defined, ok)
		if c.defined {
			testing.expectf(t, equal == c.expected, "%s: expected %v", c.what, c.expected)
		}
	}
}

@(test)
test_same_term_is_not_value_equality :: proc(t: ^testing.T) {
	one := lit("1", XSD_INTEGER)
	one_padded := lit("01", XSD_INTEGER)
	equal, ok := value_equal(one, one_padded)
	testing.expect(t, ok && equal, "1 and 01 are the same number")
	testing.expect(t, !value_same_term(one, one_padded), "…and different terms")
	testing.expect(t, value_same_term(one, one), "a term is the same term as itself")
}

@(test)
test_partially_timezoned_dates_are_indeterminate :: proc(t: ^testing.T) {
	// XSD's ±14-hour rule. A value written without a timezone denotes
	// any instant in a 28-hour window, so it compares definitely only
	// when the window clears the other value entirely.
	naive := lit("2006-08-23", XSD_DATE)
	zulu := lit("2006-08-23Z", XSD_DATE)
	far := lit("2001-01-01Z", XSD_DATE)

	_, overlapping := value_equal(naive, zulu)
	testing.expect(t, !overlapping, "same day, one timezoned: indeterminate")

	equal, defined := value_equal(naive, far)
	testing.expect(t, defined && !equal, "years apart: definitely unequal whatever the timezone")

	// Ordering clears the window too.
	order, ordered := value_compare(lit("2006-08-22", XSD_DATE), zulu)
	testing.expect(t, ordered && order < 0, "a day earlier clears the 14-hour window")

	// A date is not a dateTime, however they are written.
	date_vs_time_equal, date_vs_time_ok := value_equal(zulu, lit("2006-08-23T00:00:00Z", XSD_DATE_TIME))
	testing.expect(t, date_vs_time_ok && !date_vs_time_equal, "different types are definitely unequal")
}

@(test)
test_date_time_parsing :: proc(t: ^testing.T) {
	utc, utc_ok := parse_date_time("2006-08-23T09:00:00Z")
	testing.expect(t, utc_ok, "a Z-timezoned dateTime parses")
	offset, offset_ok := parse_date_time("2006-08-23T10:00:00+01:00")
	testing.expect(t, offset_ok, "an offset dateTime parses")
	testing.expect(t, utc.seconds == offset.seconds, "the same instant, written two ways")

	fractional, fractional_ok := parse_date_time("2006-08-23T09:00:00.500Z")
	testing.expect(t, fractional_ok && fractional.seconds == utc.seconds + 0.5, "fractional seconds")

	_, bad := parse_date_time("2006-08-23")
	testing.expect(t, !bad, "a date is not a dateTime")

	// The date parser must not mistake the date's own hyphens for a
	// timezone sign — the bug this test exists to prevent recurring.
	naive, naive_ok := parse_date("2006-08-23")
	testing.expect(t, naive_ok && !naive.has_tz && naive.year == 2006 && naive.month == 8 && naive.day == 23, "a bare date")
	zoned, zoned_ok := parse_date("2006-08-23+01:00")
	testing.expect(t, zoned_ok && zoned.has_tz && zoned.day == 23, "a timezoned date")
}

@(test)
test_ill_typed_literals_are_not_errors_until_used :: proc(t: ^testing.T) {
	// "abc"^^xsd:integer is a perfectly good RDF term and binding; it
	// becomes an error only when something asks for its value.
	ill := lit("abc", XSD_INTEGER)
	testing.expect(t, ill.kind == .Unknown_Literal, "an unparseable lexical form is an unknown-value literal")
	testing.expect(t, !value_is_error(ill), "…not an error")
	testing.expect(t, value_datatype(ill).text == string(XSD_INTEGER), "DATATYPE still answers")
	testing.expect(t, value_is_error(value_arithmetic(.Add, ill, lit("1", XSD_INTEGER))), "arithmetic on it errors")

	// Lexical forms strconv would accept but XSD does not.
	testing.expect(t, lit("1e5", XSD_DECIMAL).kind == .Unknown_Literal, "a decimal has no exponent")
	testing.expect(t, lit("1e5", XSD_DOUBLE).kind == .Numeric, "a double does")
	testing.expect(t, lit("0x10", XSD_INTEGER).kind == .Unknown_Literal, "no hexadecimal integers")
}

@(test)
test_langmatches_ranges :: proc(t: ^testing.T) {
	testing.expect(t, langmatches("en-GB", "en"), "a range matches at a subtag boundary")
	testing.expect(t, langmatches("en", "EN"), "matching is case-insensitive")
	testing.expect(t, !langmatches("english", "en"), "…but not mid-subtag")
	testing.expect(t, langmatches("fr", "*"), "* matches any tag")
	testing.expect(t, !langmatches("", "*"), "…except the absent one")
}
