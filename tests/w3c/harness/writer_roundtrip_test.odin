// Round-trip for the result writers: build a result set, write it with
// sparql/srj and sparql/srx, read it back with this package's readers,
// and compare with the same §12.2 comparison the evaluation suites use.
//
// The point is that the writers are checked against readers written
// independently of them, against the vendored W3C documents — not
// against a fixture that agrees with them by construction. Anything a
// writer encodes wrongly either fails to parse or compares unequal.
package w3c

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"

import srj "../../../sparql/srj"
import srx "../../../sparql/srx"

// VARS has static storage on purpose: an Odin slice literal is backed by
// the enclosing stack frame, so returning one from a procedure hands back
// a dangling slice. Same reason the rows below are make()d rather than
// written as literals.
@(private = "file")
VARS := [?]string{"iri", "blank", "plain", "typed", "tagged", "star"}

// fixture spans every term kind the formats carry, plus the cases that
// break naive writers: unbound cells, a literal needing escapes in both
// formats, a control character, a language tag with a base direction,
// and an RDF-star triple term. Release with fixture_destroy.
@(private = "file")
fixture :: proc() -> (vars: []string, rows: [][]rdf.Term) {
	nested := new(rdf.Triple)
	nested.subject = rdf.IRI("http://example.org/s")
	nested.predicate = rdf.IRI("http://example.org/p")
	nested.object = rdf.literal_plain("o")

	vars = VARS[:]
	rows = make([][]rdf.Term, 3)
	for &row in rows {
		row = make([]rdf.Term, len(VARS))
	}

	rows[0][0] = rdf.IRI("http://example.org/a?x=1&y=2")
	rows[0][1] = rdf.Blank_Node("b0")
	rows[0][2] = rdf.literal_plain(`quote " backslash \ lt < amp & gt >`)
	rows[0][3] = rdf.literal_typed("42", rdf.IRI("http://www.w3.org/2001/XMLSchema#integer"))
	rows[0][4] = rdf.literal_lang("hello", "en")
	rows[0][5] = nested

	// An entirely unbound tail: the writers must omit those bindings
	// rather than emit empty ones.
	rows[1][0] = rdf.IRI("http://example.org/b")

	// A control character the JSON writer must escape as \u00XX, and a
	// directional language-tagged literal.
	rows[2][2] = rdf.literal_plain("newline:\n control:\x01 end")
	rows[2][4] = rdf.literal_dir_lang("hallo", "de", .LTR)
	return
}

@(private = "file")
fixture_destroy :: proc(rows: [][]rdf.Term) {
	free(rows[0][5].(^rdf.Triple))
	for row in rows {
		delete(row)
	}
	delete(rows)
}

@(private = "file")
expected_set :: proc(vars: []string, rows: [][]rdf.Term) -> Result_Set {
	rs: Result_Set
	rs.kind = .Bindings
	rs.vars = make([dynamic]string)
	for v in vars {
		append(&rs.vars, strings.clone(v))
	}
	rs.rows = make([dynamic][dynamic]rdf.Term)
	for row in rows {
		out := make([dynamic]rdf.Term)
		for cell in row {
			append(&out, rdf.clone_term(cell) if cell != nil else nil)
		}
		append(&rs.rows, out)
	}
	return rs
}

@(test)
test_srj_writer_roundtrips :: proc(t: ^testing.T) {
	vars, rows := fixture()
	defer fixture_destroy(rows)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	e: srj.Emitter
	testing.expect(t, srj.emitter_init(&e, strings.to_writer(&b), vars) == nil)
	for row in rows {
		testing.expect(t, srj.emit(&e, row) == nil)
	}
	testing.expect(t, srj.emitter_finish(&e) == nil)

	actual, ok := read_srj(transmute([]byte)strings.to_string(b))
	testing.expectf(t, ok, "written SRJ did not parse:\n%s", strings.to_string(b))
	if !ok {
		return
	}
	defer result_set_destroy(&actual)

	expected := expected_set(vars, rows)
	defer result_set_destroy(&expected)

	equal, reason := results_equal(&actual, &expected, Compare_Options{})
	testing.expectf(t, equal, "SRJ round-trip: %s\nwrote:\n%s", reason, strings.to_string(b))
}

@(test)
test_srx_writer_roundtrips :: proc(t: ^testing.T) {
	vars, rows := fixture()
	defer fixture_destroy(rows)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	e: srx.Emitter
	testing.expect(t, srx.emitter_init(&e, strings.to_writer(&b), vars) == nil)
	for row in rows {
		testing.expect(t, srx.emit(&e, row) == nil)
	}
	testing.expect(t, srx.emitter_finish(&e) == nil)

	actual, ok := read_srx(strings.to_string(b))
	testing.expectf(t, ok, "written SRX did not parse:\n%s", strings.to_string(b))
	if !ok {
		return
	}
	defer result_set_destroy(&actual)

	expected := expected_set(vars, rows)
	defer result_set_destroy(&expected)

	equal, reason := results_equal(&actual, &expected, Compare_Options{})
	testing.expectf(t, equal, "SRX round-trip: %s\nwrote:\n%s", reason, strings.to_string(b))
}

@(test)
test_writers_emit_ask :: proc(t: ^testing.T) {
	for value in ([?]bool{true, false}) {
		bj := strings.builder_make()
		defer strings.builder_destroy(&bj)
		testing.expect(t, srj.emit_boolean(strings.to_writer(&bj), value) == nil)
		rj, ok_j := read_srj(transmute([]byte)strings.to_string(bj))
		testing.expectf(t, ok_j, "ASK SRJ did not parse: %s", strings.to_string(bj))
		if ok_j {
			defer result_set_destroy(&rj)
			testing.expect_value(t, rj.kind, Result_Kind.Boolean)
			testing.expect_value(t, rj.boolean, value)
		}

		bx := strings.builder_make()
		defer strings.builder_destroy(&bx)
		testing.expect(t, srx.emit_boolean(strings.to_writer(&bx), value) == nil)
		rx, ok_x := read_srx(strings.to_string(bx))
		testing.expectf(t, ok_x, "ASK SRX did not parse: %s", strings.to_string(bx))
		if ok_x {
			defer result_set_destroy(&rx)
			testing.expect_value(t, rx.kind, Result_Kind.Boolean)
			testing.expect_value(t, rx.boolean, value)
		}
	}
}

@(test)
test_writers_emit_empty_result_set :: proc(t: ^testing.T) {
	vars := VARS[:1]

	bj := strings.builder_make()
	defer strings.builder_destroy(&bj)
	ej: srj.Emitter
	testing.expect(t, srj.emitter_init(&ej, strings.to_writer(&bj), vars) == nil)
	testing.expect(t, srj.emitter_finish(&ej) == nil)
	rj, ok_j := read_srj(transmute([]byte)strings.to_string(bj))
	testing.expectf(t, ok_j, "empty SRJ did not parse: %s", strings.to_string(bj))
	if ok_j {
		defer result_set_destroy(&rj)
		testing.expect_value(t, len(rj.rows), 0)
		testing.expect_value(t, len(rj.vars), 1)
	}

	bx := strings.builder_make()
	defer strings.builder_destroy(&bx)
	ex: srx.Emitter
	testing.expect(t, srx.emitter_init(&ex, strings.to_writer(&bx), vars) == nil)
	testing.expect(t, srx.emitter_finish(&ex) == nil)
	rx, ok_x := read_srx(strings.to_string(bx))
	testing.expectf(t, ok_x, "empty SRX did not parse: %s", strings.to_string(bx))
	if ok_x {
		defer result_set_destroy(&rx)
		testing.expect_value(t, len(rx.rows), 0)
		testing.expect_value(t, len(rx.vars), 1)
	}
}
