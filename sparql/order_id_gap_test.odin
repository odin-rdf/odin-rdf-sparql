// Why `ORDER BY`, `MIN`/`MAX` and `ORDER BY … LIMIT n` do not read
// odin-rdf-record in its own order (SPARQL-T-0038).
//
// record can hand this engine a range already sorted on any position
// (`snapshot_match_as`), and three operators here pay for an order they
// could in principle be given: `Plan_Order` sorts a materialized set,
// `Plan_Slice` over it discards what the sort just produced, and
// `agg_keep_extreme` walks a whole group to find one end of it.
//
// **They cannot take it, and this file is the proof.** record's ids are
// ordered, but not in SPARQL's order, and the disagreement is not a
// corner: three independent, ordinary mechanisms each produce it. What
// disqualifies a value is a property of the *data*, and SPARQL has no
// static types, so no plan can establish from a pattern and a sort key
// that the two orders agree. That is the whole finding; see the task.
//
// This file is a guard, not a demonstration. If someone later takes the
// streaming path on the grounds that "ids are ordered", these fail.
package sparql

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

@(private = "file")
XSD :: "http://www.w3.org/2001/XMLSchema#"

@(private = "file")
ORDER_GAP_FIXTURE :: `
@prefix : <http://example/> .
:a :v 1 .
:b :v 3 .
:c :v 200000000 .
:d :v "2.5"^^<http://www.w3.org/2001/XMLSchema#decimal> .
:e :v "007"^^<http://www.w3.org/2001/XMLSchema#integer> .
`

@(private = "file")
integer :: proc(lex: string) -> rdf.Term {
	return rdf.Literal{lexical = lex, datatype = rdf.IRI(XSD + "integer")}
}

// The three ways an ordinary number leaves the inlined range, and what
// each does to its id. RECORD-A-0001 froze the scheme: bit 31 flags an
// inlined term, bits 30..28 tag its type, and the low 28 bits carry an
// offset-binary payload — so inlined integers do sort numerically among
// themselves, and every dictionary id (< 2^31) sorts before every
// inlined one (>= 2^31).
@(test)
test_record_id_order_is_not_sparql_order :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "order-gap") {return}
	if !test_db_load(t, &d, ORDER_GAP_FIXTURE) {return}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {return}

	id :: proc(t: ^testing.T, snap: record.Snapshot, term: rdf.Term, label: string) -> record.Term_ID {
		v, ok := record.snapshot_resolve(snap, term)
		testing.expectf(t, ok, "%s did not resolve", label)
		return v
	}
	INLINED :: record.Term_ID(0x8000_0000)

	one := id(t, snap, integer("1"), "1")
	three := id(t, snap, integer("3"), "3")
	// **1. Out of range.** The inlined payload is 28 bits offset-binary,
	// so |v| >= 2^27 (134,217,728) is a dictionary term. Two hundred
	// million is not an exotic number.
	huge := id(t, snap, integer("200000000"), "200000000")
	// **2. Not an integer.** xsd:decimal, xsd:float and xsd:double are
	// never inlined, and SPARQL compares the whole numeric tower by
	// value — 2.5 belongs between 1 and 3.
	decimal := id(t, snap, rdf.Literal{lexical = "2.5", datatype = rdf.IRI(XSD + "decimal")}, "2.5")
	// **3. Not canonical.** `term_inline` takes canonical lexical forms
	// only, which is RDF term identity done correctly; "007" is a
	// different term from "7" and only the latter would inline.
	padded := id(t, snap, integer("007"), "007")

	testing.expect(t, one >= INLINED && three >= INLINED, "small canonical integers must inline")
	testing.expect(t, one < three, "inlined integers must sort by value among themselves")
	testing.expectf(t, huge < INLINED, "an out-of-range integer must be a dictionary term, got %d", huge)
	testing.expectf(t, decimal < INLINED, "a decimal must be a dictionary term, got %d", decimal)
	testing.expectf(t, padded < INLINED, "a non-canonical form must be a dictionary term, got %d", padded)

	// The consequence, stated as the assertion that matters: by id, the
	// largest of these five sorts first and the smallest sorts fourth.
	// Reading a range in record's order and calling it ORDER BY would
	// return exactly this.
	testing.expect(t, huge < one, "by id the largest value precedes the smallest — the whole problem")
	testing.expect(t, decimal < one, "by id 2.5 precedes 1")
	testing.expect(t, padded < one, "by id 007 precedes 1")
}

// And what the engine actually returns, which is SPARQL's order. The
// pair is the point: the order below is the requirement, the order above
// is what an ordered read would give, and they are unrelated.
@(test)
test_order_by_is_sparql_order_not_id_order :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "order-gap-eval") {return}
	if !test_db_load(t, &d, ORDER_GAP_FIXTURE) {return}

	rows, ok := test_solve(
		t,
		&d,
		`PREFIX : <http://example/> SELECT ?v WHERE { ?s :v ?v } ORDER BY ?v`,
		render_order_gap,
	)
	defer destroy_rows(&rows)
	if !ok {return}

	// 1 < 2.5 < 3 < 7 < 200000000 — by value, across the numeric tower,
	// with "007" compared as the integer seven.
	expected := []string{"1", "2.5", "3", "007", "200000000"}
	if !testing.expect_value(t, len(rows), len(expected)) {return}
	for want, i in expected {
		testing.expectf(t, rows[i] == want, "row %d: expected %q, got %q", i, want, rows[i])
	}
}

@(private = "file")
render_order_gap :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
	for id, slot in row {
		if id == UNBOUND || internal[slot] || names[slot] != "v" {
			continue
		}
		term := query_term(q, id)
		if lit, is_lit := term.(rdf.Literal); is_lit {
			// Cloned: `destroy_rows` owns every row, and the term's
			// lexical form borrows the query's materialization buffer.
			return strings.clone(lit.lexical)
		}
	}
	return strings.clone("?")
}
