package sparql

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"

// Per-function tests for the §17 library, written from the
// specification's own definitions and worked examples rather than from
// the suites — the suites are run separately in tests/w3c, and what
// they cover and what §17 *says* are not the same set. Where the spec
// prints a result ("STRBEFORE("abc"@en,"z") -> ''"), that is the case
// asserted here, verbatim.
//
// An expression is parsed and evaluated with no store behind it, so
// only the literal-and-constant part of the language is reachable —
// which is exactly the part these functions operate on.

@(private = "file")
Case :: struct {
	expr: string,
	want: string,
}

// eval_text parses one expression and evaluates it against an empty
// solution. The result is rendered the way an N-Triples term would be,
// with `error` and `unbound` for the two non-values.
@(private = "file")
eval_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> (rendered: string, ok: bool) {
	p: Parser
	parser_init(&p, transmute([]byte)text, "http://example.org/base/")
	defer parser_destroy(&p)
	advance(&p)
	e := parse_expression(&p)
	// A bare expression is not attached to a query or an algebra, so
	// parser_destroy will not reach it.
	defer destroy_expr(e, p.allocator)
	if !testing.expectf(t, p.err.kind == .None, "%q did not parse: %v", text, p.err.kind, loc = loc) {
		return "", false
	}

	slots: Var_Slots
	var_slots_init(&slots)
	defer var_slots_destroy(&slots)
	computed := make([dynamic]rdf.Term)
	defer {
		for term in computed {
			rdf.destroy_term(term)
		}
		delete(computed)
	}

	ctx: Expr_Context
	// A zero snapshot: these expressions name no variable, so nothing is
	// ever read out of a dataset.
	expr_context_init(&ctx, &slots, {}, &computed)
	defer expr_context_destroy(&ctx)
	expr_context_set_base(&ctx, parser_base(&p))

	value := expr_eval(&ctx, e)
	rendered = render_value(value)
	expr_context_release(&ctx)
	return rendered, true
}

@(private = "file")
render_value :: proc(v: Value) -> string {
	switch v.kind {
	case .Error:
		return strings.clone("error")
	case .Unbound:
		return strings.clone("unbound")
	case .Blank_Node:
		// The label is generated, so only its shape is assertable.
		return strings.clone("blank")
	case .IRI, .Triple, .Simple_String, .Lang_String, .Boolean, .Numeric, .Date_Time, .Date, .Unknown_Literal:
	}
	term, rendered := value_to_term(v)
	if !rendered {
		return strings.clone("unrenderable")
	}
	defer rdf.destroy_term(term)
	b := strings.builder_make()
	switch actual in term {
	case rdf.IRI:
		strings.write_byte(&b, '<')
		strings.write_string(&b, string(actual))
		strings.write_byte(&b, '>')
	case rdf.Blank_Node:
		strings.write_string(&b, "blank")
	case rdf.Literal:
		strings.write_byte(&b, '"')
		strings.write_string(&b, actual.lexical)
		strings.write_byte(&b, '"')
		if actual.language != "" {
			strings.write_byte(&b, '@')
			strings.write_string(&b, actual.language)
		} else if actual.datatype != rdf.XSD_STRING {
			strings.write_string(&b, "^^")
			strings.write_string(&b, string(actual.datatype))
		}
	case ^rdf.Triple:
		strings.write_string(&b, "triple")
	case nil:
		strings.write_string(&b, "nil")
	}
	return strings.to_string(b)
}

@(private = "file")
check :: proc(t: ^testing.T, cases: []Case, loc := #caller_location) {
	for c in cases {
		got, ok := eval_text(t, c.expr, loc)
		if !ok {
			continue
		}
		defer delete(got)
		testing.expectf(t, got == c.want, "%s = %s, want %s", c.expr, got, c.want, loc = loc)
	}
}

XSD_NS :: "http://www.w3.org/2001/XMLSchema#"

@(test)
test_fn_term_accessors :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`STR("chat"@en)`, `"chat"`},
			{`STR("1"^^<` + XSD_NS + `integer>)`, `"1"`},
			// STR reports the lexical form as written, not the canonical
			// one: "01" and "1" are the same integer and different terms.
			{`STR("01"^^<` + XSD_NS + `integer>)`, `"01"`},
			{`STR(<http://example.org/x>)`, `"http://example.org/x"`},
			// A computed number has no lexical form until STR gives it one.
			{`STR(1 + 2)`, `"3"`},
			{`LANG("chat"@en)`, `"en"`},
			{`LANG("chat")`, `""`},
			{`LANG(<http://example.org/x>)`, `error`},
			{`DATATYPE("chat")`, `<` + XSD_NS + `string>`},
			{`DATATYPE("chat"@en)`, `<http://www.w3.org/1999/02/22-rdf-syntax-ns#langString>`},
			{`DATATYPE("1"^^<` + XSD_NS + `byte>)`, `<` + XSD_NS + `byte>`},
			{`isIRI(<http://example.org/x>)`, `"true"^^` + XSD_NS + `boolean`},
			{`isLITERAL("chat")`, `"true"^^` + XSD_NS + `boolean`},
			{`isNUMERIC(1)`, `"true"^^` + XSD_NS + `boolean`},
			{`isNUMERIC("1")`, `"false"^^` + XSD_NS + `boolean`},
			{`sameTerm("1"^^<` + XSD_NS + `integer>, "01"^^<` + XSD_NS + `integer>)`, `"false"^^` + XSD_NS + `boolean`},
			{`langMatches(LANG("chat"@en-GB), "en")`, `"true"^^` + XSD_NS + `boolean`},
			{`langMatches(LANG("chat"@fr), "en")`, `"false"^^` + XSD_NS + `boolean`},
			{`langMatches(LANG("chat"@en), "*")`, `"true"^^` + XSD_NS + `boolean`},
		},
	)
}

// §17.4.1.2 / §17.4.1.3: the two functions that must not evaluate
// everything they are given.
@(test)
test_fn_if_and_coalesce :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`IF(true, 1, 1/0)`, `"1"^^` + XSD_NS + `integer`},
			{`IF(false, 1/0, 2)`, `"2"^^` + XSD_NS + `integer`},
			// The condition's own error is not recoverable.
			{`IF(1/0, 1, 2)`, `error`},
			{`COALESCE(1/0, 2)`, `"2"^^` + XSD_NS + `integer`},
			{`COALESCE(1/0)`, `error`},
			{`COALESCE()`, `error`},
			{`COALESCE(?unbound, "d")`, `"d"`},
		},
	)
}

// §17.4.2.9 / §17.4.2.10. STRDT does not validate the lexical form —
// an ill-typed literal is a term, and only using its value errors.
@(test)
test_fn_constructors :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`STRDT("123", <` + XSD_NS + `integer>)`, `"123"^^` + XSD_NS + `integer`},
			{`STRDT("iiii", <http://example.org/romanNumeral>)`, `"iiii"^^http://example.org/romanNumeral`},
			// The datatype survives as written, not folded into the tower.
			{`STRDT("1", <` + XSD_NS + `byte>)`, `"1"^^` + XSD_NS + `byte`},
			{`STRDT("chat"@en, <` + XSD_NS + `string>)`, `error`},
			{`STRDT(1, <` + XSD_NS + `string>)`, `error`},
			{`STRLANG("chat", "en")`, `"chat"@en`},
			{`STRLANG("chat"@fr, "en")`, `error`},
			{`STRLANG("chat", "")`, `error`},
			// IRI resolves against the query's base.
			{`IRI("thing")`, `<http://example.org/base/thing>`},
			{`IRI("http://other.example/x")`, `<http://other.example/x>`},
			{`IRI(<http://example.org/x>)`, `<http://example.org/x>`},
			{`IRI("chat"@en)`, `error`},
			{`URI("thing")`, `<http://example.org/base/thing>`},
			{`BNODE()`, `blank`},
			{`BNODE("x")`, `blank`},
			{`BNODE(1)`, `error`},
		},
	)
}

// §17.4.3.2 through §17.4.3.12, including every worked example the
// specification prints for STRBEFORE and STRAFTER — the two functions
// whose language-tag rules are least guessable.
@(test)
test_fn_strings :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`STRLEN("chat")`, `"4"^^` + XSD_NS + `integer`},
			{`STRLEN("chat"@en)`, `"4"^^` + XSD_NS + `integer`},
			// Codepoints, not bytes: three characters, nine UTF-8 bytes.
			{`STRLEN("食べ物")`, `"3"^^` + XSD_NS + `integer`},
			{`STRLEN(1)`, `error`},
			{`SUBSTR("foobar", 4)`, `"bar"`},
			{`SUBSTR("foobar"@en, 4)`, `"bar"@en`},
			{`SUBSTR("foobar", 4, 1)`, `"b"`},
			// XPath clips a range that runs past either end.
			{`SUBSTR("foobar", 0, 3)`, `"fo"`},
			{`SUBSTR("foobar", 4, 100)`, `"bar"`},
			{`UCASE("foo")`, `"FOO"`},
			{`UCASE("foo"@en)`, `"FOO"@en`},
			{`LCASE("BAR")`, `"bar"`},
			{`LCASE("BAR"@en)`, `"bar"@en`},
			{`STRSTARTS("foobar", "foo")`, `"true"^^` + XSD_NS + `boolean`},
			{`STRSTARTS("foobar"@en, "foo"@en)`, `"true"^^` + XSD_NS + `boolean`},
			{`STRSTARTS("foobar"^^<` + XSD_NS + `string>, "foo")`, `"true"^^` + XSD_NS + `boolean`},
			// Incompatible arguments are an error, not a false.
			{`STRSTARTS("foobar"@en, "foo"@fr)`, `error`},
			{`STRSTARTS("foobar", "foo"@en)`, `error`},
			{`STRENDS("foobar", "bar")`, `"true"^^` + XSD_NS + `boolean`},
			{`CONTAINS("foobar", "bar")`, `"true"^^` + XSD_NS + `boolean`},
			{`CONTAINS("foobar", "zzz")`, `"false"^^` + XSD_NS + `boolean`},

			// §17.4.3.9's table, entry for entry.
			{`STRBEFORE("abc", "b")`, `"a"`},
			{`STRBEFORE("abc"@en, "bc")`, `"a"@en`},
			{`STRBEFORE("abc"@en, "b"@cy)`, `error`},
			{`STRBEFORE("abc"^^<` + XSD_NS + `string>, "")`, `""`},
			{`STRBEFORE("abc", "xyz")`, `""`},
			{`STRBEFORE("abc"@en, "z"@en)`, `""`},
			{`STRBEFORE("abc"@en, "z")`, `""`},
			{`STRBEFORE("abc"@en, ""@en)`, `""@en`},
			{`STRBEFORE("abc"@en, "")`, `""@en`},

			// §17.4.3.10's table.
			{`STRAFTER("abc", "b")`, `"c"`},
			{`STRAFTER("abc"@en, "ab")`, `"c"@en`},
			{`STRAFTER("abc"@en, "b"@cy)`, `error`},
			{`STRAFTER("abc"^^<` + XSD_NS + `string>, "")`, `"abc"`},
			{`STRAFTER("abc", "xyz")`, `""`},
			{`STRAFTER("abc"@en, "z"@en)`, `""`},
			{`STRAFTER("abc"@en, "z")`, `""`},
			{`STRAFTER("abc"@en, ""@en)`, `"abc"@en`},
			{`STRAFTER("abc"@en, "")`, `"abc"@en`},

			{`ENCODE_FOR_URI("Los Angeles")`, `"Los%20Angeles"`},
			// The result is text in no language, whatever went in.
			{`ENCODE_FOR_URI("Los Angeles"@en)`, `"Los%20Angeles"`},
			{`ENCODE_FOR_URI("100%")`, `"100%25"`},

			{`CONCAT("foo", "bar")`, `"foobar"`},
			{`CONCAT("foo"@en, "bar"@en)`, `"foobar"@en`},
			// One shared tag or none at all.
			{`CONCAT("foo"@en, "bar")`, `"foobar"`},
			{`CONCAT("foo"@en, "bar"@fr)`, `"foobar"`},
			{`CONCAT("foo"^^<` + XSD_NS + `string>, "bar"^^<` + XSD_NS + `string>)`, `"foobar"`},
			{`CONCAT()`, `""`},
			{`CONCAT("foo", 1)`, `error`},
		},
	)
}

// §17.4.3.14 and §17.4.3.15's worked examples. The flavour itself is
// tested in regex_test.odin; these check the SPARQL-level wrapping —
// argument types, flags, and the result's language tag.
@(test)
test_fn_regex_and_replace :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`REGEX("Alice", "^ali", "i")`, `"true"^^` + XSD_NS + `boolean`},
			{`REGEX("Alice", "^bob")`, `"false"^^` + XSD_NS + `boolean`},
			{`REGEX("Alice"@en, "^ali", "i")`, `"true"^^` + XSD_NS + `boolean`},
			{`REGEX(1, "1")`, `error`},
			// An invalid pattern raises rather than failing to match.
			{`REGEX("Alice", "(")`, `error`},
			{`REGEX("Alice", "a", "z")`, `error`},
			{`REPLACE("abcd", "b", "Z")`, `"aZcd"`},
			{`REPLACE("abab", "B", "Z", "i")`, `"aZaZ"`},
			{`REPLACE("abab", "B.", "Z", "i")`, `"aZb"`},
			// The subject's language survives the rewrite.
			{`REPLACE("abcd"@en, "b", "Z")`, `"aZcd"@en`},
			{`REPLACE("abcd", "(b)(c)", "[$2$1]")`, `"a[cb]d"`},
		},
	)
}

// §17.4.4. Each answers in its argument's type, and ROUND's ties go
// towards positive infinity — round(-2.5) is -2, not -3.
@(test)
test_fn_numerics :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`ABS(1)`, `"1"^^` + XSD_NS + `integer`},
			{`ABS(-1.5)`, `"1.5"^^` + XSD_NS + `decimal`},
			{`ABS(-2)`, `"2"^^` + XSD_NS + `integer`},
			{`ROUND(2.4999)`, `"2.0"^^` + XSD_NS + `decimal`},
			{`ROUND(2.5)`, `"3.0"^^` + XSD_NS + `decimal`},
			{`ROUND(-2.5)`, `"-2.0"^^` + XSD_NS + `decimal`},
			{`CEIL(10.5)`, `"11.0"^^` + XSD_NS + `decimal`},
			{`CEIL(-10.5)`, `"-10.0"^^` + XSD_NS + `decimal`},
			{`FLOOR(10.5)`, `"10.0"^^` + XSD_NS + `decimal`},
			{`FLOOR(-10.5)`, `"-11.0"^^` + XSD_NS + `decimal`},
			{`FLOOR(3)`, `"3"^^` + XSD_NS + `integer`},
			{`ABS("x")`, `error`},
		},
	)
}

// §17.4.5's accessors, over the specification's own example dateTime.
// The fields are the lexical form's, not UTC's: the hour is 14 even
// though the instant is 19:45Z.
@(test)
test_fn_datetime :: proc(t: ^testing.T) {
	D :: `"2011-01-10T14:45:13.815-05:00"^^<` + XSD_NS + `dateTime>`
	check(
		t,
		{
			{`YEAR(` + D + `)`, `"2011"^^` + XSD_NS + `integer`},
			{`MONTH(` + D + `)`, `"1"^^` + XSD_NS + `integer`},
			{`DAY(` + D + `)`, `"10"^^` + XSD_NS + `integer`},
			{`HOURS(` + D + `)`, `"14"^^` + XSD_NS + `integer`},
			{`MINUTES(` + D + `)`, `"45"^^` + XSD_NS + `integer`},
			{`SECONDS(` + D + `)`, `"13.815"^^` + XSD_NS + `decimal`},
			{`TIMEZONE(` + D + `)`, `"-PT5H"^^` + XSD_NS + `dayTimeDuration`},
			{`TZ(` + D + `)`, `"-05:00"`},
			{`TZ("2011-01-10T14:45:13Z"^^<` + XSD_NS + `dateTime>)`, `"Z"`},
			{`TIMEZONE("2011-01-10T14:45:13Z"^^<` + XSD_NS + `dateTime>)`, `"PT0S"^^` + XSD_NS + `dayTimeDuration`},
			// No timezone: TZ says so, TIMEZONE has no duration to name.
			{`TZ("2011-01-10T14:45:13"^^<` + XSD_NS + `dateTime>)`, `""`},
			{`TIMEZONE("2011-01-10T14:45:13"^^<` + XSD_NS + `dateTime>)`, `error`},
			{`YEAR("chat")`, `error`},
		},
	)
}

// §17.4.6, over the specification's "abc" examples.
@(test)
test_fn_hashes :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`MD5("abc")`, `"900150983cd24fb0d6963f7d28e17f72"`},
			{`SHA1("abc")`, `"a9993e364706816aba3e25717850c26c9cd0d89d"`},
			{`SHA256("abc")`, `"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`},
			{
				`SHA384("abc")`,
				`"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"`,
			},
			{
				`SHA512("abc")`,
				`"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"`,
			},
			{`MD5(1)`, `error`},
		},
	)
}

// §17.5's cast table. The interesting rows are the ones that must
// *fail*: a lexical form is castable to a type exactly when it is in
// that type's lexical space, which is the same test that decides
// whether a stored literal is ill-typed.
@(test)
test_fn_casts :: proc(t: ^testing.T) {
	check(
		t,
		{
			{`<` + XSD_NS + `integer>("13")`, `"13"^^` + XSD_NS + `integer`},
			{`<` + XSD_NS + `integer>("1.5")`, `error`},
			{`<` + XSD_NS + `integer>("0E1")`, `error`},
			{`<` + XSD_NS + `integer>(1.5)`, `"1"^^` + XSD_NS + `integer`},
			// Truncation towards zero, not flooring.
			{`<` + XSD_NS + `integer>(-1.5)`, `"-1"^^` + XSD_NS + `integer`},
			{`<` + XSD_NS + `integer>(true)`, `"1"^^` + XSD_NS + `integer`},
			{`<` + XSD_NS + `integer>(false)`, `"0"^^` + XSD_NS + `integer`},
			{`<` + XSD_NS + `decimal>("+33.3300")`, `"+33.3300"^^` + XSD_NS + `decimal`},
			{`<` + XSD_NS + `decimal>("-10.2E3")`, `error`},
			{`<` + XSD_NS + `double>("-10.2E3")`, `"-10.2E3"^^` + XSD_NS + `double`},
			{`<` + XSD_NS + `boolean>("true")`, `"true"^^` + XSD_NS + `boolean`},
			{`<` + XSD_NS + `boolean>("1")`, `"1"^^` + XSD_NS + `boolean`},
			{`<` + XSD_NS + `boolean>("yes")`, `error`},
			{`<` + XSD_NS + `boolean>(0)`, `"false"^^` + XSD_NS + `boolean`},
			{`<` + XSD_NS + `boolean>(3)`, `"true"^^` + XSD_NS + `boolean`},
			{`<` + XSD_NS + `string>(1)`, `"1"`},
			{`<` + XSD_NS + `string>(1.5)`, `"1.5"`},
			{`<` + XSD_NS + `string>(true)`, `"true"`},
			// An IRI is the one non-literal §17.5 admits as a cast source.
			{`<` + XSD_NS + `string>(<http://example.org/x>)`, `"http://example.org/x"`},
			{`<` + XSD_NS + `dateTime>("2002-10-10T17:00:00Z")`, `"2002-10-10T17:00:00Z"^^` + XSD_NS + `dateTime`},
			{`<` + XSD_NS + `dateTime>("not a date")`, `error`},
			{`<` + XSD_NS + `integer>("chat"@en)`, `error`},
		},
	)
}

// NOW is one instant for the whole query (§17.4.5.1), so two calls
// cannot disagree — the property that makes a query's answer a snapshot
// rather than a smear.
@(test)
test_fn_now_is_fixed :: proc(t: ^testing.T) {
	first, first_ok := eval_text(t, `NOW()`)
	defer delete(first)
	second, second_ok := eval_text(t, `NOW()`)
	defer delete(second)
	testing.expect(t, first_ok && second_ok)
	testing.expectf(t, strings.has_suffix(first, XSD_NS + "dateTime"), "NOW() is not an xsd:dateTime: %s", first)

	same, same_ok := eval_text(t, `NOW() = NOW()`)
	defer delete(same)
	testing.expect(t, same_ok)
	testing.expectf(t, same == `"true"^^` + XSD_NS + `boolean`, "NOW() drifted within one query: %s", same)
}

// RAND's only stated contract is the half-open range it lands in, and
// that it is an xsd:double.
@(test)
test_fn_rand_range :: proc(t: ^testing.T) {
	for _ in 0 ..< 32 {
		got, ok := eval_text(t, `RAND() >= 0.0 && RAND() < 1.0 && DATATYPE(RAND()) = <` + XSD_NS + `double>`)
		defer delete(got)
		testing.expect(t, ok)
		testing.expectf(t, got == `"true"^^` + XSD_NS + `boolean`, "RAND() out of contract: %s", got)
	}
}

// UUID and STRUUID: shape, not value — the suites deliberately assert
// only the form, because the value is by definition unpredictable.
@(test)
test_fn_uuid_shape :: proc(t: ^testing.T) {
	// Version 4, variant 1: the '4' and the [89AB] are the bits the
	// generator is required to set.
	BODY :: `[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}`
	P :: `"^` + BODY + `$"`
	check(
		t,
		{
			{`REGEX(STRUUID(), ` + P + `, "i")`, `"true"^^` + XSD_NS + `boolean`},
			{`isIRI(UUID())`, `"true"^^` + XSD_NS + `boolean`},
			{`REGEX(STR(UUID()), "^urn:uuid:` + BODY + `$", "i")`, `"true"^^` + XSD_NS + `boolean`},
			// Two calls must not collide.
			{`UUID() != UUID()`, `"true"^^` + XSD_NS + `boolean`},
			{`STRLEN(STRUUID())`, `"36"^^` + XSD_NS + `integer`},
		},
	)
}

// The SPARQL 1.2 triple-term accessors, which the grammar already
// parses. Their evaluation over stored triple terms arrives with
// SPARQL-T-0018; what is checked here is the function contract.
@(test)
test_fn_triple_terms :: proc(t: ^testing.T) {
	TT :: `TRIPLE(<http://example.org/s>, <http://example.org/p>, "o")`
	check(
		t,
		{
			{`isTRIPLE(` + TT + `)`, `"true"^^` + XSD_NS + `boolean`},
			{`isTRIPLE("x")`, `"false"^^` + XSD_NS + `boolean`},
			{`SUBJECT(` + TT + `)`, `<http://example.org/s>`},
			{`PREDICATE(` + TT + `)`, `<http://example.org/p>`},
			{`OBJECT(` + TT + `)`, `"o"`},
			{`SUBJECT("x")`, `error`},
			// A literal cannot be a subject and a literal predicate is not
			// a predicate.
			{`TRIPLE("s", <http://example.org/p>, "o")`, `error`},
			{`TRIPLE(<http://example.org/s>, "p", "o")`, `error`},
		},
	)
}

// Every function the grammar parses is either implemented or named as
// unimplemented — never silently absent. A built-in missing from
// builtin_implemented would evaluate to a type error at runtime, which
// reads as "your filter matched nothing".
@(test)
test_fn_coverage_is_declared :: proc(t: ^testing.T) {
	PENDING :: [?]Keyword{.Lang_Dir, .Str_Lang_Dir, .Has_Lang, .Has_Lang_Dir}
	for kw in Keyword {
		_, _, is_builtin := builtin_arity(kw)
		if !is_builtin {
			continue
		}
		pending := false
		for p in PENDING {
			if p == kw {
				pending = true
			}
		}
		testing.expectf(
			t,
			builtin_implemented(kw) != pending,
			"%v is parsed as a built-in but %s",
			kw,
			pending ? "is listed as pending and also implemented" : "has no implementation",
		)
	}
}
