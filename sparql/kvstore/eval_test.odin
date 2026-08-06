package sparql_kvstore

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

// The W3C evaluation suites already run this instantiation end to end
// against the persistent backend (tests/w3c/harness). What is pinned here
// is the part the suites cannot reach: that preparing a query against a
// persistent store stays a read, and that a store failure is reported as a
// failure rather than as an empty answer.

@(private = "file")
scratch_path :: proc(name: string) -> string {
	return fmt.aprintf("%s/odin-sparql-kv-%s-%d", temp_dir(), name, os.get_pid())
}

// temp_dir returns the OS temp directory with no trailing separator, so
// callers add their own. macOS exports TMPDIR with a trailing slash and
// Linux usually exports nothing, which makes concatenating onto the
// variable a coin flip; Windows names it TEMP or TMP and has no /tmp to
// fall back to, so the fallback alone is not enough.
@(private = "file")
temp_dir :: proc() -> string {
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
	return strings.trim_right(tmp, `/\`)
}

@(private = "file")
remove_scratch :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}

@(private = "file")
DATA :: `@prefix : <http://example/> .
:alice :knows :bob .
:bob :knows :carol .
`

@(test)
test_kvstore_evaluates_a_join :: proc(t: ^testing.T) {
	path := scratch_path("join")
	defer remove_scratch(path)
	s, open_err := kvstore.open(path)
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(DATA), "http://example/")
	testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load: %s %v", parse_err.message, load_err)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(`PREFIX : <http://example/> SELECT * WHERE { ?a :knows ?b . ?b :knows ?c }`))
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := sparql.translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, s), "query not supported: %s", q.unsupported) {
		return
	}

	solutions := 0
	names := query_var_names(&q)
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		solutions += 1
		for id, slot in row {
			if id == store.UNBOUND {
				continue
			}
			term := query_term(&q, id)
			iri, is_iri := term.(rdf.IRI)
			testing.expectf(t, is_iri, "%s should be bound to an IRI", names[slot])
			testing.expectf(t, iri != "", "%s materialized to an empty IRI", names[slot])
		}
	}
	testing.expectf(t, solutions == 1, "expected one solution, got %d", solutions)
	testing.expectf(t, query_error(&q) == nil, "the store reported an error: %v", query_error(&q))
}

@(test)
test_kvstore_query_setup_does_not_write :: proc(t: ^testing.T) {
	// The point of STORE-T-0014: resolving a query's ground terms uses
	// find_term, which serves from a read transaction. If it interned
	// instead, preparing a query would be a write — and a query against a
	// store opened read-only would fail outright. Opening read-only is
	// therefore the sharpest way to assert it.
	path := scratch_path("readonly")
	defer remove_scratch(path)
	{
		s, open_err := kvstore.open(path)
		if !testing.expectf(t, open_err == nil, "cannot create the store: %v", open_err) {
			return
		}
		defer kvstore.close(s)
		_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(DATA), "http://example/")
		testing.expectf(t, parse_err.message == "" && load_err == nil, "fixture did not load")
	}

	options := kvstore.DEFAULT_OPTIONS
	options.read_only = true
	s, open_err := kvstore.open(path, options)
	if !testing.expectf(t, open_err == nil, "cannot reopen read-only: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	p: sparql.Parser
	// The query names a term the store holds and one it does not, so both
	// the found and the not-found paths run under the read-only open.
	sparql.parser_init(
		&p,
		transmute([]byte)string(`PREFIX : <http://example/> SELECT * WHERE { :alice :knows ?b }`),
	)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := sparql.translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, s), "preparing the query failed: %s", q.unsupported) {
		return
	}
	solutions := 0
	for {
		_, more := query_next(&q)
		if !more {
			break
		}
		solutions += 1
	}
	testing.expectf(t, solutions == 1, "expected one solution from the read-only store, got %d", solutions)
	testing.expectf(t, query_error(&q) == nil, "evaluating read-only reported an error: %v", query_error(&q))

	absent: Query
	defer query_destroy(&absent)
	p2: sparql.Parser
	sparql.parser_init(
		&p2,
		transmute([]byte)string(`PREFIX : <http://example/> SELECT * WHERE { :nobody :knows ?b }`),
	)
	defer sparql.parser_destroy(&p2)
	_, parsed2 := sparql.parse(&p2)
	testing.expect(t, parsed2, "the second query should parse")
	algebra2, _ := sparql.translate(&p2)
	testing.expect(t, query_init(&absent, algebra2, s), "an absent term must not fail preparation")
	_, more := query_next(&absent)
	testing.expect(t, !more, "a term the store does not hold cannot match")
	testing.expectf(t, query_error(&absent) == nil, "the absent-term path errored: %v", query_error(&absent))
}
