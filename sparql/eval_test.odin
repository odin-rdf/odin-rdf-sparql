// The materialization contract at the answer boundary, and what a query
// asks of a store to prepare itself.
//
// *(Was `sparql/kvstore/eval_test.odin`, moved by SPARQL-T-0032. Its
// second test is gone and its first is narrower; both are explained
// below. The W3C evaluation suites run this engine end to end and are
// the verdict — what is here is what they cannot reach.)*
package sparql

import "core:testing"

import rdf "rdf:rdf"

@(private = "file")
DATA :: `@prefix : <http://example/> .
:alice :knows :bob .
:bob :knows :carol .
`

// Every ID a solution binds materializes back into a term the caller can
// read, and the terms stay readable for the query's whole life rather
// than only until the next pull.
//
// **That second half is the part worth a test.** `record.snapshot_term`
// borrows the dictionary arena for most kinds and owns for two
// (RECORD-A-0008), so "valid until query_destroy" is a promise the Query
// keeps by remembering every id it decoded and releasing each through
// record's own verb. Holding the first solution's terms across the
// second pull is what would catch a Query that freed as it went.
@(test)
test_materialized_terms_live_until_query_destroy :: proc(t: ^testing.T) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "materialize") {
		return
	}
	if !test_db_load(t, &d, DATA) {
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		return
	}

	p: Parser
	parser_init(&p, transmute([]byte)string(`PREFIX : <http://example/> SELECT * WHERE { ?a :knows ?b }`))
	defer parser_destroy(&p)
	_, parsed := parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, snap, parser_base(&p)), "query not supported: %s", q.unsupported) {
		return
	}

	names := query_var_names(&q)
	held: [dynamic]rdf.Term
	defer delete(held)
	solutions := 0
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		solutions += 1
		for id, slot in row {
			if id == UNBOUND {
				continue
			}
			term := query_term(&q, id)
			iri, is_iri := term.(rdf.IRI)
			testing.expectf(t, is_iri, "%s should be bound to an IRI", names[slot])
			testing.expectf(t, iri != "", "%s materialized to an empty IRI", names[slot])
			append(&held, term)
		}
	}
	testing.expectf(t, solutions == 2, "expected two solutions, got %d", solutions)

	// Every term from every solution, still readable after the run ended.
	// A Query that released as it went would be reading freed memory
	// here, which the test runner's allocator sees.
	testing.expectf(t, len(held) == 4, "expected four bindings, got %d", len(held))
	for term in held {
		iri, is_iri := term.(rdf.IRI)
		testing.expect(t, is_iri && len(iri) > len("http://example/"), "a term did not survive the run")
	}
}

// **`test_kvstore_query_setup_does_not_write` is deleted, not ported.**
//
// It closed a store, reopened the same path with `read_only = true`, and
// prepared a query against it — the sharpest way to assert STORE-T-0014's
// point, that the term-binding bridge uses `find_term` and not
// `intern_term`, because a query that interned would fail outright
// against a read-only open.
//
// There is nothing left to assert that way. record has no read-only open
// and no path to reopen (the suites run over the memory seam), and more
// to the point its read API has no interning verb at all: `query_init`
// resolves through `snapshot_resolve`, which cannot write, and against an
// immutable published index set which could not observe a write if one
// happened. The property survives as arithmetic instead — see
// `test_absent_ground_term_short_circuits` in `evaluation_test.odin`,
// which reads the store's term count through a fresh snapshot taken after
// the query ran and requires it not to have moved.
