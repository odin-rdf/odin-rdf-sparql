// Exact-output tests. The round-trip in tests/w3c/harness proves the
// writer and this project's readers agree; these pin the actual bytes
// against the format specification, which a round-trip cannot do -- a
// writer and a reader can agree on the same mistake.
package srj

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
test_head_and_bindings :: proc(t: ^testing.T) {
	vars := [?]string{"x"}
	row := [?]rdf.Term{rdf.IRI("http://example.org/a")}
	out := write(vars[:], row[:])
	defer delete(out)
	testing.expect_value(
		t,
		out,
		`{"head":{"vars":["x"]},"results":{"bindings":[{"x":{"type":"uri","value":"http://example.org/a"}}]}}`,
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
	testing.expect(t, strings.contains(out, `"a":{"type":"bnode","value":"b0"}`))
	testing.expect(t, strings.contains(out, `"b":{"type":"literal","value":"plain"}`))
	testing.expect(
		t,
		strings.contains(
			out,
			`"c":{"type":"literal","value":"42","datatype":"http://www.w3.org/2001/XMLSchema#integer"}`,
		),
	)
	testing.expect(t, strings.contains(out, `"d":{"type":"literal","value":"hi","xml:lang":"en"}`))
}

@(test)
test_unbound_is_omitted :: proc(t: ^testing.T) {
	vars := [?]string{"x", "y"}
	row := [?]rdf.Term{nil, rdf.IRI("http://example.org/a")}
	out := write(vars[:], row[:])
	defer delete(out)
	// Not "x":null -- the format omits unbound variables entirely.
	testing.expect(t, !strings.contains(out, `"x"`) || strings.contains(out, `"vars":["x"`))
	testing.expect(t, strings.contains(out, `[{"y":{"type":"uri"`))
}

@(test)
test_escapes :: proc(t: ^testing.T) {
	vars := [?]string{"x"}
	row := [?]rdf.Term{rdf.literal_plain("q\" b\\ nl\n ctrl\x01")}
	out := write(vars[:], row[:])
	defer delete(out)
	// The C0 control has no short form, so it becomes \u0001.
	testing.expectf(t, strings.contains(out, "q\\\" b\\\\ nl\\n ctrl\\u0001"), "got: %s", out)
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

	testing.expect(t, strings.contains(out, `"xml:lang":"ar","its:dir":"rtl"`))
	testing.expect(
		t,
		strings.contains(
			out,
			`"s":{"type":"triple","value":{"subject":{"type":"uri","value":"http://example.org/s"},"predicate":{"type":"uri","value":"http://example.org/p"},"object":{"type":"literal","value":"o"}}}`,
		),
	)
}

@(test)
test_ask :: proc(t: ^testing.T) {
	Case :: struct {
		value: bool,
		want:  string,
	}
	cases := [?]Case {
		{true, `{"head":{},"boolean":true}`},
		{false, `{"head":{},"boolean":false}`},
	}
	for c in cases {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		testing.expect(t, emit_boolean(strings.to_writer(&b), c.value) == nil)
		testing.expect_value(t, strings.to_string(b), c.want)
	}
}
