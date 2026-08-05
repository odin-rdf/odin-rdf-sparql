package sparql

import "core:testing"

// scan_all drains the scanner into the caller's buffer and returns the
// slice filled; buf is sized by the test.
@(private = "file")
scan_all :: proc(s: ^Scanner, source: string, buf: []Token) -> []Token {
	scanner_init(s, transmute([]byte)source)
	n := 0
	for {
		tok, ok := scanner_next(s)
		if !ok {
			break
		}
		buf[n] = tok
		n += 1
	}
	return buf[:n]
}

@(private = "file")
expect_kinds :: proc(t: ^testing.T, toks: []Token, kinds: []Token_Kind, loc := #caller_location) {
	testing.expectf(t, len(toks) == len(kinds), "got %d tokens, expected %d", len(toks), len(kinds), loc = loc)
	if len(toks) != len(kinds) {
		return
	}
	for k, i in kinds {
		testing.expectf(t, toks[i].kind == k, "token %d: got %v, expected %v", i, toks[i].kind, k, loc = loc)
	}
}

@(test)
test_keywords_case_insensitive :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token
	toks := scan_all(&s, "select SELECT SeLeCt where WHERE", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Keyword, .Keyword, .Keyword, .Keyword, .Keyword})
	for tok, i in toks {
		expected := Keyword.Select if i < 3 else Keyword.Where
		testing.expect_value(t, tok.keyword, expected)
	}
}

@(test)
test_keyword_a_case_sensitive :: proc(t: ^testing.T) {
	s: Scanner
	buf: [4]Token
	toks := scan_all(&s, "a", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.A})

	// Uppercase 'A' is not the rdf:type keyword and is no other keyword
	// either.
	toks = scan_all(&s, "A", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Unknown_Keyword)
	testing.expect_value(t, len(toks), 0)
}

@(test)
test_keyword_escape_rejected :: proc(t: ^testing.T) {
	// SPARQL 1.2 confines codepoint escapes to strings and IRIs; an
	// escaped keyword is a syntax error (sparql12 codepoint-esc-01-bad),
	// revising SPARQL 1.1's anywhere-rule.
	s: Scanner
	buf: [4]Token
	toks := scan_all(&s, `\u0053ELECT`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Unexpected_Character)
	testing.expect_value(t, len(toks), 0)

	// And in prefixed-name locals, only PN_LOCAL_ESC remains legal
	// (codepoint-esc-03-bad).
	scan_all(&s, `ns:a\u0062c`, buf[:])
	testing.expect(t, s.err.kind != .None)
}

@(test)
test_booleans :: proc(t: ^testing.T) {
	s: Scanner
	buf: [4]Token
	toks := scan_all(&s, "true FALSE True", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Boolean, .Boolean, .Boolean})
	if len(toks) == 3 {
		testing.expect_value(t, toks[0].text, "true")
		testing.expect_value(t, toks[1].text, "FALSE")
	}
}

@(test)
test_positions :: proc(t: ^testing.T) {
	s: Scanner
	buf: [16]Token
	toks := scan_all(&s, "SELECT ?x\nWHERE {\n\t?x a ?y\n}", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Keyword, .Var, .Keyword, .L_Brace, .Var, .A, .Var, .R_Brace})
	if len(toks) == 8 {
		testing.expect_value(t, toks[0].line, 1)
		testing.expect_value(t, toks[0].column, 1)
		testing.expect_value(t, toks[1].line, 1)
		testing.expect_value(t, toks[1].column, 8)
		testing.expect_value(t, toks[2].line, 2)
		testing.expect_value(t, toks[2].column, 1)
		testing.expect_value(t, toks[4].line, 3)
		testing.expect_value(t, toks[4].column, 2) // after the tab
		testing.expect_value(t, toks[7].line, 4)
		testing.expect_value(t, toks[7].column, 1)
	}
}

@(test)
test_error_positions :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	// '&' alone is no token; error on line 2 at the exact column.
	scan_all(&s, "SELECT ?x\n  & ?y", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Unexpected_Character)
	testing.expect_value(t, s.err.line, 2)
	testing.expect_value(t, s.err.column, 3)

	// Raw newline inside a single-quoted string.
	scan_all(&s, "\"abc\ndef\"", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_String_Character)
	testing.expect_value(t, s.err.line, 1)
	testing.expect_value(t, s.err.column, 5)

	// '$' without a variable name.
	scan_all(&s, "$ ", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Variable_Name)
	testing.expect_value(t, s.err.column, 1)
}

@(test)
test_strings_and_escapes :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	toks := scan_all(&s, `"plain" 'single' "e\tsc\"aped"`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.String_Literal, .String_Literal, .String_Literal})
	if len(toks) == 3 {
		testing.expect_value(t, toks[0].text, "plain")
		testing.expect_value(t, toks[1].text, "single")
		testing.expect_value(t, toks[2].text, `e\tsc\"aped`)
		testing.expect(t, !toks[0].has_escape)
		testing.expect(t, toks[2].has_escape)
	}

	// Codepoint escape in a string (syn-codepoint-escape-01 shape).
	toks = scan_all(&s, `"\U0001f46a"`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.String_Literal})

	// A surrogate is not a character (syn-invalid-codepoint-escaped-bad-01).
	scan_all(&s, `'\uD800'`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Escape)

	// Unknown ECHAR.
	scan_all(&s, `"\x"`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Escape)
}

@(test)
test_long_strings :: proc(t: ^testing.T) {
	s: Scanner
	buf: [4]Token
	toks := scan_all(&s, "'''a 'b' ''c'''", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.String_Literal})
	if len(toks) == 1 {
		testing.expect_value(t, toks[0].text, "a 'b' ''c")
		testing.expect(t, toks[0].long_string)
	}

	// Line tracking across an embedded newline.
	toks = scan_all(&s, "\"\"\"a\nb\"\"\" ?x", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.String_Literal, .Var})
	if len(toks) == 2 {
		testing.expect_value(t, toks[1].line, 2)
	}
}

@(test)
test_pnames :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	toks := scan_all(&s, "foaf:name :x ex:a.b ex:a. og:audio%3Atitle", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.PName, .PName, .PName, .PName, .Dot, .PName})
	if len(toks) == 6 {
		testing.expect_value(t, toks[0].text, "foaf:name")
		testing.expect_value(t, toks[1].text, ":x")
		testing.expect_value(t, toks[2].text, "ex:a.b") // interior dot is content
		testing.expect_value(t, toks[3].text, "ex:a") // trailing dot is not
		testing.expect_value(t, toks[5].text, "og:audio%3Atitle")
	}

	// PN_LOCAL_ESC.
	toks = scan_all(&s, `ex:n\~ame`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.PName})
	if len(toks) == 1 {
		testing.expect(t, toks[0].has_escape)
	}

	// Bad percent encoding.
	scan_all(&s, "ex:a%2 ", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Percent_Encoding)
}

@(test)
test_unicode_boundaries :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	// é (U+00E9) is PN_CHARS_BASE; both prefix and local accept it.
	toks := scan_all(&s, "é:è ?vé _:bé", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.PName, .Var, .Blank_Node_Label})
	if len(toks) == 3 {
		testing.expect_value(t, toks[0].text, "é:è")
		testing.expect_value(t, toks[1].text, "vé")
		testing.expect_value(t, toks[2].text, "bé")
	}

	// U+2040 is a VARNAME/PN_CHARS continuation but no starter.
	toks = scan_all(&s, "?x⁀", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Var})
}

@(test)
test_numbers :: proc(t: ^testing.T) {
	s: Scanner
	buf: [16]Token

	toks := scan_all(&s, "1 12.5 .5 1e0 1.e0 .5E-3 +1 -2.5", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Integer, .Decimal, .Decimal, .Double, .Double, .Double, .Integer, .Decimal})
	if len(toks) == 8 {
		testing.expect_value(t, toks[6].text, "+1")
		testing.expect_value(t, toks[7].text, "-2.5")
	}

	// SPARQL DECIMAL needs digits after the dot: "1." is INTEGER Dot.
	toks = scan_all(&s, "1.", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Integer, .Dot})
}

@(test)
test_nil_and_anon :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	toks := scan_all(&s, "( ) (?x) [ \n ] [?y]", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Nil, .L_Paren, .Var, .R_Paren, .Anon, .L_Bracket, .Var, .R_Bracket})
	// The ANON swallowed a newline; the following '[' is on line 2.
	if len(toks) == 8 {
		testing.expect_value(t, toks[5].line, 2)
	}
}

@(test)
test_operators_and_paths :: proc(t: ^testing.T) {
	s: Scanner
	buf: [24]Token

	toks := scan_all(&s, "?x = ?y || !?z && ?a != ?b", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Var, .Eq, .Var, .Or, .Bang, .Var, .And, .Var, .Ne, .Var})

	// Path operators: ^, /, |, and the zero-or-one '?' after an element.
	toks = scan_all(&s, "^foaf:knows/foaf:name|foaf:nick? *", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Caret, .PName, .Slash, .PName, .Pipe, .PName, .Question, .Star})

	// Comparison vs IRI: maximal munch backtracks '<' to an operator when
	// no IRIREF can match.
	toks = scan_all(&s, "?x < ?y <= <http://e/p>", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Var, .Lt, .Var, .Le, .IRI_Ref})
	if len(toks) == 5 {
		testing.expect_value(t, toks[4].text, "http://e/p")
	}

	toks = scan_all(&s, "?x > ?y >= 2", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Var, .Gt, .Var, .Ge, .Integer})
}

@(test)
test_triple_terms :: proc(t: ^testing.T) {
	s: Scanner
	buf: [16]Token

	toks := scan_all(&s, "<< ?s ?p ?o >> <<( <u:s> <u:p> 1 )>>", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(
		t,
		toks,
		{
			.Reified_Open,
			.Var,
			.Var,
			.Var,
			.Reified_Close,
			.Triple_Term_Open,
			.IRI_Ref,
			.IRI_Ref,
			.Integer,
			.Triple_Term_Close,
		},
	)
}

@(test)
test_lang_tags :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	toks := scan_all(&s, `"a"@en "b"@en-US "c"@en--ltr`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.String_Literal, .Lang_Tag, .String_Literal, .Lang_Tag, .String_Literal, .Lang_Tag})
	if len(toks) == 6 {
		testing.expect_value(t, toks[1].text, "en")
		testing.expect_value(t, toks[3].text, "en-US")
		testing.expect_value(t, toks[5].text, "en--ltr")
	}

	scan_all(&s, `"x"@`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Lang_Tag)
}

@(test)
test_codepoint_escape_no_reprocessing :: proc(t: ^testing.T) {
	// syn-codepoint-escape-bad-04 (after its \ produced a literal
	// backslash): \U00000031 is a well-formed escape producing '1',
	// which starts no token — and is never re-interpreted.
	s: Scanner
	buf: [8]Token
	scan_all(&s, `?s ?p \U00000031 .`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Unexpected_Character)

	// bad-05: \U0000005c produces '\'; the following "u0031" must NOT
	// be treated as a second escape round.
	scan_all(&s, `?s ?p \U0000005cu0031 .`, buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Unexpected_Character)
}

@(test)
test_blank_nodes :: proc(t: ^testing.T) {
	s: Scanner
	buf: [8]Token

	toks := scan_all(&s, "_:b0 _:a.b _:a.", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.None)
	expect_kinds(t, toks, {.Blank_Node_Label, .Blank_Node_Label, .Blank_Node_Label, .Dot})
	if len(toks) == 4 {
		testing.expect_value(t, toks[1].text, "a.b")
		testing.expect_value(t, toks[2].text, "a")
	}

	scan_all(&s, "_x", buf[:])
	testing.expect_value(t, s.err.kind, Error_Kind.Invalid_Blank_Node_Label)
}
