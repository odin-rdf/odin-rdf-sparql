// Exact-output tests. The round-trip in tests/w3c/harness proves the
// writer and this project's readers agree; these pin the actual bytes
// against the format specification, which a round-trip cannot do -- a
// writer and a reader can agree on the same mistake.
package srx

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"

@(private = "file")
write :: proc(vars: []string, rows: ..[]rdf.Term) -> string {
	b := strings.builder_make()
	e: Emitter
	assert(emitter_init(&e, strings.to_writer(&b), vars) == nil)
	for row in rows {
		assert(emit(&e, row) == nil)
	}
	assert(emitter_finish(&e) == nil)
	return strings.to_string(b)
}

@(test)
test_document_shape :: proc(t: ^testing.T) {
	vars := [?]string{"x"}
	row := [?]rdf.Term{rdf.IRI("http://example.org/a")}
	out := write(vars[:], row[:])
	defer delete(out)
	testing.expect_value(
		t,
		out,
		`<?xml version="1.0"?><sparql xmlns="http://www.w3.org/2005/sparql-results#">` +
		`<head><variable name="x"/></head><results><result>` +
		`<binding name="x"><uri>http://example.org/a</uri></binding>` +
		`</result></results></sparql>`,
	)
}

@(test)
test_term_kinds :: proc(t: ^testing.T) {
	vars := [?]string{"a", "b", "c", "d"}
	row := [?]rdf.Term {
		rdf.Blank_Node("b0"),
		rdf.literal_plain("plain"),
		rdf.literal_typed("42", rdf.IRI("http://www.w3.org/2001/XMLSchema#integer")),
		rdf.literal_lang("hi", "en"),
	}
	out := write(vars[:], row[:])
	defer delete(out)

	// The blank node's label carries no "_:" -- that is syntax, not
	// identity. A plain literal writes no datatype: xsd:string is the
	// data model's invariant and readers infer it.
	testing.expect(t, strings.contains(out, `<bnode>b0</bnode>`))
	testing.expect(t, strings.contains(out, `<literal>plain</literal>`))
	testing.expect(
		t,
		strings.contains(
			out,
			`<literal datatype="http://www.w3.org/2001/XMLSchema#integer">42</literal>`,
		),
	)
	testing.expect(t, strings.contains(out, `<literal xml:lang="en">hi</literal>`))
}

@(test)
test_unbound_is_omitted :: proc(t: ^testing.T) {
	vars := [?]string{"x", "y"}
	row := [?]rdf.Term{nil, rdf.IRI("http://example.org/a")}
	out := write(vars[:], row[:])
	defer delete(out)
	// One binding element, for y only -- not an empty <binding name="x"/>.
	testing.expect(t, strings.contains(out, `<result><binding name="y">`))
	testing.expect(t, !strings.contains(out, `<binding name="x"`))
}

@(test)
test_escapes :: proc(t: ^testing.T) {
	vars := [?]string{"x"}
	// A carriage return in character content must survive as a character
	// reference: an XML processor normalizes a literal CR away, which
	// would silently change the literal's value.
	row := [?]rdf.Term{rdf.literal_plain("a & b < c > d\r")}
	out := write(vars[:], row[:])
	defer delete(out)
	testing.expect(t, strings.contains(out, `a &amp; b &lt; c &gt; d&#xD;`))
}

@(test)
test_attribute_escapes :: proc(t: ^testing.T) {
	vars := [?]string{"x"}
	row := [?]rdf.Term{rdf.literal_typed("v", rdf.IRI(`http://example.org/a"b&c`))}
	out := write(vars[:], row[:])
	defer delete(out)
	testing.expect(t, strings.contains(out, `datatype="http://example.org/a&quot;b&amp;c"`))
}

@(test)
test_direction_and_triple_term :: proc(t: ^testing.T) {
	nested := new(rdf.Triple)
	defer free(nested)
	nested.subject = rdf.IRI("http://example.org/s")
	nested.predicate = rdf.IRI("http://example.org/p")
	nested.object = rdf.literal_plain("o")

	vars := [?]string{"d", "s"}
	row := [?]rdf.Term{rdf.literal_dir_lang("x", "ar", .RTL), nested}
	out := write(vars[:], row[:])
	defer delete(out)

	testing.expect(t, strings.contains(out, `<literal xml:lang="ar" dir="rtl">x</literal>`))
	testing.expect(
		t,
		strings.contains(
			out,
			`<triple><subject><uri>http://example.org/s</uri></subject>` +
			`<predicate><uri>http://example.org/p</uri></predicate>` +
			`<object><literal>o</literal></object></triple>`,
		),
	)
}

@(test)
test_ask :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect(t, emit_boolean(strings.to_writer(&b), true) == nil)
	testing.expect_value(
		t,
		strings.to_string(b),
		`<?xml version="1.0"?><sparql xmlns="http://www.w3.org/2005/sparql-results#">` +
		`<head/><boolean>true</boolean></sparql>`,
	)
}
