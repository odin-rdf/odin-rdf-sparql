package sparql_kvstore

import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

// A query is one snapshot (SPARQL-T-0024).
//
// **The W3C suites cannot produce these.** They are single-threaded, so
// nothing in them ever commits while a query is running, and the engine
// answered correctly for 483 evaluation entries without holding a
// transaction at all. What broke was never observable there — it becomes
// observable the moment anything writes to a store a query is reading, and
// the family's deployment shape makes that a question of when. So these are
// written on purpose rather than derived from a suite, and each one asserts
// something a per-operation-read engine would get wrong.

@(private = "file")
SNAPSHOT_DATA :: `@prefix : <http://example/> .
:alice :knows :bob .
:bob :knows :carol .
`

// The write that lands mid-query. It introduces a subject, an object, and
// therefore a term the dictionary has never seen.
@(private = "file")
LATER_WRITE :: `@prefix : <http://example/> .
:carol :knows :dave .
`

@(private = "file")
KNOWS_QUERY :: `PREFIX : <http://example/> SELECT ?a ?b WHERE { ?a :knows ?b }`

// A join, and it has to be a join to test anything.
//
// A single-pattern query would pass without any of this code: `match` hands
// its iterator a transaction of its own, so one iterator opened before a
// commit already ignores that commit. What has no protection is the *second*
// read — the inner pattern reopens once per outer solution, so an inner
// iterator opened after the commit would see it. Here the outer pattern
// yields `bob :knows :carol` from the pre-commit dataset, and the inner
// lookup for `:carol :knows ?c` is the read that lands after the write.
@(private = "file")
JOIN_QUERY :: `PREFIX : <http://example/> SELECT ?a ?b ?c WHERE { ?a :knows ?b . ?b :knows ?c }`

// solution_text renders one row as "a b", so a set of solutions compares as
// strings rather than as IDs — IDs are stable here, but an assertion that
// reads like the data is worth more when it fails.
@(private = "file")
solution_text :: proc(q: ^Query, row: []store.Term_ID) -> string {
	sb := strings.builder_make()
	for id, slot in row {
		if slot > 0 {
			strings.write_byte(&sb, ' ')
		}
		if id == store.UNBOUND {
			strings.write_string(&sb, "?")
			continue
		}
		term := query_term(q, id)
		if iri, is_iri := term.(rdf.IRI); is_iri {
			strings.write_string(&sb, local(string(iri)))
		} else {
			strings.write_string(&sb, "<not an IRI>")
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
local :: proc(iri: string) -> string {
	if i := strings.last_index_any(iri, "#/"); i >= 0 {
		return iri[i + 1:]
	}
	return iri
}

// prepare parses, translates and prepares one query, returning false with
// the reason already reported. The parser has to outlive the Query — the
// algebra belongs to it — so the caller owns both.
@(private = "file")
prepare :: proc(t: ^testing.T, q: ^Query, p: ^sparql.Parser, s: ^kvstore.Store, text: string) -> bool {
	sparql.parser_init(p, transmute([]byte)text)
	_, parsed := sparql.parse(p)
	if !testing.expect(t, parsed, "the query should parse") {
		return false
	}
	algebra, _ := sparql.translate(p)
	return testing.expectf(t, query_init(q, algebra, s, sparql.parser_base(p)), "query not supported: %s", q.unsupported)
}

// The item's own acceptance criterion: drain part of a query, commit a
// write, and the rest of the query must still be answering about the
// dataset it started on.
@(test)
test_a_query_answers_about_the_dataset_it_started_on :: proc(t: ^testing.T) {
	path := scratch_path("snapshot")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(SNAPSHOT_DATA), "http://example/")
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load: %s %v", parse_err.message, load_err) {
		return
	}

	p: sparql.Parser
	defer sparql.parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(t, &q, &p, s, JOIN_QUERY) {
		return
	}

	got: [dynamic]string
	defer {
		for line in got {
			delete(line)
		}
		delete(got)
	}

	// One solution, then the write. Draining the first is what makes this a
	// test of the snapshot rather than of query_init: the query is mid-run
	// and has open cursors when the commit lands.
	row, more := query_next(&q)
	if !testing.expect(t, more, "the query should have a first solution") {
		return
	}
	append(&got, solution_text(&q, row))

	// An ordinary autocommit write through the same handle. It is not
	// refused — only a second *write* transaction would be — so this
	// commits, and a per-operation-read engine would start seeing it.
	_, w_parse, w_err := kvstore.load_turtle(s, transmute([]byte)string(LATER_WRITE), "http://example/")
	if !testing.expectf(t, w_parse.message == "" && w_err == nil, "the later write failed: %s %v", w_parse.message, w_err) {
		return
	}

	for {
		next, ok := query_next(&q)
		if !ok {
			break
		}
		append(&got, solution_text(&q, next))
	}
	testing.expectf(t, query_error(&q) == nil, "the store reported an error: %v", query_error(&q))

	slice.sort(got[:])
	joined := strings.join(got[:], ", ", context.temp_allocator)
	testing.expectf(
		t,
		joined == "alice bob carol",
		"the query saw the later commit: expected `alice bob carol`, got `%s`",
		joined,
	)

	// And the store itself does have the second solution — otherwise the
	// assertion above would hold for the wrong reason, and this test would
	// pass against a dataset where the write simply had no effect.
	p2: sparql.Parser
	defer sparql.parser_destroy(&p2)
	q2: Query
	defer query_destroy(&q2)
	if !prepare(t, &q2, &p2, s, JOIN_QUERY) {
		return
	}
	after := 0
	for {
		_, ok := query_next(&q2)
		if !ok {
			break
		}
		after += 1
	}
	testing.expectf(t, after == 2, "a query started after the write should see two solutions, got %d", after)
}

// The dictionary half, and the one that stops a query half-seeing a write:
// a term interned by a later commit must not resolve through this query's
// snapshot. If it did, a ground term could bind to an ID whose quads the
// snapshot cannot see — a solution assembled from two datasets.
@(test)
test_a_term_interned_after_query_init_is_invisible :: proc(t: ^testing.T) {
	path := scratch_path("snapshot-dict")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(SNAPSHOT_DATA), "http://example/")
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load") {
		return
	}

	p: sparql.Parser
	defer sparql.parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(t, &q, &p, s, KNOWS_QUERY) {
		return
	}

	dave := rdf.Term(rdf.IRI("http://example/dave"))
	if _, found := query_find(&q, dave); !testing.expect(t, !found, ":dave should not exist yet") {
		return
	}

	_, w_parse, w_err := kvstore.load_turtle(s, transmute([]byte)string(LATER_WRITE), "http://example/")
	if !testing.expectf(t, w_parse.message == "" && w_err == nil, "the later write failed: %s %v", w_parse.message, w_err) {
		return
	}

	_, found := query_find(&q, dave)
	testing.expect(t, !found, ":dave was interned after this query's snapshot and must not resolve through it")
	testing.expectf(t, query_error(&q) == nil, "the store reported an error: %v", query_error(&q))

	// The term is genuinely there — the snapshot is what is hiding it.
	_, present, find_err := kvstore.find_term(s, dave)
	testing.expectf(t, find_err == nil, "find_term failed: %v", find_err)
	testing.expect(t, present, ":dave should exist in the store the write committed to")
}

// query_init_txn: a query inside a write transaction the caller holds,
// which is what a consumer deciding whether a candidate may join the
// dataset needs. The same store at the same instant answers two ways.
@(test)
test_query_init_txn_sees_the_callers_uncommitted_write :: proc(t: ^testing.T) {
	path := scratch_path("snapshot-txn")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(SNAPSHOT_DATA), "http://example/")
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load") {
		return
	}

	tx, txn_err := kvstore.txn_begin(s, .Write)
	if !testing.expectf(t, txn_err == nil, "txn_begin: %v", txn_err) {
		return
	}
	defer kvstore.txn_abort(&tx)

	_, c_parse, c_err := kvstore.load_turtle_txn(&tx, transmute([]byte)string(LATER_WRITE), "http://example/")
	if !testing.expectf(t, c_parse.message == "" && c_err == nil, "the candidate failed to load: %s %v", c_parse.message, c_err) {
		return
	}

	// Through the caller's write transaction: the candidate is visible.
	{
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)string(KNOWS_QUERY))
		defer sparql.parser_destroy(&p)
		_, parsed := sparql.parse(&p)
		testing.expect(t, parsed, "the query should parse")
		algebra, _ := sparql.translate(&p)

		q: Query
		defer query_destroy(&q)
		if !testing.expectf(t, query_init_txn(&q, algebra, &tx, sparql.parser_base(&p)), "not supported: %s", q.unsupported) {
			return
		}
		n := 0
		for {
			_, ok := query_next(&q)
			if !ok {
				break
			}
			n += 1
		}
		testing.expectf(t, n == 3, "a query inside the write transaction must see the candidate: got %d solutions", n)
		testing.expectf(t, query_error(&q) == nil, "store error: %v", query_error(&q))
	}

	// And an ordinary query, at the same instant, is not refused and does
	// not see it — it takes a read transaction of its own and answers about
	// the committed dataset. A caller that reaches for the wrong constructor
	// gets an answer, not a diagnostic.
	{
		p: sparql.Parser
		defer sparql.parser_destroy(&p)
		q: Query
		defer query_destroy(&q)
		if !prepare(t, &q, &p, s, KNOWS_QUERY) {
			return
		}
		n := 0
		for {
			_, ok := query_next(&q)
			if !ok {
				break
			}
			n += 1
		}
		testing.expectf(t, n == 2, "a query outside the transaction must not see the candidate: got %d solutions", n)
	}
}

// The lifetime, asserted the only way it can be observed from here.
//
// LMDB's reader table is finite — DEFAULT_OPTIONS carries 126 slots — and a
// read transaction holds one until it ends. So a query that leaked its
// snapshot would not fail on the query that leaked it; it would fail on the
// 127th query afterwards, which is the kind of bug that reaches production.
// Running well past that bound is what proves query_destroy ends what
// query_init began.
@(test)
test_queries_do_not_exhaust_the_reader_table :: proc(t: ^testing.T) {
	path := scratch_path("snapshot-readers")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(SNAPSHOT_DATA), "http://example/")
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load") {
		return
	}

	// Comfortably past DEFAULT_OPTIONS.max_readers.
	for i in 0 ..< 300 {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)string(KNOWS_QUERY))
		_, parsed := sparql.parse(&p)
		algebra, _ := sparql.translate(&p)

		q: Query
		ok := query_init(&q, algebra, s, sparql.parser_base(&p))
		if !ok || !parsed {
			testing.expectf(t, false, "query %d could not be prepared: %v", i, query_error(&q))
			query_destroy(&q)
			sparql.parser_destroy(&p)
			return
		}
		for {
			_, more := query_next(&q)
			if !more {
				break
			}
		}
		failure := query_error(&q)
		query_destroy(&q)
		sparql.parser_destroy(&p)
		if !testing.expectf(t, failure == nil, "query %d failed: %v", i, failure) {
			return
		}
	}
}

// The same bound, against the failure path, and without calling
// query_destroy at all: a query_init that returns false must leave no
// transaction behind on its own. An extension function is the cheapest
// algebra this engine declines to plan.
@(test)
test_a_failed_query_init_leaves_no_transaction :: proc(t: ^testing.T) {
	path := scratch_path("snapshot-failed-init")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(SNAPSHOT_DATA), "http://example/")
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load") {
		return
	}

	UNSUPPORTED :: `PREFIX : <http://example/>
SELECT * WHERE { ?a :knows ?b FILTER(<http://example/f>(?a)) }`

	for i in 0 ..< 300 {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)string(UNSUPPORTED))
		_, parsed := sparql.parse(&p)
		if !testing.expect(t, parsed, "the fixture query should parse") {
			sparql.parser_destroy(&p)
			return
		}
		algebra, _ := sparql.translate(&p)

		q: Query
		ok := query_init(&q, algebra, s, sparql.parser_base(&p))
		if !testing.expectf(t, !ok, "the fixture query should not be supported") {
			query_destroy(&q)
			sparql.parser_destroy(&p)
			return
		}
		// Deliberately no query_destroy: the point is that query_init
		// cleaned up after itself.
		sparql.parser_destroy(&p)
		_ = i
	}

	// If those 300 leaked, this one cannot start.
	p: sparql.Parser
	defer sparql.parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	testing.expect(t, prepare(t, &q, &p, s, KNOWS_QUERY), "a query after 300 failed inits must still start")
}
