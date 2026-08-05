package sparql

// Error_Kind enumerates grammar violations. Scanner-level kinds only for
// now; parser-level kinds arrive with the parser core (SPARQL-T-0003) so
// the whole package shares this single Error type, the family shape
// (mirrored from odin-rdf-parser, whose type is internal to that repo).
Error_Kind :: enum {
	None,
	// Scanner-level.
	Unexpected_Character,
	Unterminated_IRI,
	Invalid_IRI_Character,
	Unterminated_String,
	Invalid_String_Character,
	Unterminated_Long_String,
	Invalid_Escape,
	Invalid_Percent_Encoding,
	Invalid_Blank_Node_Label,
	Invalid_Lang_Tag,
	Invalid_Number,
	Invalid_Variable_Name,
	Unknown_Keyword,
}

// Error is a grammar violation with its position. The zero value (kind
// .None) means no error.
Error :: struct {
	kind:   Error_Kind,
	offset: int, // byte offset into the source
	line:   int, // 1-based
	column: int, // 1-based, in bytes
}

// error_message returns a static description of the error kind,
// referencing the violated grammar production by name (production names
// are stable across SPARQL spec revisions, unlike their numbers).
// Position formatting is the caller's concern; this never allocates.
error_message :: proc(kind: Error_Kind) -> string {
	switch kind {
	case .None:
		return "no error"
	case .Unexpected_Character:
		return "unexpected character (QueryUnit)"
	case .Unterminated_IRI:
		return "unterminated IRI reference (IRIREF)"
	case .Invalid_IRI_Character:
		return "character not allowed in IRI reference (IRIREF)"
	case .Unterminated_String:
		return "unterminated string literal (STRING_LITERAL1/STRING_LITERAL2)"
	case .Invalid_String_Character:
		return "raw newline in string literal; use \\n or \\r (STRING_LITERAL1/STRING_LITERAL2)"
	case .Unterminated_Long_String:
		return "unterminated long string literal (STRING_LITERAL_LONG1/STRING_LITERAL_LONG2)"
	case .Invalid_Escape:
		return "invalid escape sequence (ECHAR/PN_LOCAL_ESC/codepoint escape)"
	case .Invalid_Percent_Encoding:
		return "malformed percent encoding in local name (PERCENT)"
	case .Invalid_Blank_Node_Label:
		return "malformed blank node label (BLANK_NODE_LABEL)"
	case .Invalid_Lang_Tag:
		return "malformed language tag (LANGTAG)"
	case .Invalid_Number:
		return "malformed numeric literal (INTEGER/DECIMAL/DOUBLE)"
	case .Invalid_Variable_Name:
		return "malformed variable name (VAR1/VAR2)"
	case .Unknown_Keyword:
		return "word is neither a SPARQL keyword, 'a', 'true'/'false', nor a prefixed name (QueryUnit)"
	}
	return "unknown error"
}
