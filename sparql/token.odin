package sparql

// Token_Kind enumerates the terminals of the SPARQL grammar (W3C SPARQL
// 1.1 Query plus the SPARQL 1.2 triple-term surface). Keywords collapse
// into one kind carrying a Keyword value — the set is large and uniform,
// and the parser dispatches on the keyword, not the kind.
Token_Kind :: enum {
	Invalid,
	IRI_Ref, // <...>, text without the angle brackets
	PName, // prefixed name incl. the colon; split at the FIRST colon
	Blank_Node_Label, // _:label, text without the "_:" prefix
	Var, // ?name or $name, text without the sigil
	String_Literal, // any of the four quoted forms, delimiters stripped
	Lang_Tag, // @tag, text without the "@"; direction suffix included
	Integer, // INTEGER(_POSITIVE/_NEGATIVE), full lexical form incl. sign
	Decimal, // DECIMAL(_POSITIVE/_NEGATIVE)
	Double, // DOUBLE(_POSITIVE/_NEGATIVE)
	Boolean, // 'true' or 'false' (case-insensitive), text as written
	A, // the keyword 'a' (rdf:type; case-sensitive)
	Keyword, // any other keyword; see the keyword field
	Nil, // '(' WS* ')'
	Anon, // '[' WS* ']'
	L_Brace, // {
	R_Brace, // }
	L_Paren, // (
	R_Paren, // )
	L_Bracket, // [
	R_Bracket, // ]
	Semicolon, // ;
	Comma, // ,
	Dot, // .
	Datatype_Marker, // ^^
	Caret, // ^ (property-path inverse)
	Slash, // / (property-path sequence)
	Pipe, // | (property-path alternative)
	Or, // ||
	And, // &&
	Bang, // !
	Eq, // =
	Ne, // !=
	Lt, // <
	Le, // <=
	Gt, // >
	Ge, // >=
	Plus, // +
	Minus, // -
	Star, // *
	Question, // ? (property-path zero-or-one; '?name' is Var)
	Reified_Open, // << (SPARQL 1.2)
	Reified_Close, // >> (SPARQL 1.2)
	Triple_Term_Open, // <<( (SPARQL 1.2)
	Triple_Term_Close, // )>> (SPARQL 1.2)
}

// Keyword enumerates the case-insensitive SPARQL keywords ('a' is a
// separate token kind because it alone is case-sensitive; 'true' and
// 'false' surface as Boolean tokens). SPARQL 1.2 additions at the end.
Keyword :: enum {
	None,
	// Query forms and clauses.
	Base,
	Prefix,
	Select,
	Distinct,
	Reduced,
	As,
	Construct,
	Where,
	Describe,
	Ask,
	From,
	Named,
	Group,
	By,
	Having,
	Order,
	Asc,
	Desc,
	Limit,
	Offset,
	Values,
	// Graph patterns.
	Optional,
	Graph,
	Service,
	Silent,
	Bind,
	Undef,
	Minus,
	Union,
	Filter,
	// Expressions.
	In,
	Not,
	Exists,
	// Built-in calls.
	Str,
	Lang,
	Langmatches,
	Datatype,
	Bound,
	Iri,
	Uri,
	Bnode,
	Rand,
	Abs,
	Ceil,
	Floor,
	Round,
	Concat,
	Strlen,
	Ucase,
	Lcase,
	Encode_For_Uri,
	Contains,
	Strstarts,
	Strends,
	Strbefore,
	Strafter,
	Year,
	Month,
	Day,
	Hours,
	Minutes,
	Seconds,
	Timezone,
	Tz,
	Now,
	Uuid,
	Struuid,
	Md5,
	Sha1,
	Sha256,
	Sha384,
	Sha512,
	Coalesce,
	If,
	Strlang,
	Strdt,
	Same_Term,
	Is_Iri,
	Is_Uri,
	Is_Blank,
	Is_Literal,
	Is_Numeric,
	Regex,
	Substr,
	Replace,
	// Aggregates.
	Count,
	Sum,
	Min,
	Max,
	Avg,
	Sample,
	Group_Concat,
	Separator,
	// SPARQL 1.2.
	Version,
	Triple,
	Subject,
	Predicate,
	Object,
	Is_Triple,
	Lang_Dir,
	Str_Lang_Dir,
	Has_Lang,
	Has_Lang_Dir,
}

// Token is one terminal. text is a borrowed slice of the source buffer
// with delimiters stripped (except PName, which keeps its colon); it is
// valid as long as the source is. has_escape marks tokens whose text
// still contains \-escapes (ECHAR, PN_LOCAL_ESC, or codepoint escapes)
// for the parser to decode on materialization — percent encodings in
// local names are content, never decoded.
Token :: struct {
	kind:        Token_Kind,
	keyword:     Keyword, // set when kind == .Keyword, .None otherwise
	text:        string,
	offset:      int, // byte offset of the token start (incl. delimiters)
	line:        int, // 1-based
	column:      int, // 1-based, in bytes
	has_escape:  bool,
	long_string: bool, // String_Literal came from a long ("""/''') form
}
