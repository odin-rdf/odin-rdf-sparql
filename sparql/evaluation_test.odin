package sparql

// Evaluation end to end (SPARQL-I-0002): a join, a repeated variable
// within one pattern, an absent term, DISTINCT, and the solution
// modifiers — each against a real store rather than through the W3C
// harness, so that a failure names the property rather than a manifest
// entry.
//
// *(Moved into this package by SPARQL-T-0032, from `sparql/kvstore`.
// The fixture became a `Test_DB` over record's memory seam and the
// assertions did not change.)*

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

// Fixture: a small graph with a join, a repeated subject, and a term
// that no query below asks for, so an absent-term short-circuit has
// something to be distinguished from.
@(private = "file")
DATA :: `@prefix : <http://example/> .
:alice :knows :bob ; :name "Alice" .
:bob   :knows :carol ; :name "Bob" .
:carol :name "Carol" .
`

@(private = "file")
Fixture :: struct {
	db: Test_DB,
}

@(private = "file")
fixture_init :: proc(f: ^Fixture, t: ^testing.T, source := DATA, loc := #caller_location) {
	if !test_db_open(t, &f.db, "evaluation", loc = loc) {
		return
	}
	test_db_load(t, &f.db, source, nil, loc = loc)
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	test_db_close(&f.db)
}

// solve parses, translates, and evaluates a query, returning each
// solution as a list of "name=term" strings in slot order. Rendering to
// text keeps the assertions readable; the engine itself never leaves
// Term_IDs until the last step.
@(private = "file")
solve :: proc(
	t: ^testing.T,
	f: ^Fixture,
	query: string,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	return test_solve(t, &f.db, query, render_row, loc)
}

@(private = "file")
render_row :: proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string {
	b := strings.builder_make()
	for id, slot in row {
		if id == UNBOUND || internal[slot] {
			continue
		}
		strings.write_string(&b, names[slot])
		strings.write_byte(&b, '=')
		strings.write_string(&b, render(query_term(q, id)))
		strings.write_byte(&b, ' ')
	}
	return strings.to_string(b)
}

@(private = "file")
render :: proc(term: rdf.Term) -> string {
	switch v in term {
	case rdf.IRI:
		return string(v)
	case rdf.Blank_Node:
		return "_"
	case rdf.Literal:
		return v.lexical
	case ^rdf.Triple:
		return "<<triple>>"
	}
	return "?"
}

@(private = "file")
contains :: proc(rows: [dynamic]string, want: string) -> bool {
	for row in rows {
		if row == want {
			return true
		}
	}
	return false
}

@(test)
test_single_triple_pattern :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT * WHERE { :alice :knows ?who }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 1, "expected one solution, got %d: %v", len(rows), rows)
	testing.expectf(t, contains(rows, "who=http://example/bob "), "unexpected solutions: %v", rows)
}

@(test)
test_join_probes_the_second_pattern :: proc(t: ^testing.T) {
	// The second pattern's subject is bound by the first, so it is
	// matched by probe rather than by scanning and filtering. The
	// observable part is the answer; the mechanism is asserted by
	// test_probe_narrows_the_match below.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT * WHERE { ?a :knows ?b . ?b :name ?n }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 2, "expected two solutions, got %d: %v", len(rows), rows)
	testing.expectf(
		t,
		contains(rows, "a=http://example/alice b=http://example/bob n=Bob "),
		"missing the alice/bob solution: %v",
		rows,
	)
	testing.expectf(
		t,
		contains(rows, "a=http://example/bob b=http://example/carol n=Carol "),
		"missing the bob/carol solution: %v",
		rows,
	)
}

@(test)
test_repeated_variable_within_a_pattern :: proc(t: ^testing.T) {
	// `?x ?x ?y` can only match a quad whose subject and predicate are
	// the same term. The store matched two wildcards; unification is what
	// rejects the rest.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `SELECT * WHERE { ?x ?x ?y }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 0, "no quad has subject == predicate, got %v", rows)
}

@(test)
test_absent_ground_term_short_circuits :: proc(t: ^testing.T) {
	// A query naming a term the store has never seen cannot match. The
	// plan must collapse to nothing rather than scan — and, critically,
	// preparing the query must not have added the term to the dictionary.
	//
	// **Against odin-rdf-store this asserted a discipline; against record
	// it asserts an arithmetic.** kvstore had both `find_term` and
	// `intern_term`, and the term-binding bridge using the wrong one
	// would have turned every query into a write — so the old form of
	// this test called `find_term` before and after and checked the term
	// was still absent. record's read API has no interning verb at all:
	// `snapshot_resolve` cannot write, and a snapshot is a pinned index
	// set that could not observe a write if one happened. So the check
	// moved to the store's own term count, read through a fresh snapshot
	// taken after the query ran, which is the only thing that *could*
	// have moved.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	snap, pinned := test_db_snap(t, &f.db)
	if !pinned {
		return
	}
	absent := rdf.IRI("http://example/nobody")
	_, found_before := record.snapshot_resolve(snap, absent)
	testing.expect(t, !found_before, "the fixture should not contain :nobody")
	terms_before := record.snapshot_terms(snap)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT * WHERE { :nobody :knows ?who }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 0, "an absent subject cannot match, got %v", rows)

	after, after_err := record.store_latest(&f.db.db)
	testing.expectf(t, after_err == .None, "cannot pin a fresh snapshot: %v", after_err)
	if after_err != .None {
		return
	}
	defer record.snapshot_release(&after)
	_, found_after := record.snapshot_resolve(after, absent)
	testing.expect(t, !found_after, "preparing the query interned a term it only looked up")
	testing.expectf(
		t,
		record.snapshot_terms(after) == terms_before,
		"the dictionary grew from %d to %d terms while a query was prepared",
		terms_before,
		record.snapshot_terms(after),
	)
}

@(test)
test_projection_and_distinct :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	// Three subjects have a name; projecting away the name leaves three
	// distinct subjects, and projecting away the subject leaves three
	// distinct names.
	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT DISTINCT ?s WHERE { ?s :name ?n }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 3, "expected three subjects, got %d: %v", len(rows), rows)

	// Every solution must carry only the projected variable.
	for row in rows {
		testing.expectf(t, len(row) > 0, "projected solution is empty")
		testing.expectf(t, row[0] == 's', "projection leaked a variable: %q", row)
	}
}

@(test)
test_distinct_collapses_duplicates :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	// Two quads have :knows as predicate, so projecting to the predicate
	// alone yields a duplicate that DISTINCT must remove.
	all, ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?p WHERE { ?s :knows ?o . ?s ?p ?o }`)
	if !ok {
		return
	}
	defer destroy_rows(&all)
	deduped, deduped_ok := solve(t, &f, `PREFIX : <http://example/> SELECT DISTINCT ?p WHERE { ?s :knows ?o . ?s ?p ?o }`)
	if !deduped_ok {
		return
	}
	defer destroy_rows(&deduped)

	testing.expectf(t, len(all) == 2, "expected two solutions before DISTINCT, got %v", all)
	testing.expectf(t, len(deduped) == 1, "expected one solution after DISTINCT, got %v", deduped)
}

@(test)
test_limit_and_offset :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n } LIMIT 2`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 2, "LIMIT 2 should yield two solutions, got %d", len(rows))

	offset, offset_ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n } OFFSET 2`)
	if !offset_ok {
		return
	}
	defer destroy_rows(&offset)
	testing.expectf(t, len(offset) == 1, "OFFSET 2 should leave one solution, got %d", len(offset))
}

@(test)
test_blank_node_in_a_pattern_is_not_projected :: proc(t: ^testing.T) {
	// A blank node in a pattern matches like a variable but cannot be
	// named, so `SELECT *` must not report it.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT * WHERE { _:x :knows ?who }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 2, "expected two solutions, got %d: %v", len(rows), rows)
	for row in rows {
		testing.expectf(t, row[0] == 'w', "a blank-node slot was projected: %q", row)
	}
}

@(test)
test_filter_drops_non_matching_solutions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(
		t,
		&f,
		`PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(?n = "Bob") }`,
	)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 1, "expected one solution, got %d: %v", len(rows), rows)
	testing.expectf(t, contains(rows, "s=http://example/bob "), "unexpected solutions: %v", rows)
}

@(test)
test_filter_error_drops_the_solution :: proc(t: ^testing.T) {
	// `?n + 1` is a type error on a string. A type error is not false —
	// it propagates — but FILTER treats it the same way, so every
	// solution goes.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(?n + 1 > 0) }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 0, "a type error must drop every solution, got %v", rows)
}

@(test)
test_filter_or_recovers_from_an_error :: proc(t: ^testing.T) {
	// The three-valued rule that is easy to get wrong: `||` is true when
	// either side is true, even when the other side raised a type error.
	// A naive implementation propagates the error and returns nothing.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(
		t,
		&f,
		`PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(?n + 1 > 0 || ?n = "Bob") }`,
	)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 1, "|| should recover from the errored branch, got %v", rows)

	// …and `&&` is false when either side is false, likewise.
	nothing, nothing_ok := solve(
		t,
		&f,
		`PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(?n + 1 > 0 && ?n = "nobody") }`,
	)
	if !nothing_ok {
		return
	}
	defer destroy_rows(&nothing)
	testing.expectf(t, len(nothing) == 0, "&& with a false branch is false, got %v", nothing)
}

@(test)
test_filter_bound_and_unbound_variables :: proc(t: ^testing.T) {
	// A variable the pattern never mentions is unbound, not an error, so
	// BOUND can answer false about it — while using its value is an
	// error, which drops the row.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(!BOUND(?nowhere)) }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 3, "BOUND(?nowhere) is false, so all three pass: %v", rows)

	used, used_ok := solve(t, &f, `PREFIX : <http://example/> SELECT ?s WHERE { ?s :name ?n FILTER(?nowhere = 1) }`)
	if !used_ok {
		return
	}
	defer destroy_rows(&used)
	testing.expectf(t, len(used) == 0, "using an unbound variable is an error: %v", used)
}

@(test)
test_unsupported_expression_is_reported :: proc(t: ^testing.T) {
	// An expression the engine cannot evaluate must be named at
	// preparation, not answered with a type error at runtime — a filter
	// that silently matched nothing would look exactly like a correct
	// query with no results.
	//
	// LANGDIR is the stand-in: the SPARQL 1.2 grammar parses it and
	// SPARQL-T-0018 evaluates it, so today it is a built-in the engine
	// knows of and cannot run. (REGEX played this part until
	// SPARQL-T-0014 implemented it, which is the point — the list this
	// checks against is meant to shrink.)
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	snap, pinned := test_db_snap(t, &f.db)
	if !pinned {
		return
	}

	p: Parser
	parser_init(&p, transmute([]byte)string(`SELECT * WHERE { ?s ?p ?o FILTER(LANGDIR(?o) = "ltr") }`), TEST_BASE)
	defer parser_destroy(&p)
	_, parsed := parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := translate(&p)

	q: Query
	ok := query_init(&q, algebra, snap)
	defer query_destroy(&q)
	testing.expect(t, !ok, "REGEX is not implemented yet, so preparation must fail")
	testing.expectf(t, q.unsupported == "built-in function", "expected the built-in to be named, got %q", q.unsupported)
}
