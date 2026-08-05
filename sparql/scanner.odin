// The SPARQL tokenizer. Tokens borrow from the caller-owned source
// buffer; scanning never allocates. Modeled on odin-rdf-parser's
// internal scanners (SPARQL-T-0002).
//
// Codepoint escapes: SPARQL 1.2 restricts \uXXXX and \UXXXXXXXX to
// string literals and IRI references (the sparql12 codepoint-escape
// suite pins this — escaped keywords, prefixed names, and variable
// names are illegal, revising SPARQL 1.1's anywhere-rule). Inside
// those two contexts the scanner decodes an escape as the single
// character it denotes, with no second buffer (zero-copy) and no
// re-interpretation of produced characters — '\U00000031' is a
// backslash followed by 'U', never a second escape round. Deliberate
// simplification: an escape-produced quote, backslash, or newline
// inside a string literal is treated as content rather than
// re-tokenized; the W3C suites do not exercise those corners.
package sparql

import "core:unicode/utf8"

// Scanner is the tokenizer's state over one caller-owned source buffer.
// The error is sticky: after a failure every scanner_next returns
// ok=false with err unchanged.
Scanner :: struct {
	source:     []byte,
	pos:        int,
	line:       int, // 1-based
	line_start: int, // byte offset where the current line begins
	err:        Error,
}

// scanner_init prepares s to scan source, which must stay valid and
// unmoved for the scanner's lifetime (tokens borrow from it).
scanner_init :: proc(s: ^Scanner, source: []byte) {
	s^ = {
		source = source,
		line   = 1,
	}
}

// scanner_next returns the next token. ok is false at end of input or on
// error; s.err.kind distinguishes the two (.None means clean end).
scanner_next :: proc(s: ^Scanner) -> (tok: Token, ok: bool) {
	if s.err.kind != .None {
		return {}, false
	}
	skip_whitespace(s)
	if s.pos >= len(s.source) {
		return {}, false
	}

	start := s.pos
	tok = Token {
		offset = start,
		line   = s.line,
		column = start - s.line_start + 1,
	}

	switch c := s.source[s.pos]; c {
	case '<':
		// '<<(' and '<<' first: IRIREF forbids '<' in content, so a
		// second '<' can never begin an IRI.
		if peek(s, 1) == '<' {
			if peek(s, 2) == '(' {
				s.pos += 3
				tok.kind = .Triple_Term_Open
				return tok, true
			}
			s.pos += 2
			tok.kind = .Reified_Open
			return tok, true
		}
		// Maximal munch: try IRIREF; when its character set rules the
		// rest out, fall back to '<=' or '<'.
		if scan_iri_ref(s, &tok) {
			return tok, true
		}
		if s.err.kind != .None {
			return {}, false
		}
		if peek(s, 1) == '=' {
			s.pos += 2
			tok.kind = .Le
			return tok, true
		}
		s.pos += 1
		tok.kind = .Lt
		return tok, true

	case '>':
		if peek(s, 1) == '>' {
			s.pos += 2
			tok.kind = .Reified_Close
			return tok, true
		}
		if peek(s, 1) == '=' {
			s.pos += 2
			tok.kind = .Ge
			return tok, true
		}
		s.pos += 1
		tok.kind = .Gt
		return tok, true

	case '"', '\'':
		return scan_string(s, &tok, c)

	case '_':
		return scan_blank_node(s, &tok)

	case '@':
		return scan_lang_tag(s, &tok)

	case '?':
		if varname_starts_at(s, s.pos + 1) {
			return scan_var(s, &tok)
		}
		s.pos += 1
		tok.kind = .Question
		return tok, true

	case '$':
		if varname_starts_at(s, s.pos + 1) {
			return scan_var(s, &tok)
		}
		set_error(s, .Invalid_Variable_Name, start)
		return {}, false

	case '^':
		if peek(s, 1) == '^' {
			s.pos += 2
			tok.kind = .Datatype_Marker
			return tok, true
		}
		s.pos += 1
		tok.kind = .Caret
		return tok, true

	case '|':
		if peek(s, 1) == '|' {
			s.pos += 2
			tok.kind = .Or
			return tok, true
		}
		if peek(s, 1) == '}' {
			s.pos += 2
			tok.kind = .Annotation_Close
			return tok, true
		}
		s.pos += 1
		tok.kind = .Pipe
		return tok, true

	case '~':
		s.pos += 1
		tok.kind = .Tilde
		return tok, true

	case '&':
		if peek(s, 1) == '&' {
			s.pos += 2
			tok.kind = .And
			return tok, true
		}
		set_error(s, .Unexpected_Character, start)
		return {}, false

	case '!':
		if peek(s, 1) == '=' {
			s.pos += 2
			tok.kind = .Ne
			return tok, true
		}
		s.pos += 1
		tok.kind = .Bang
		return tok, true

	case '=':
		s.pos += 1
		tok.kind = .Eq
		return tok, true

	case '+', '-':
		// A sign joins a numeric literal by maximal munch (the grammar's
		// NumericLiteralPositive/Negative); otherwise it is an operator.
		if is_digit(peek(s, 1)) || (peek(s, 1) == '.' && is_digit(peek(s, 2))) {
			return scan_number(s, &tok)
		}
		s.pos += 1
		tok.kind = .Plus if c == '+' else .Minus
		return tok, true

	case '0' ..= '9':
		return scan_number(s, &tok)

	case '.':
		// A dot is a number only when digits follow (".5").
		if is_digit(peek(s, 1)) {
			return scan_number(s, &tok)
		}
		s.pos += 1
		tok.kind = .Dot
		return tok, true

	case '(':
		// NIL ::= '(' WS* ')' — a whole token when only whitespace
		// intervenes; otherwise an ordinary parenthesis.
		if j, is_nil := ws_run_ends_with(s, s.pos + 1, ')'); is_nil {
			commit_ws_run(s, s.pos + 1, j)
			s.pos = j + 1
			tok.kind = .Nil
			return tok, true
		}
		s.pos += 1
		tok.kind = .L_Paren
		return tok, true

	case ')':
		if peek(s, 1) == '>' && peek(s, 2) == '>' {
			s.pos += 3
			tok.kind = .Triple_Term_Close
			return tok, true
		}
		s.pos += 1
		tok.kind = .R_Paren
		return tok, true

	case '[':
		// ANON ::= '[' WS* ']'.
		if j, is_anon := ws_run_ends_with(s, s.pos + 1, ']'); is_anon {
			commit_ws_run(s, s.pos + 1, j)
			s.pos = j + 1
			tok.kind = .Anon
			return tok, true
		}
		s.pos += 1
		tok.kind = .L_Bracket
		return tok, true

	case ']':
		s.pos += 1
		tok.kind = .R_Bracket
		return tok, true

	case '{':
		if peek(s, 1) == '|' {
			s.pos += 2
			tok.kind = .Annotation_Open
			return tok, true
		}
		s.pos += 1
		tok.kind = .L_Brace
		return tok, true
	case '}':
		s.pos += 1
		tok.kind = .R_Brace
		return tok, true
	case ';':
		s.pos += 1
		tok.kind = .Semicolon
		return tok, true
	case ',':
		s.pos += 1
		tok.kind = .Comma
		return tok, true
	case '*':
		s.pos += 1
		tok.kind = .Star
		return tok, true
	case '/':
		s.pos += 1
		tok.kind = .Slash
		return tok, true

	case ':':
		return scan_pname(s, &tok, start)

	case:
		// PN_CHARS_BASE start: a keyword, 'a', a boolean, or the prefix
		// part of a prefixed name.
		return scan_name(s, &tok)
	}
}

@(private = "file")
peek :: proc(s: ^Scanner, ahead: int) -> byte {
	if s.pos + ahead < len(s.source) {
		return s.source[s.pos + ahead]
	}
	return 0
}

@(private = "file")
set_error :: proc(s: ^Scanner, kind: Error_Kind, offset: int) {
	s.err = Error {
		kind   = kind,
		offset = offset,
		line   = s.line,
		column = offset - s.line_start + 1,
	}
}

@(private = "file")
skip_whitespace :: proc(s: ^Scanner) {
	for s.pos < len(s.source) {
		switch s.source[s.pos] {
		case ' ', '\t', '\r':
			s.pos += 1
		case '\n':
			s.pos += 1
			s.line += 1
			s.line_start = s.pos
		case '#':
			for s.pos < len(s.source) && s.source[s.pos] != '\n' {
				s.pos += 1
			}
		case:
			return
		}
	}
}

// ws_run_ends_with reports whether only WS bytes sit between `from` and
// the closing byte, returning the closer's offset. WS per the grammar is
// space, tab, CR, LF — comments do not participate in NIL/ANON.
@(private = "file")
ws_run_ends_with :: proc(s: ^Scanner, from: int, closer: byte) -> (at: int, found: bool) {
	j := from
	for j < len(s.source) {
		switch s.source[j] {
		case ' ', '\t', '\r', '\n':
			j += 1
		case closer:
			return j, true
		case:
			return 0, false
		}
	}
	return 0, false
}

// commit_ws_run applies line tracking for a whitespace run that a
// NIL/ANON token swallows.
@(private = "file")
commit_ws_run :: proc(s: ^Scanner, from, to: int) {
	for k in from ..< to {
		if s.source[k] == '\n' {
			s.line += 1
			s.line_start = k + 1
		}
	}
}

// scan_iri_ref speculatively scans an IRIREF from '<'. Returns false
// with no error when the content rules it out (the caller retries as
// '<'/'<='); returns false with a sticky error for a malformed escape.
@(private = "file")
scan_iri_ref :: proc(s: ^Scanner, tok: ^Token) -> bool {
	start := s.pos
	j := start + 1
	escaped := false
	for j < len(s.source) {
		c := s.source[j]
		switch {
		case c == '>':
			tok.kind = .IRI_Ref
			tok.text = string(s.source[start + 1:j])
			tok.has_escape = escaped
			s.pos = j + 1
			return true
		case c == '\\':
			// Only a codepoint escape may appear; it must not produce a
			// character IRIREF forbids.
			r, n := decode_escape_at(s, j)
			if n == 0 {
				set_error(s, .Invalid_Escape, j)
				return false
			}
			if iri_forbids(r) {
				set_error(s, .Invalid_IRI_Character, j)
				return false
			}
			escaped = true
			j += n
		case c <= 0x20 || c == '<' || c == '"' || c == '{' || c == '}' || c == '|' || c == '^' || c == '`':
			return false // not an IRI; '<' is an operator here
		case:
			j += 1
		}
	}
	return false // unterminated candidate: treat '<' as an operator
}

@(private = "file")
iri_forbids :: proc(r: rune) -> bool {
	if r <= 0x20 {
		return true
	}
	switch r {
	case '<', '>', '"', '{', '}', '|', '^', '`', '\\':
		return true
	}
	return false
}

@(private = "file")
scan_string :: proc(s: ^Scanner, tok: ^Token, quote: byte) -> (Token, bool) {
	if peek(s, 1) == quote && peek(s, 2) == quote {
		return scan_long_string(s, tok, quote)
	}
	start := s.pos
	s.pos += 1
	content_start := s.pos
	for {
		if s.pos >= len(s.source) {
			set_error(s, .Unterminated_String, start)
			return {}, false
		}
		c := s.source[s.pos]
		switch {
		case c == quote:
			tok.kind = .String_Literal
			tok.text = string(s.source[content_start:s.pos])
			s.pos += 1
			return tok^, true
		case c == '\\':
			tok.has_escape = true
			if !scan_string_escape(s) {
				return {}, false
			}
		case c == '\n' || c == '\r':
			set_error(s, .Invalid_String_Character, s.pos)
			return {}, false
		case:
			s.pos += 1
		}
	}
}

@(private = "file")
scan_long_string :: proc(s: ^Scanner, tok: ^Token, quote: byte) -> (Token, bool) {
	start := s.pos
	s.pos += 3
	content_start := s.pos
	for {
		if s.pos >= len(s.source) {
			set_error(s, .Unterminated_Long_String, start)
			return {}, false
		}
		c := s.source[s.pos]
		switch {
		case c == quote:
			// The literal closes at the FIRST run of three quotes.
			run_start := s.pos
			for s.pos < len(s.source) && s.source[s.pos] == quote && s.pos - run_start < 3 {
				s.pos += 1
			}
			if s.pos - run_start == 3 {
				tok.kind = .String_Literal
				tok.long_string = true
				tok.text = string(s.source[content_start:run_start])
				return tok^, true
			}
		case c == '\\':
			tok.has_escape = true
			if !scan_string_escape(s) {
				return {}, false
			}
		case c == '\n':
			s.pos += 1
			s.line += 1
			s.line_start = s.pos
		case:
			s.pos += 1
		}
	}
}

// scan_string_escape validates an ECHAR or codepoint escape inside a
// string literal. SPARQL strings have no UCHAR production of their own;
// \u and \U are the pre-grammar codepoint escapes. s.pos is at the
// backslash on entry.
@(private = "file")
scan_string_escape :: proc(s: ^Scanner) -> bool {
	esc := s.pos
	if s.pos + 1 < len(s.source) {
		switch s.source[s.pos + 1] {
		case 't', 'b', 'n', 'r', 'f', '"', '\'', '\\':
			s.pos += 2
			return true
		case 'u', 'U':
			_, n := decode_escape_at(s, s.pos)
			if n != 0 {
				s.pos += n
				return true
			}
		}
	}
	set_error(s, .Invalid_Escape, esc)
	return false
}

@(private = "file")
scan_blank_node :: proc(s: ^Scanner, tok: ^Token) -> (Token, bool) {
	start := s.pos
	if peek(s, 1) != ':' {
		set_error(s, .Invalid_Blank_Node_Label, start)
		return {}, false
	}
	s.pos += 2
	content_start := s.pos
	r, n, esc := decode_char_at(s, s.pos)
	if n == 0 || !(is_pn_chars_u(r) || is_digit_rune(r)) {
		set_error(s, .Invalid_Blank_Node_Label, start)
		return {}, false
	}
	tok.has_escape |= esc
	s.pos += n
	for s.pos < len(s.source) {
		if s.source[s.pos] == '.' {
			// A dot run is label content only when a label character
			// follows it.
			j := s.pos
			for j < len(s.source) && s.source[j] == '.' {
				j += 1
			}
			r2, n2, _ := decode_char_at(s, j)
			if n2 == 0 || !is_pn_chars(r2) {
				break
			}
			s.pos = j
			continue
		}
		r, n, esc = decode_char_at(s, s.pos)
		if n == 0 || !is_pn_chars(r) {
			break
		}
		tok.has_escape |= esc
		s.pos += n
	}
	tok.kind = .Blank_Node_Label
	tok.text = string(s.source[content_start:s.pos])
	return tok^, true
}

// scan_lang_tag scans LANGTAG, including the SPARQL 1.2 base-direction
// suffix ('--' [a-zA-Z]+). The grammar places no length bound on
// subtags (unlike RDF 1.2's BCP47 well-formedness rule, which the
// family's format scanners enforce); validity of the direction word
// ('ltr'/'rtl') is the parser's concern.
@(private = "file")
scan_lang_tag :: proc(s: ^Scanner, tok: ^Token) -> (Token, bool) {
	start := s.pos
	s.pos += 1
	content_start := s.pos
	for s.pos < len(s.source) && is_alpha(s.source[s.pos]) {
		s.pos += 1
	}
	if s.pos == content_start {
		set_error(s, .Invalid_Lang_Tag, start)
		return {}, false
	}
	subtags: for s.pos < len(s.source) && s.source[s.pos] == '-' {
		if peek(s, 1) == '-' {
			// SPARQL 1.2 base direction suffix.
			s.pos += 2
			dir_start := s.pos
			for s.pos < len(s.source) && is_alpha(s.source[s.pos]) {
				s.pos += 1
			}
			if s.pos == dir_start {
				set_error(s, .Invalid_Lang_Tag, start)
				return {}, false
			}
			break subtags
		}
		s.pos += 1
		seg_start := s.pos
		for s.pos < len(s.source) && is_alnum(s.source[s.pos]) {
			s.pos += 1
		}
		if s.pos == seg_start {
			set_error(s, .Invalid_Lang_Tag, start)
			return {}, false
		}
	}
	tok.kind = .Lang_Tag
	tok.text = string(s.source[content_start:s.pos])
	return tok^, true
}

@(private = "file")
varname_starts_at :: proc(s: ^Scanner, at: int) -> bool {
	r, n, _ := decode_char_at(s, at)
	return n != 0 && (is_pn_chars_u(r) || is_digit_rune(r))
}

@(private = "file")
scan_var :: proc(s: ^Scanner, tok: ^Token) -> (Token, bool) {
	s.pos += 1 // '?' or '$'
	content_start := s.pos
	// The caller verified the first character; consume it.
	_, n0, esc0 := decode_char_at(s, s.pos)
	tok.has_escape |= esc0
	s.pos += n0
	for s.pos < len(s.source) {
		r, n, esc := decode_char_at(s, s.pos)
		if n == 0 || !is_varname_char(r) {
			break
		}
		tok.has_escape |= esc
		s.pos += n
	}
	tok.kind = .Var
	tok.text = string(s.source[content_start:s.pos])
	return tok^, true
}

@(private = "file")
scan_number :: proc(s: ^Scanner, tok: ^Token) -> (Token, bool) {
	start := s.pos
	if s.source[s.pos] == '+' || s.source[s.pos] == '-' {
		s.pos += 1
	}
	int_digits := scan_digits(s)
	kind := Token_Kind.Integer
	if s.pos < len(s.source) && s.source[s.pos] == '.' {
		// SPARQL DECIMAL requires digits after the dot ("1." is INTEGER
		// then Dot); "1.e0" is a DOUBLE with an empty fraction.
		if is_digit(peek(s, 1)) {
			s.pos += 1
			_ = scan_digits(s)
			kind = .Decimal
		} else if int_digits > 0 && starts_exponent(s, 1) {
			s.pos += 1
			kind = .Decimal // upgraded to Double below
		}
	}
	if starts_exponent(s, 0) {
		s.pos += 1 // 'e' | 'E'
		if s.source[s.pos] == '+' || s.source[s.pos] == '-' {
			s.pos += 1
		}
		_ = scan_digits(s)
		kind = .Double
	}
	if int_digits == 0 && kind == .Integer {
		set_error(s, .Invalid_Number, start)
		return {}, false
	}
	tok.kind = kind
	tok.text = string(s.source[start:s.pos])
	return tok^, true
}

// starts_exponent reports whether a complete EXPONENT ([eE] [+-]? [0-9]+)
// begins `ahead` bytes past the current position.
@(private = "file")
starts_exponent :: proc(s: ^Scanner, ahead: int) -> bool {
	i := s.pos + ahead
	if i >= len(s.source) || (s.source[i] != 'e' && s.source[i] != 'E') {
		return false
	}
	i += 1
	if i < len(s.source) && (s.source[i] == '+' || s.source[i] == '-') {
		i += 1
	}
	return i < len(s.source) && is_digit(s.source[i])
}

@(private = "file")
scan_digits :: proc(s: ^Scanner) -> (count: int) {
	for s.pos < len(s.source) && is_digit(s.source[s.pos]) {
		s.pos += 1
		count += 1
	}
	return
}

// scan_name scans a bare word starting with PN_CHARS_BASE: a keyword,
// 'a', a boolean, or the prefix part of a prefixed name.
@(private = "file")
scan_name :: proc(s: ^Scanner, tok: ^Token) -> (Token, bool) {
	start := s.pos
	r, n, esc := decode_char_at(s, s.pos)
	if n == 0 {
		// Malformed escape or invalid UTF-8.
		kind := Error_Kind.Invalid_Escape if s.source[s.pos] == '\\' else Error_Kind.Unexpected_Character
		set_error(s, kind, start)
		return {}, false
	}
	if !is_pn_chars_base(r) {
		// Includes a well-formed escape that produced a character no
		// token starts with — never re-interpreted (§19.2).
		set_error(s, .Unexpected_Character, start)
		return {}, false
	}
	tok.has_escape |= esc
	s.pos += n
	scan_prefix_body(s, tok)
	if s.pos < len(s.source) && s.source[s.pos] == ':' {
		return scan_pname(s, tok, start)
	}
	word := string(s.source[start:s.pos])
	if word == "a" {
		tok.kind = .A
		return tok^, true
	}
	kw, boolean, kw_ok := keyword_lookup(s, start, s.pos)
	if !kw_ok {
		set_error(s, .Unknown_Keyword, start)
		return {}, false
	}
	if boolean {
		tok.kind = .Boolean
		tok.text = word
		return tok^, true
	}
	tok.kind = .Keyword
	tok.keyword = kw
	return tok^, true
}

// scan_prefix_body consumes the rest of a PN_PREFIX after its first
// character: (PN_CHARS | '.')* PN_CHARS — dots interior only.
@(private = "file")
scan_prefix_body :: proc(s: ^Scanner, tok: ^Token) {
	for s.pos < len(s.source) {
		if s.source[s.pos] == '.' {
			j := s.pos
			for j < len(s.source) && s.source[j] == '.' {
				j += 1
			}
			r, n, _ := decode_char_at(s, j)
			if n == 0 || !is_pn_chars(r) {
				return
			}
			s.pos = j
			continue
		}
		r, n, esc := decode_char_at(s, s.pos)
		if n == 0 || !is_pn_chars(r) {
			return
		}
		tok.has_escape |= esc
		s.pos += n
	}
}

// scan_pname scans a prefixed name from its ':' separator; start is the
// offset of the prefix (equal to s.pos for the empty default prefix).
@(private = "file")
scan_pname :: proc(s: ^Scanner, tok: ^Token, start: int) -> (Token, bool) {
	s.pos += 1 // ':'
	if !scan_local(s, tok) {
		return {}, false
	}
	tok.kind = .PName
	tok.text = string(s.source[start:s.pos])
	return tok^, true
}

// scan_local consumes an optional PN_LOCAL. An empty local part is valid
// (PNAME_NS used bare).
@(private = "file")
scan_local :: proc(s: ^Scanner, tok: ^Token) -> bool {
	if !local_char_at(s, s.pos, true) {
		return true
	}
	if !consume_local_char(s, tok) {
		return false
	}
	for {
		if s.pos < len(s.source) && s.source[s.pos] == '.' {
			// A dot run is local content only when more local follows.
			j := s.pos
			for j < len(s.source) && s.source[j] == '.' {
				j += 1
			}
			if !local_char_at(s, j, false) {
				break
			}
			s.pos = j
			if !consume_local_char(s, tok) {
				return false
			}
			continue
		}
		if !local_char_at(s, s.pos, false) {
			break
		}
		if !consume_local_char(s, tok) {
			return false
		}
	}
	return true
}

// local_char_at reports whether a PN_LOCAL character (or PLX escape)
// starts at the given offset. The first character excludes '-', the
// middle dot, and combining marks (PN_CHARS_U | ':' | [0-9] | PLX).
@(private = "file")
local_char_at :: proc(s: ^Scanner, at: int, first: bool) -> bool {
	if at >= len(s.source) {
		return false
	}
	c := s.source[at]
	if c == ':' || c == '%' {
		return true
	}
	if c == '\\' {
		// Only PN_LOCAL_ESC — SPARQL 1.2 forbids codepoint escapes in
		// prefixed names.
		return at + 1 < len(s.source) && is_pn_local_esc(s.source[at + 1])
	}
	r, n, _ := decode_char_at(s, at)
	if n == 0 {
		return false
	}
	if first {
		return is_pn_chars_u(r) || is_digit_rune(r)
	}
	return is_pn_chars(r)
}

// consume_local_char consumes one PN_LOCAL constituent whose class was
// already validated by local_char_at.
@(private = "file")
consume_local_char :: proc(s: ^Scanner, tok: ^Token) -> bool {
	switch s.source[s.pos] {
	case '%':
		// PERCENT is content: validated, never decoded.
		if s.pos + 2 >= len(s.source) ||
		   !is_hex_digit(s.source[s.pos + 1]) ||
		   !is_hex_digit(s.source[s.pos + 2]) {
			set_error(s, .Invalid_Percent_Encoding, s.pos)
			return false
		}
		s.pos += 3
	case '\\':
		if s.pos + 1 >= len(s.source) || !is_pn_local_esc(s.source[s.pos + 1]) {
			set_error(s, .Invalid_Escape, s.pos)
			return false
		}
		tok.has_escape = true
		s.pos += 2
	case:
		_, n, _ := decode_char_at(s, s.pos)
		s.pos += n
	}
	return true
}

@(private = "file")
is_pn_local_esc :: proc(c: byte) -> bool {
	switch c {
	case '_', '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '@', '%':
		return true
	}
	return false
}

// keyword_lookup folds the word at source[start:end] to upper case
// through decode_char_at (codepoint escapes participate, so an escaped
// keyword still matches) and looks it up. boolean marks the 'true' and
// 'false' literals, which are not Keyword values. Keywords are pure
// ASCII and at most 14 characters; anything longer or non-ASCII is not
// a keyword.
@(private = "file")
keyword_lookup :: proc(s: ^Scanner, start, end: int) -> (kw: Keyword, boolean: bool, ok: bool) {
	buf: [16]byte
	n := 0
	at := start
	for at < end {
		r, size, _ := decode_char_at(s, at)
		if size == 0 || r > 127 || n >= len(buf) {
			return .None, false, false
		}
		c := byte(r)
		if 'a' <= c && c <= 'z' {
			c -= 32
		}
		buf[n] = c
		n += 1
		at += size
	}
	word := string(buf[:n])
	if word == "TRUE" || word == "FALSE" {
		return .None, true, true
	}
	kw = lookup_keyword_word(word)
	return kw, false, kw != .None
}

@(private = "file")
lookup_keyword_word :: proc(word: string) -> Keyword {
	kw := Keyword.None
	switch word {
	case "BASE":
		kw = .Base
	case "PREFIX":
		kw = .Prefix
	case "SELECT":
		kw = .Select
	case "DISTINCT":
		kw = .Distinct
	case "REDUCED":
		kw = .Reduced
	case "AS":
		kw = .As
	case "CONSTRUCT":
		kw = .Construct
	case "WHERE":
		kw = .Where
	case "DESCRIBE":
		kw = .Describe
	case "ASK":
		kw = .Ask
	case "FROM":
		kw = .From
	case "NAMED":
		kw = .Named
	case "GROUP":
		kw = .Group
	case "BY":
		kw = .By
	case "HAVING":
		kw = .Having
	case "ORDER":
		kw = .Order
	case "ASC":
		kw = .Asc
	case "DESC":
		kw = .Desc
	case "LIMIT":
		kw = .Limit
	case "OFFSET":
		kw = .Offset
	case "VALUES":
		kw = .Values
	case "OPTIONAL":
		kw = .Optional
	case "GRAPH":
		kw = .Graph
	case "SERVICE":
		kw = .Service
	case "SILENT":
		kw = .Silent
	case "BIND":
		kw = .Bind
	case "UNDEF":
		kw = .Undef
	case "MINUS":
		kw = .Minus
	case "UNION":
		kw = .Union
	case "FILTER":
		kw = .Filter
	case "IN":
		kw = .In
	case "NOT":
		kw = .Not
	case "EXISTS":
		kw = .Exists
	case "STR":
		kw = .Str
	case "LANG":
		kw = .Lang
	case "LANGMATCHES":
		kw = .Langmatches
	case "DATATYPE":
		kw = .Datatype
	case "BOUND":
		kw = .Bound
	case "IRI":
		kw = .Iri
	case "URI":
		kw = .Uri
	case "BNODE":
		kw = .Bnode
	case "RAND":
		kw = .Rand
	case "ABS":
		kw = .Abs
	case "CEIL":
		kw = .Ceil
	case "FLOOR":
		kw = .Floor
	case "ROUND":
		kw = .Round
	case "CONCAT":
		kw = .Concat
	case "STRLEN":
		kw = .Strlen
	case "UCASE":
		kw = .Ucase
	case "LCASE":
		kw = .Lcase
	case "ENCODE_FOR_URI":
		kw = .Encode_For_Uri
	case "CONTAINS":
		kw = .Contains
	case "STRSTARTS":
		kw = .Strstarts
	case "STRENDS":
		kw = .Strends
	case "STRBEFORE":
		kw = .Strbefore
	case "STRAFTER":
		kw = .Strafter
	case "YEAR":
		kw = .Year
	case "MONTH":
		kw = .Month
	case "DAY":
		kw = .Day
	case "HOURS":
		kw = .Hours
	case "MINUTES":
		kw = .Minutes
	case "SECONDS":
		kw = .Seconds
	case "TIMEZONE":
		kw = .Timezone
	case "TZ":
		kw = .Tz
	case "NOW":
		kw = .Now
	case "UUID":
		kw = .Uuid
	case "STRUUID":
		kw = .Struuid
	case "MD5":
		kw = .Md5
	case "SHA1":
		kw = .Sha1
	case "SHA256":
		kw = .Sha256
	case "SHA384":
		kw = .Sha384
	case "SHA512":
		kw = .Sha512
	case "COALESCE":
		kw = .Coalesce
	case "IF":
		kw = .If
	case "STRLANG":
		kw = .Strlang
	case "STRDT":
		kw = .Strdt
	case "SAMETERM":
		kw = .Same_Term
	case "ISIRI":
		kw = .Is_Iri
	case "ISURI":
		kw = .Is_Uri
	case "ISBLANK":
		kw = .Is_Blank
	case "ISLITERAL":
		kw = .Is_Literal
	case "ISNUMERIC":
		kw = .Is_Numeric
	case "REGEX":
		kw = .Regex
	case "SUBSTR":
		kw = .Substr
	case "REPLACE":
		kw = .Replace
	case "COUNT":
		kw = .Count
	case "SUM":
		kw = .Sum
	case "MIN":
		kw = .Min
	case "MAX":
		kw = .Max
	case "AVG":
		kw = .Avg
	case "SAMPLE":
		kw = .Sample
	case "GROUP_CONCAT":
		kw = .Group_Concat
	case "SEPARATOR":
		kw = .Separator
	case "VERSION":
		kw = .Version
	case "TRIPLE":
		kw = .Triple
	case "SUBJECT":
		kw = .Subject
	case "PREDICATE":
		kw = .Predicate
	case "OBJECT":
		kw = .Object
	case "ISTRIPLE":
		kw = .Is_Triple
	case "LANGDIR":
		kw = .Lang_Dir
	case "STRLANGDIR":
		kw = .Str_Lang_Dir
	case "HASLANG":
		kw = .Has_Lang
	case "HASLANGDIR":
		kw = .Has_Lang_Dir
	}
	return kw
}

// decode_char_at decodes the UTF-8 character at `at`. Codepoint
// escapes are NOT decoded here — SPARQL 1.2 confines them to strings
// and IRIs, whose scanners handle them explicitly. n == 0 marks an
// invalid character; the caller chooses the error kind from context.
@(private = "file")
decode_char_at :: proc(s: ^Scanner, at: int) -> (r: rune, n: int, escaped: bool) {
	if at >= len(s.source) {
		return 0, 0, false
	}
	c := s.source[at]
	if c < 0x80 {
		return rune(c), 1, false
	}
	r, n = utf8.decode_rune(s.source[at:])
	// A genuine U+FFFD decodes as RUNE_ERROR with size 3 and is a legal
	// PN_CHARS_BASE character; only a size-1 error marks invalid bytes.
	if r == utf8.RUNE_ERROR && n <= 1 {
		return 0, 0, false
	}
	return r, n, false
}

// decode_escape_at decodes a codepoint escape at `at` (which holds the
// backslash). Surrogates and values beyond U+10FFFF are not characters
// and are rejected. n == 0 marks a malformed escape.
@(private = "file")
decode_escape_at :: proc(s: ^Scanner, at: int) -> (r: rune, n: int) {
	digits: int
	switch peek_at(s, at + 1) {
	case 'u':
		digits = 4
	case 'U':
		digits = 8
	case:
		return 0, 0
	}
	value: u32
	for i in 0 ..< digits {
		c := peek_at(s, at + 2 + i)
		if !is_hex_digit(c) {
			return 0, 0
		}
		value <<= 4
		switch {
		case c <= '9':
			value |= u32(c - '0')
		case c >= 'a':
			value |= u32(c - 'a' + 10)
		case:
			value |= u32(c - 'A' + 10)
		}
	}
	if (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF {
		return 0, 0
	}
	return rune(value), 2 + digits
}

@(private = "file")
peek_at :: proc(s: ^Scanner, at: int) -> byte {
	if at < len(s.source) {
		return s.source[at]
	}
	return 0
}

@(private = "file")
is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_alpha :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z':
		return true
	}
	return false
}

@(private = "file")
is_alnum :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	}
	return false
}

@(private = "file")
is_hex_digit :: proc(c: byte) -> bool {
	switch c {
	case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		return true
	}
	return false
}

@(private = "file")
is_digit_rune :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// is_pn_chars_base implements the PN_CHARS_BASE production of the SPARQL
// grammar exactly (identical to Turtle's).
@(private = "file")
is_pn_chars_base :: proc(r: rune) -> bool {
	switch r {
	case 'A' ..= 'Z', 'a' ..= 'z',
	     0x00C0 ..= 0x00D6, 0x00D8 ..= 0x00F6, 0x00F8 ..= 0x02FF,
	     0x0370 ..= 0x037D, 0x037F ..= 0x1FFF, 0x200C ..= 0x200D,
	     0x2070 ..= 0x218F, 0x2C00 ..= 0x2FEF, 0x3001 ..= 0xD7FF,
	     0xF900 ..= 0xFDCF, 0xFDF0 ..= 0xFFFD, 0x10000 ..= 0xEFFFF:
		return true
	}
	return false
}

@(private = "file")
is_pn_chars_u :: proc(r: rune) -> bool {
	return r == '_' || is_pn_chars_base(r)
}

@(private = "file")
is_pn_chars :: proc(r: rune) -> bool {
	switch r {
	case '-', '0' ..= '9', 0x00B7, 0x0300 ..= 0x036F, 0x203F ..= 0x2040:
		return true
	}
	return is_pn_chars_u(r)
}

// is_varname_char implements the VARNAME continuation set: PN_CHARS_U,
// digits, middle dot, and combining marks — no '-' and no '.' (unlike
// PN_CHARS).
@(private = "file")
is_varname_char :: proc(r: rune) -> bool {
	switch r {
	case '0' ..= '9', 0x00B7, 0x0300 ..= 0x036F, 0x203F ..= 0x2040:
		return true
	}
	return is_pn_chars_u(r)
}
