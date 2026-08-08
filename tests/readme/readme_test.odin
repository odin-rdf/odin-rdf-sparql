// The README quick-start examples, compiled and asserted here so the
// documentation cannot drift from the real API (the family's
// README-as-contract pattern, SPARQL-T-0009 for the parser half,
// SPARQL-T-0019 for the evaluation half).
package readme

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

import "rdf:rdf"
import "store:store"
import "store:store/kvstore"

import "../../sparql"
// Aliased because an unaliased import takes the last path segment, and
// odin-rdf-store's backend package is also called kvstore.
import sparql_kvstore "../../sparql/kvstore"

QUERY :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT ?name WHERE {
	?person a foaf:Person ; foaf:name ?name .
	FILTER(STRLEN(?name) > 0)
}
ORDER BY ?name LIMIT 10
`

@(test)
readme_quick_start :: proc(t: ^testing.T) {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(QUERY))
	defer sparql.parser_destroy(&p)

	query, ok := sparql.parse(&p)
	if !testing.expectf(
		t,
		ok,
		"parse error at line %d, column %d: %s",
		p.err.line,
		p.err.column,
		sparql.error_message(p.err.kind),
	) {
		return
	}
	testing.expect_value(t, query.form, sparql.Query_Form.Select)
	testing.expect_value(t, query.limit, 10)

	algebra, translate_ok := sparql.translate(&p)
	testing.expect(t, translate_ok)
	sse := sparql.algebra_to_string(algebra)
	defer delete(sse)

	// The README shows this operator stack (with IRIs elided there).
	testing.expect(t, strings.has_prefix(sse, "(slice _ 10\n  (project (?name)\n    (order (?name)\n      (filter (> (strlen ?name) 0)\n        (bgp"))
}

DATA :: `@prefix foaf: <http://xmlns.com/foaf/0.1/> .
<http://example/alice> a foaf:Person ; foaf:name "Alice" ; foaf:knows <http://example/bob> .
<http://example/bob>   a foaf:Person ; foaf:name "Bob" .
`

FRIENDS :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT ?name ?friend WHERE {
	?person a foaf:Person ; foaf:name ?name .
	OPTIONAL { ?person foaf:knows ?other . ?other foaf:name ?friend }
}
ORDER BY ?name
`

// A throwaway database directory, and its cleanup. The README shows
// kvstore.open against a path the reader chooses; this is only how the
// test picks one it can delete afterwards.
@(private = "file")
scratch_counter: u64

@(private = "file")
scratch_path :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = os.get_env("TEMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = os.get_env("TMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = "/tmp"
	}
	// The counter, not the pid, is what separates two tests in one run: the
	// runner is threaded, and this package now has more than one test that
	// opens a store.
	n := sync.atomic_add(&scratch_counter, 1)
	return fmt.aprintf("%s/odin-sparql-readme-%d-%d", strings.trim_right(tmp, `/\`), os.get_pid(), n)
}

@(private = "file")
remove_scratch :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}

@(test)
readme_evaluation :: proc(t: ^testing.T) {
	// The store is a directory on disk. This one is scratch, so it is
	// removed at the end; a real one is opened once and kept.
	path := scratch_path()
	defer remove_scratch(path)
	db, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "the store should open: %v", open_err) {
		return
	}
	defer kvstore.close(db)
	_, load_err, db_err := kvstore.load_turtle(
		db,
		transmute([]byte)string(DATA),
		"http://example/",
	)
	if !testing.expectf(t, load_err.message == "" && db_err == nil, "data did not load: %s %v", load_err.message, db_err) {
		return
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p) // the parser owns the algebra
	if _, parsed := sparql.parse(&p); !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, translated := sparql.translate(&p)
	if !testing.expect(t, translated, "the query should translate") {
		return
	}

	// A prepared query borrows the algebra, so the parser outlives it.
	q: sparql_kvstore.Query
	defer sparql_kvstore.query_destroy(&q)
	if !sparql_kvstore.query_init(&q, algebra, db, sparql.parser_base(&p)) {
		testing.expectf(t, false, "unsupported: %s", q.unsupported)
		return
	}

	answer := strings.builder_make()
	defer strings.builder_destroy(&answer)
	names := sparql_kvstore.query_var_names(&q)
	internal := sparql_kvstore.query_var_internal(&q)
	for {
		// A row is Term_IDs indexed by variable slot, valid until the
		// next pull. Deep-copy it if you keep it.
		row, more := sparql_kvstore.query_next(&q)
		if !more {
			break
		}
		for id, slot in row {
			if id == store.UNBOUND || internal[slot] {
				continue // unbound, or a pattern blank node
			}
			#partial switch term in sparql_kvstore.query_term(&q, id) {
			case rdf.IRI:
				fmt.sbprintf(&answer, "?%s=<%s> ", names[slot], string(term))
			case rdf.Literal:
				fmt.sbprintf(&answer, "?%s=%q ", names[slot], term.lexical)
			}
		}
		strings.write_byte(&answer, '\n')
	}

	// The README shows this answer (as two `fmt.printf` lines).
	testing.expect_value(t, strings.to_string(answer), "?name=\"Alice\" ?friend=\"Bob\" \n?name=\"Bob\" \n")
}

// The README's third example: a query inside a write transaction the caller
// holds, so it sees the candidate that transaction carries (SPARQL-T-0024).
// The snippet in the README is this body from `txn_begin` to `query_init_txn`,
// with the counting below standing in for whatever the caller does with the
// answer.
CANDIDATE :: `@prefix foaf: <http://xmlns.com/foaf/0.1/> .
<http://example/carol> a foaf:Person ; foaf:name "Carol" .
`

@(test)
readme_query_inside_a_write_transaction :: proc(t: ^testing.T) {
	path := scratch_path()
	defer remove_scratch(path)
	db, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "the store should open: %v", open_err) {
		return
	}
	defer kvstore.close(db)
	_, load_err, db_err := kvstore.load_turtle(db, transmute([]byte)string(DATA), "http://example/")
	if !testing.expectf(t, load_err.message == "" && db_err == nil, "data did not load: %s %v", load_err.message, db_err) {
		return
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, _ := sparql.translate(&p)

	tx, txn_err := kvstore.txn_begin(db, .Write)
	if !testing.expectf(t, txn_err == nil, "txn_begin: %v", txn_err) {
		return
	}
	defer kvstore.txn_abort(&tx)
	kvstore.load_turtle_txn(&tx, transmute([]byte)string(CANDIDATE), "http://example/")

	q: sparql_kvstore.Query
	defer sparql_kvstore.query_destroy(&q) // leaves tx open
	if !sparql_kvstore.query_init_txn(&q, algebra, &tx, sparql.parser_base(&p)) {
		testing.expectf(t, false, "unsupported: %s", q.unsupported)
		return
	}

	solutions := 0
	for {
		_, more := sparql_kvstore.query_next(&q)
		if !more {
			break
		}
		solutions += 1
	}
	// Alice, Bob, and the uncommitted Carol — the candidate is visible
	// because the query is reading through the transaction that carries it.
	testing.expect_value(t, solutions, 3)
	testing.expectf(t, sparql_kvstore.query_error(&q) == nil, "store error: %v", sparql_kvstore.query_error(&q))
}
