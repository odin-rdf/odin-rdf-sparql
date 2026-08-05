package guards

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import memstore "store:store/memstore"

import sparql "../../sparql"
import sparql_mem "../../sparql/memstore"

// A representative query touching every token family: keywords, vars,
// IRIs, prefixed names (incl. percent + escape), literals of every
// shape, paths, operators, NIL/ANON, and 1.2 triple terms.
QUERY :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT DISTINCT ?name (COUNT(?friend) AS ?n)
WHERE {
	?person a foaf:Person ;
		foaf:name ?name ;
		og:audio%3Atitle "título"@es ;
		foaf:knows/foaf:knows? ?friend .
	?x ex:n\~ame ( ) [ ] _:b0 .
	<< ?s ?p ?o >> ex:q <<( <u:s> <u:p> 1 )>> .
	FILTER(?age >= 18 && ?age < 65.5 || ?w != .5E-3)
	FILTER EXISTS { ?person foaf:mbox '''m
box''' }
}
GROUP BY ?name
ORDER BY DESC(?n)
LIMIT 10
`

ROUNDS :: 1_000

// The scanner must never allocate: tokens borrow the source buffer
// (SPARQL-T-0002 acceptance criterion, ADR RDF-A-0001 discipline).
@(test)
test_scanner_zero_allocations :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&track)

	tokens := 0
	for _ in 0 ..< ROUNDS {
		s: sparql.Scanner
		sparql.scanner_init(&s, transmute([]byte)string(QUERY))
		for {
			_, ok := sparql.scanner_next(&s)
			if !ok {
				break
			}
			tokens += 1
		}
		testing.expect_value(t, s.err.kind, sparql.Error_Kind.None)
	}
	testing.expect(t, tokens > 0)
	testing.expect(t, track.total_allocation_count == 0, "scanning must not allocate at all")
}

// A parse-and-destroy cycle must release everything the parser owns:
// the query tree, the intern table, the prefix map, and the scratch
// buffers (SPARQL-T-0003 memory contract).
@(test)
test_parser_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	PARSE_QUERY :: `
BASE <http://example.org/data/>
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT DISTINCT ?name (STRLEN(?name) + 1 AS ?n)
FROM <graphs/main> FROM NAMED <graphs/extra>
WHERE {
	?person a foaf:Person ;
		foaf:name ?name , "backup\n"@en ;
		foaf:topics ( "a" "b" 3 ) .
	[ foaf:nick "néo" ] foaf:knows ?person .
	{ GRAPH ?g { ?person foaf:age 42 } } UNION { OPTIONAL { ?person foaf:mbox ?m } }
	FILTER(?age >= 18 && !REGEX(?name, "^x", "i") || ?age NOT IN (1, 2+3))
	FILTER NOT EXISTS { ?person foaf:enemy ?e }
	FILTER foaf:custom(DISTINCT ?name)
	BIND(IF(BOUND(?m), STR(?m), "none") AS ?mail)
	?person foaf:knows/foaf:knows?|^foaf:employs ?fof .
	?person !(foaf:enemy|^foaf:blocks) ?other .
	<< ?person foaf:age 42 ~ foaf:claim >> foaf:source ?src .
	?person foaf:says ?quote ~ foaf:q1 {| foaf:certainty 0.9 |} .
	<<( ?person foaf:name ?name )>> foaf:listedIn ?reg .
	BIND(<<( ?person foaf:name ?name )>> AS ?nameClaim)
	MINUS { ?person foaf:status "hidden" }
	VALUES (?dept ?floor) { ("eng" 3) (UNDEF 1) }
	{ SELECT ?person (COUNT(*) AS ?edges) { ?person foaf:knows ?anyone } GROUP BY ?person }
}
GROUP BY ?name ?person ?mail
HAVING(COUNT(?fof) >= 0)
ORDER BY ?name DESC(?person + 1) str(?mail) LIMIT 5 OFFSET 2
`
	for _ in 0 ..< 100 {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)string(PARSE_QUERY), "", allocator)
		_, ok := sparql.parse(&p)
		testing.expect_value(t, p.err.kind, sparql.Error_Kind.None)
		testing.expect(t, ok)
		sparql.parser_destroy(&p)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// A parse+translate+destroy cycle must release everything: the query
// tree, the algebra tree, and the aggregate expressions the §18.2
// substitution detaches from the AST (SPARQL-T-0007 ownership).
@(test)
test_translate_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	TRANSLATE_QUERY :: `
PREFIX f: <urn:f#>
SELECT ?s (COUNT(DISTINCT ?v) + 1 AS ?n) (GROUP_CONCAT(?v ; SEPARATOR = ",") AS ?all)
WHERE {
	?s f:p/f:q+ ?v ; ^f:r ?w .
	OPTIONAL { ?s f:m ?m FILTER(?m > 0) FILTER(?m < 9) }
	FILTER EXISTS { ?s f:flag true }
	MINUS { ?s f:hide ?any }
	BIND(STR(?w) AS ?label)
	VALUES ?tag { "a" "b" }
	{ SELECT (SUM(?z) AS ?total) { ?a f:num ?z } }
}
GROUP BY ?s HAVING(COUNT(?v) > 1 && NOT EXISTS { ?s f:no ?x })
ORDER BY DESC(?n) LIMIT 7 OFFSET 1
`
	for _ in 0 ..< 50 {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)string(TRANSLATE_QUERY), "", allocator)
		_, parse_ok := sparql.parse(&p)
		testing.expect_value(t, p.err.kind, sparql.Error_Kind.None)
		testing.expect(t, parse_ok)
		_, translate_ok := sparql.translate(&p)
		testing.expect(t, translate_ok)
		sparql.parser_destroy(&p)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Failed parses must release everything too — the error paths abandon
// partial trees to the parser, never to the floor.
@(test)
test_parser_no_leaks_on_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	BAD_QUERIES :: [?]string {
		"SELECT * { ?s foaf:undeclared ?o }",
		"SELECT * { ?s ?p ?o ",
		"SELECT * { <rel> ?p ?o }",
		"SELECT * { { ?a ?b ?c } UNION { ?d ?e ",
		"SELECT * { ?s ?p ( 1 2 }",
		"SELECT * { [ ?p 1 ?o }",
		"ASK { _:a ?p ?o OPTIONAL { ?s ?q _:a } }",
		"ASK { FILTER(?x + ) }",
		"ASK { FILTER(STRLEN(?x, ?y)) }",
		"ASK { BIND(?x + 1 ?y) }",
		"SELECT (1 + AS ?x) { ?s ?p ?o }",
		"ASK { FILTER EXISTS { ?s ?p } }",
		"SELECT * { ?s !( ?p } ",
		"SELECT * { ?s ^/:p ?o }",
		"SELECT * { VALUES (?x) { (1 2) } }",
		"SELECT (COUNT(*) AS ?n) ?s { ?s ?p ?o }",
		"SELECT * { { SELECT ?x { ?x ?y ?z ",
		"SELECT * { ?s ?p ?o } GROUP BY ?s",
		"CONSTRUCT { ?s ?p/?q ?o } WHERE { ?s ?p ?o }",
	}
	for bad in BAD_QUERIES {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)bad, "", allocator)
		_, ok := sparql.parse(&p)
		testing.expect(t, !ok)
		sparql.parser_destroy(&p)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Evaluation's memory contract (SPARQL-T-0011).
//
// The streaming operators promise to allocate nothing per solution: the
// row buffer, the per-pattern match iterators, and their bookkeeping are
// allocated when the query is prepared, and pulling solutions must touch
// none of it. That promise is what makes a query over a large store cost
// memory proportional to the query rather than to the answer, so it is
// asserted directly — the allocation counter must not move across the
// pull loop.
//
// DISTINCT is the deliberate exception and is excluded here: it has to
// retain what it has seen, and it says so in exec.odin.
@(test)
test_evaluation_streams_without_allocating :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	defer memstore.dictionary_destroy(&d)
	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	defer memstore.dataset_destroy(&ds)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 500 {
		fmt.sbprintf(&b, "<http://e/s%d> <http://e/p> <http://e/m%d> .\n", i, i %% 50)
		fmt.sbprintf(&b, "<http://e/m%d> <http://e/q> <http://e/o%d> .\n", i %% 50, i)
	}
	_, load_err := memstore.load_triples(&d, &ds, transmute([]byte)strings.to_string(b))
	testing.expectf(t, load_err.message == "", "fixture did not load: %s", load_err.message)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(`SELECT * WHERE { ?s <http://e/p> ?m . ?m <http://e/q> ?o }`))
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, translated := sparql.translate(&p)
	testing.expect(t, translated, "the query should translate")

	q: sparql_mem.Query
	prepared := sparql_mem.query_init(&q, algebra, &d, &ds)
	defer sparql_mem.query_destroy(&q)
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)

	// Pull one solution before measuring. Preparing a query allocates
	// nothing store-side, but the *first* match does: memstore merges its
	// pending inserts into its indexes lazily, on the first read. That is
	// the store's business and it happens once, not per solution — what
	// this guard is about is everything after it.
	_, first := sparql_mem.query_next(&q)
	testing.expect(t, first, "the query should have solutions")

	before := track.total_allocation_count
	solutions := 1
	for {
		_, more := sparql_mem.query_next(&q)
		if !more {
			break
		}
		solutions += 1
	}
	after := track.total_allocation_count

	testing.expectf(t, solutions == 5000, "expected 5000 solutions, got %d", solutions)
	testing.expectf(
		t,
		after == before,
		"streaming %d solutions performed %d allocations; the streaming path must allocate none",
		solutions,
		after - before,
	)
}

// Preparing, running, and destroying a query must release everything —
// the plan, the slot table, the operator state, and every match iterator
// the run opened, including the ones abandoned mid-stream.
@(test)
test_evaluation_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	d: memstore.Dictionary
	memstore.dictionary_init(&d, allocator)
	ds: memstore.Dataset
	memstore.dataset_init(&ds, allocator)
	context.allocator = allocator
	_, load_err := memstore.load_triples(
		&d,
		&ds,
		transmute([]byte)string(`<http://e/a> <http://e/p> <http://e/b> .
<http://e/b> <http://e/p> <http://e/c> .
<http://e/c> <http://e/p> <http://e/a> .`),
	)
	testing.expectf(t, load_err.message == "", "fixture did not load: %s", load_err.message)

	QUERIES :: [?]string {
		`SELECT * WHERE { ?s <http://e/p> ?o }`,
		`SELECT DISTINCT ?o WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?o WHERE { ?s <http://e/p> ?o } LIMIT 1 OFFSET 1`,
		`SELECT * WHERE { ?a <http://e/p> ?b . ?b <http://e/p> ?c . ?c <http://e/p> ?a }`,
		// A term the store does not hold: the plan collapses, and the
		// partially built pattern must still be released.
		`SELECT * WHERE { <http://e/missing> <http://e/p> ?o }`,
	}
	for query in QUERIES {
		for stop_early in ([?]bool{false, true}) {
			p: sparql.Parser
			sparql.parser_init(&p, transmute([]byte)query, "", allocator)
			_, parsed := sparql.parse(&p)
			testing.expect(t, parsed)
			algebra, _ := sparql.translate(&p)

			q: sparql_mem.Query
			if sparql_mem.query_init(&q, algebra, &d, &ds, allocator) {
				pulled := 0
				for {
					_, more := sparql_mem.query_next(&q)
					if !more {
						break
					}
					pulled += 1
					// Abandoning a run mid-stream leaves match iterators
					// open; destroying the query must still close them.
					if stop_early && pulled == 1 {
						break
					}
				}
			}
			sparql_mem.query_destroy(&q)
			sparql.parser_destroy(&p)
		}
	}
	// The store is torn down before the assertion, not by a defer: a
	// deferred destroy runs after the check and would leave the store's
	// own live allocations looking like the engine's leaks.
	memstore.dataset_destroy(&ds)
	memstore.dictionary_destroy(&d)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
