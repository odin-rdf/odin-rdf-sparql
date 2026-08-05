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
	// Parser-level (set by the query parser, SPARQL-T-0003 on).
	Expected_Query_Form,
	Expected_Projection,
	Expected_Group,
	Unclosed_Group,
	Expected_Pattern,
	Expected_Subject,
	Expected_Predicate,
	Expected_Object,
	Expected_IRI,
	Expected_Datatype,
	Expected_Prefix_Name,
	Undefined_Prefix,
	Relative_IRI,
	Expected_Variable,
	Expected_Integer,
	Unclosed_Collection,
	Unclosed_Property_List,
	Nesting_Too_Deep,
	Blank_Label_Reuse,
	Invalid_Direction,
	Trailing_Content,
	Expected_Expression,
	Expected_Close_Paren,
	Wrong_Arity,
	Expected_As,
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
	case .Expected_Query_Form:
		return "expected SELECT or ASK (Query)"
	case .Expected_Projection:
		return "expected '*' or variables in the SELECT clause (SelectClause)"
	case .Expected_Group:
		return "expected '{' to open a group graph pattern (GroupGraphPattern)"
	case .Unclosed_Group:
		return "group graph pattern not closed with '}' (GroupGraphPattern)"
	case .Expected_Pattern:
		return "expected a triple pattern, group, OPTIONAL, GRAPH, or UNION (GraphPatternNotTriples)"
	case .Expected_Subject:
		return "expected a term or variable as subject (TriplesSameSubject)"
	case .Expected_Predicate:
		return "expected an IRI, variable, or 'a' as predicate (Verb)"
	case .Expected_Object:
		return "expected a term or variable as object (ObjectList)"
	case .Expected_IRI:
		return "expected an IRI reference (iri)"
	case .Expected_Datatype:
		return "expected an IRI after '^^' (RDFLiteral)"
	case .Expected_Prefix_Name:
		return "expected a prefix name ending in ':' (PrefixDecl)"
	case .Undefined_Prefix:
		return "prefixed name uses an undeclared prefix (PrefixedName)"
	case .Relative_IRI:
		return "relative IRI with no base established (IRIREF)"
	case .Expected_Variable:
		return "expected a variable (Var)"
	case .Expected_Integer:
		return "expected a non-negative integer (LimitClause/OffsetClause)"
	case .Unclosed_Collection:
		return "collection not closed with ')' (Collection)"
	case .Unclosed_Property_List:
		return "blank node property list not closed with ']' (BlankNodePropertyList)"
	case .Nesting_Too_Deep:
		return "nesting exceeds the parser's depth bound (GroupGraphPattern/TriplesNode)"
	case .Blank_Label_Reuse:
		return "blank node label reused across basic graph patterns (BLANK_NODE_LABEL)"
	case .Invalid_Direction:
		return "base direction must be 'ltr' or 'rtl' (LANGTAG)"
	case .Trailing_Content:
		return "unexpected content after the end of the query (QueryUnit)"
	case .Expected_Expression:
		return "expected an expression (Expression)"
	case .Expected_Close_Paren:
		return "expected ')' (BrackettedExpression/ArgList)"
	case .Wrong_Arity:
		return "wrong number of arguments for built-in call (BuiltInCall)"
	case .Expected_As:
		return "expected AS (SelectClause/Bind)"
	}
	return "unknown error"
}
