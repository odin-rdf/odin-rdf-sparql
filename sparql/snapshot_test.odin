// A query is one snapshot (SPARQL-T-0024).
//
// **The W3C suites cannot produce these.** They are single-threaded, so
// nothing in them ever commits while a query is running, and the engine
// answered correctly for 483 evaluation entries without holding a
// snapshot at all. What broke was never observable there — it becomes
// observable the moment anything writes to a store a query is reading,
// and the family's deployment shape makes that a question of when. So
// these are written on purpose rather than derived from a suite, and each
// asserts something a per-operation-read engine would get wrong.
//
// *(Rewritten by SPARQL-T-0032, from `sparql/kvstore/snapshot_test.odin`.
// The property is unchanged; almost everything around it went. There is
// no transaction, no reader table and no NOLOCK caveat — the old file's
// longest comment was an argument for why every store in it had to be
// `kvstore.open` rather than `open_ephemeral`, and record's snapshots are
// refcounted index sets with no such hazard. Two of the five tests
// changed subject and one is gone; each says so where it stands.)*
package sparql

import "base:runtime"

import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

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
// A single-pattern query would pass without any of this code: one scan
// opened before a commit is a window over the index set it was made from
// and already ignores that commit. What has no protection is the *second*
// read — the inner pattern reopens once per outer solution, so an inner
// scan opened after the commit would see it if the executor asked the
// store rather than the snapshot. Here the outer pattern yields
// `bob :knows :carol` from the pre-commit dataset, and the inner lookup
// for `:carol :knows ?c` is the read that lands after the write.
@(private = "file")
JOIN_QUERY :: `PREFIX : <http://example/> SELECT ?a ?b ?c WHERE { ?a :knows ?b . ?b :knows ?c }`

// solution_text renders one row as "a b", so a set of solutions compares
// as strings rather than as IDs — IDs are stable here, but an assertion
// that reads like the data is worth more when it fails.
@(private = "file")
solution_text :: proc(q: ^Query, row: []record.Term_ID) -> string {
	sb := strings.builder_make()
	for id, slot in row {
		if slot > 0 {
			strings.write_byte(&sb, ' ')
		}
		if id == UNBOUND {
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

// prepare parses, translates and prepares one query against a snapshot,
// returning false with the reason already reported. The parser has to
// outlive the Query — the algebra belongs to it — so the caller owns
// both.
@(private = "file")
prepare :: proc(t: ^testing.T, q: ^Query, p: ^Parser, snap: record.Snapshot, text: string) -> bool {
	parser_init(p, transmute([]byte)text)
	_, parsed := parse(p)
	if !testing.expect(t, parsed, "the query should parse") {
		return false
	}
	algebra, _ := translate(p)
	return testing.expectf(t, query_init(q, algebra, snap, parser_base(p)), "query not supported: %s", q.unsupported)
}

@(private = "file")
destroy_lines :: proc(lines: ^[dynamic]string) {
	for line in lines {
		delete(line)
	}
	delete(lines^)
}

// The item's own acceptance criterion: drain part of a query, commit a
// write, and the rest of the query must still be answering about the
// dataset it started on.
@(test)
test_a_query_answers_about_the_dataset_it_started_on :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "snapshot") {
		return
	}
	if !test_db_load(t, &d, SNAPSHOT_DATA) {
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		return
	}

	p: Parser
	defer parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(t, &q, &p, snap, JOIN_QUERY) {
		return
	}

	got: [dynamic]string
	defer destroy_lines(&got)

	// One solution, then the write. Draining the first is what makes this
	// a test of the snapshot rather than of query_init: the query is
	// mid-run and has open scans when the commit lands.
	row, more := query_next(&q)
	if !testing.expect(t, more, "the query should have a first solution") {
		return
	}
	append(&got, solution_text(&q, row))

	// An ordinary commit through the same store. record publishes a new
	// index set for it; this query's snapshot still holds the old one, and
	// a per-operation-read engine would start seeing the new.
	if !test_db_load(t, &d, LATER_WRITE) {
		return
	}

	for {
		next, ok := query_next(&q)
		if !ok {
			break
		}
		append(&got, solution_text(&q, next))
	}

	joined := strings.join(got[:], "; ", context.temp_allocator)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == "alice bob carol",
		"the query saw the later commit: expected `alice bob carol`, got `%s`",
		joined,
	)

	// And the store itself does have the second solution — otherwise the
	// assertion above would hold for the wrong reason, and this test would
	// pass against a dataset where the write simply had no effect.
	after_snap, after_err := record.store_latest(&d.db)
	if !testing.expectf(t, after_err == .None, "cannot pin the post-write head: %v", after_err) {
		return
	}
	defer record.snapshot_release(&after_snap)

	p2: Parser
	defer parser_destroy(&p2)
	q2: Query
	defer query_destroy(&q2)
	if !prepare(t, &q2, &p2, after_snap, JOIN_QUERY) {
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

// The dictionary half, and the one that stops a query half-seeing a
// write: a term interned by a later commit must not resolve through this
// query's snapshot. If it did, a ground term could bind to an ID whose
// quads the snapshot cannot see — a solution assembled from two datasets.
//
// record makes this a bound rather than a discipline: an index set
// carries the term count it published with, and `snapshot_resolve` refuses
// anything past it. The assertion is the same either way.
@(test)
test_a_term_interned_after_query_init_is_invisible :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "snapshot-dict") {
		return
	}
	if !test_db_load(t, &d, SNAPSHOT_DATA) {
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		return
	}

	p: Parser
	defer parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(t, &q, &p, snap, KNOWS_QUERY) {
		return
	}

	dave := rdf.Term(rdf.IRI("http://example/dave"))
	if _, found := query_find(&q, dave); !testing.expect(t, !found, ":dave should not exist yet") {
		return
	}

	if !test_db_load(t, &d, LATER_WRITE) {
		return
	}

	_, found := query_find(&q, dave)
	testing.expect(t, !found, ":dave was interned after this query's snapshot and must not resolve through it")

	// The term is genuinely there — the snapshot is what is hiding it.
	after_snap, after_err := record.store_latest(&d.db)
	if !testing.expectf(t, after_err == .None, "cannot pin the post-write head: %v", after_err) {
		return
	}
	defer record.snapshot_release(&after_snap)
	_, present := record.snapshot_resolve(after_snap, dave)
	testing.expect(t, present, ":dave should exist in the store the write committed to")
}

// **The test `query_init_txn` existed for, answered by the thing that
// replaced it.**
//
// Against odin-rdf-store this was `test_query_init_txn_sees_the_callers_
// uncommitted_write`: a query prepared inside a caller's *write*
// transaction, so that a consumer deciding whether a candidate may join
// the dataset could see the candidate. SPARQL-T-0031 deleted that
// constructor on the argument that record's validation hook serves the
// same consumer better — the hook is handed the dataset the write *would*
// produce, as an ordinary snapshot at the epoch it would commit at, so
// querying a candidate is the ordinary call and not a second entry point.
//
// This is that argument under test. The validator below runs a real query
// against the candidate and counts its solutions; the same query against
// the committed head, at the same instant, counts two. It also pins the
// half that makes the hook usable at all: **the candidate snapshot is
// borrowed and `query_destroy` does not release it**, which is why
// `query_init` takes a snapshot it does not own.
@(private = "file")
Candidate_Probe :: struct {
	t:     ^testing.T,
	// One entry per candidate judged. The fixture's own commit is judged
	// too — the hook is wired at open, which is record's contract — so
	// the test reads the last, not the only.
	seen:  [dynamic]int,
}

@(private = "file")
probe_candidate :: proc(
	data: rawptr,
	candidate: record.Snapshot,
	ops: []record.Resident_Op,
	allocator: runtime.Allocator,
) -> bool {
	probe := cast(^Candidate_Probe)data
	_ = ops
	_ = allocator

	p: Parser
	defer parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(probe.t, &q, &p, candidate, KNOWS_QUERY) {
		append(&probe.seen, -1)
		return true
	}
	n := 0
	for {
		_, ok := query_next(&q)
		if !ok {
			break
		}
		n += 1
	}
	append(&probe.seen, n)
	// `query_destroy` runs on the way out of this procedure and must not
	// have released the candidate: record releases it itself, and a
	// double release would fail record's own assertion on the next use.
	return true
}

@(test)
test_a_validator_candidate_is_an_ordinary_snapshot :: proc(t: ^testing.T) {
	probe := Candidate_Probe {
		t    = t,
		seen = make([dynamic]int),
	}
	defer delete(probe.seen)

	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "candidate", record.Validator{check = probe_candidate, data = &probe}) {
		return
	}
	if !test_db_load(t, &d, SNAPSHOT_DATA) {
		return
	}
	if !test_db_load(t, &d, LATER_WRITE) {
		return
	}

	if !testing.expectf(t, len(probe.seen) == 2, "the validator should judge both commits, judged %d", len(probe.seen)) {
		return
	}
	// The fixture's candidate has the two triples the fixture adds; the
	// second candidate has those plus the one the later write carries —
	// **before it is committed**, which is the whole point.
	testing.expectf(t, probe.seen[0] == 2, "the first candidate should have two solutions, got %d", probe.seen[0])
	testing.expectf(
		t,
		probe.seen[1] == 3,
		"a query over the candidate must see the write it carries: got %d solutions",
		probe.seen[1],
	)

	// And the head, after the commit, agrees — so the three above was the
	// candidate and not a miscount.
	head, head_err := record.store_latest(&d.db)
	if !testing.expectf(t, head_err == .None, "cannot pin the head: %v", head_err) {
		return
	}
	defer record.snapshot_release(&head)
	p: Parser
	defer parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	if !prepare(t, &q, &p, head, KNOWS_QUERY) {
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
	testing.expectf(t, n == 3, "the committed head should have three solutions, got %d", n)
}

// **`test_queries_do_not_exhaust_the_reader_table` is deleted, not
// ported.** It ran 300 queries past LMDB's 126-slot reader table to prove
// that `query_destroy` ended what `query_init` began — a leaked read
// transaction failed on the 127th query afterwards rather than on the one
// that leaked it, which is the kind of bug that reaches production.
// record has no such table and no such failure mode: a snapshot is a
// refcount on an index set, there is no bound to exhaust, and since
// SPARQL-T-0031 the query does not acquire or release one at all — the
// caller does. There is nothing left for the test to be about. Recorded
// here rather than dropped silently.

// The failure path, and without calling query_destroy at all: a
// query_init that returns false must leave nothing behind on its own. An
// extension function is the cheapest algebra this engine declines to
// plan.
//
// *(This was `test_a_failed_query_init_leaves_no_transaction`, and it
// proved the transaction was ended. There is no transaction; what is left
// is the stronger property, that the failed init freed its slot table,
// its builder and any EXISTS sub-plan it had already built. The leak
// checker is the assertion — 300 iterations so that a per-init leak is
// unmissable rather than a rounding error.)*
@(test)
test_a_failed_query_init_leaks_nothing :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "failed-init") {
		return
	}
	if !test_db_load(t, &d, SNAPSHOT_DATA) {
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		return
	}

	UNSUPPORTED :: `PREFIX : <http://example/>
SELECT * WHERE { ?a :knows ?b FILTER(<http://example/f>(?a)) }`

	for _ in 0 ..< 300 {
		p: Parser
		parser_init(&p, transmute([]byte)string(UNSUPPORTED))
		_, parsed := parse(&p)
		if !testing.expect(t, parsed, "the fixture query should parse") {
			parser_destroy(&p)
			return
		}
		algebra, _ := translate(&p)

		q: Query
		ok := query_init(&q, algebra, snap, parser_base(&p))
		if !testing.expectf(t, !ok, "the fixture query should not be supported") {
			query_destroy(&q)
			parser_destroy(&p)
			return
		}
		testing.expect(t, q.unsupported != "", "a failed init should name what it could not plan")
		// Deliberately no query_destroy: the point is that query_init
		// cleaned up after itself.
		parser_destroy(&p)
	}

	// And one that must still start afterwards.
	p: Parser
	defer parser_destroy(&p)
	q: Query
	defer query_destroy(&q)
	testing.expect(t, prepare(t, &q, &p, snap, KNOWS_QUERY), "a query after 300 failed inits must still start")
}
