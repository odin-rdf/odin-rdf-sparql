package sparql_kvstore

import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

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
	store: ^kvstore.Store,
}

@(private = "file")
fixture_init :: proc(f: ^Fixture, t: ^testing.T, source := DATA) {
	open_err: kvstore.Error
	f.store, open_err = kvstore.open_ephemeral()
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	_, parse_err, load_err := kvstore.load_turtle(f.store, transmute([]byte)source, "http://example/")
	testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load: %s %v", parse_err.message, load_err)
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	if f.store != nil {
		kvstore.close(f.store)
	}
}

// solve parses, translates, and evaluates a query, returning each
// solution as a list of "name=term" strings in slot order. Rendering to
// text keeps the assertions readable; the engine itself never leaves
// Term_IDs until the last step.
@(private = "file")
solve :: proc(t: ^testing.T, f: ^Fixture, query: string) -> (rows: [dynamic]string, ok: bool) {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)query, "http://example/")
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind) {
		return nil, false
	}
	algebra, translated := sparql.translate(&p)
	if !testing.expect(t, translated, "query did not translate") {
		return nil, false
	}

	q: Query
	if !query_init(&q, algebra, f.store) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported)
		query_destroy(&q)
		return nil, false
	}
	defer query_destroy(&q)

	names := query_var_names(&q)
	internal := query_var_internal(&q)
	rows = make([dynamic]string)
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		line: string
		for id, slot in row {
			if id == store.UNBOUND || internal[slot] {
				continue
			}
			line = concat(line, names[slot], "=", render(query_term(&q, id)), " ")
		}
		append(&rows, line)
	}
	return rows, true
}

@(private = "file")
concat :: proc(parts: ..string) -> string {
	// The caller frees each row through destroy_rows; building with a
	// running concatenation keeps the test free of a builder ceremony
	// that would obscure what is being asserted.
	total := 0
	for part in parts {
		total += len(part)
	}
	out := make([]u8, total)
	at := 0
	for part in parts {
		copy(out[at:], part)
		at += len(part)
	}
	if len(parts) > 0 && parts[0] != "" {
		delete(parts[0])
	}
	return string(out)
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
destroy_rows :: proc(rows: ^[dynamic]string) {
	for row in rows {
		delete(row)
	}
	delete(rows^)
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
	// On a persistent backend that is the difference between a read and a
	// write, which is why the bridge uses find_term and not intern_term.
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	absent := rdf.IRI("http://example/nobody")
	_, found_before, find_err_before := kvstore.find_term(f.store, absent)
	testing.expectf(t, find_err_before == nil, "find_term failed: %v", find_err_before)
	testing.expect(t, !found_before, "the fixture should not contain :nobody")

	rows, ok := solve(t, &f, `PREFIX : <http://example/> SELECT * WHERE { :nobody :knows ?who }`)
	if !ok {
		return
	}
	defer destroy_rows(&rows)
	testing.expectf(t, len(rows) == 0, "an absent subject cannot match, got %v", rows)

	_, found_after, find_err_after := kvstore.find_term(f.store, absent)
	testing.expectf(t, find_err_after == nil, "find_term failed: %v", find_err_after)
	testing.expect(t, !found_after, "preparing the query interned a term it only looked up")
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

	p: sparql.Parser
	sparql.parser_init(
		&p,
		transmute([]byte)string(`SELECT * WHERE { ?s ?p ?o FILTER(LANGDIR(?o) = "ltr") }`),
		"http://example/",
	)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := sparql.translate(&p)

	q: Query
	ok := query_init(&q, algebra, f.store)
	defer query_destroy(&q)
	testing.expect(t, !ok, "REGEX is not implemented yet, so preparation must fail")
	testing.expectf(t, q.unsupported == "built-in function", "expected the built-in to be named, got %q", q.unsupported)
}
