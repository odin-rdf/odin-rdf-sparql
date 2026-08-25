package guards

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"


import "../../sparql"

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

	g: Guard_DB
	defer guard_close(&g)
	if !guard_open(t, &g, "streams") {
		return
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< 500 {
		fmt.sbprintf(&b, "<http://e/s%d> <http://e/p> <http://e/m%d> .\n", i, i %% 50)
		fmt.sbprintf(&b, "<http://e/m%d> <http://e/q> <http://e/o%d> .\n", i %% 50, i)
	}
	if !guard_load_ntriples(t, &g, strings.to_string(b)) {
		return
	}
	snap, pinned := guard_snap(t, &g)
	if !pinned {
		return
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(`SELECT * WHERE { ?s <http://e/p> ?m . ?m <http://e/q> ?o }`))
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, translated := sparql.translate(&p)
	testing.expect(t, translated, "the query should translate")

	q: sparql.Query
	prepared := sparql.query_init(&q, algebra, snap)
	defer sparql.query_destroy(&q)
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)

	// Pull one solution before measuring. Whatever a first read costs is
	// the store's business and happens once, not per solution — what this
	// guard is about is everything after it. (Against odin-rdf-store that
	// first read was memstore merging its pending inserts; record's
	// permutations are built at apply, so this is now belt and braces.)
	_, first := sparql.query_next(&q)
	testing.expect(t, first, "the query should have solutions")

	before := track.total_allocation_count
	solutions := 1
	for {
		_, more := sparql.query_next(&q)
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

// A triple-term pattern's memory contract (SPARQL-T-0018) — RETIRED
// 2026-08-07 with the in-memory backend (odin-rdf-store STORE-A-0006).
//
// The guard asserted that matching `<<( ?a ?b ?c )>>` takes a stored
// triple term apart without allocating. That was true of memstore and
// only of memstore: its dictionary already held the component IDs it
// interned the term from, and the Triple_Reader adapter read them
// straight out. The guard's own comment recorded the limit — "a backend
// that has to materialize instead — kvstore does — will not satisfy
// this" — so this is a property that left with the backend, not one that
// regressed.
//
// Measured on the way out rather than assumed: 500 triple-term solutions
// performed 1996 allocations against kvstore, roughly four per solution,
// which is the term materialization the adapter's comment predicted.
//
// Nothing replaces it. The general streaming guard above still holds and
// still covers every other operator; what is no longer asserted anywhere
// is that triple-term decomposition is allocation-free, because on the
// only backend that exists it is not. If an in-memory backend ever
// returns, this guard is the thing to bring back with it.

// A GROUP BY is a blocking operator, but it must not be a *buffering*
// one: it keeps one accumulator per aggregate per group and folds each
// solution in as it arrives, so its memory is the number of groups and
// not the size of its input. That is what makes `SELECT ?p (COUNT(?o) AS
// ?n) … GROUP BY ?p` runnable over a store that does not fit in memory,
// and it is the sort of property that decays silently — hence a
// measurement rather than a comment.
//
// Ten times the solutions, the same two groups: the query's own peak
// must not follow the input. The store is deliberately outside the
// tracked allocator, because its memory *does* scale with the data.
@(test)
test_grouping_is_bounded_by_its_groups :: proc(t: ^testing.T) {
	small := grouped_query_peak(t, 100)
	large := grouped_query_peak(t, 1000)
	// A slack of a few kilobytes covers the dynamic arrays' growth
	// doubling; what it does not cover is a per-solution retention, which
	// would be nine hundred rows of difference.
	testing.expectf(
		t,
		large <= small + 8192,
		"grouping 10x the solutions into the same two groups took %d bytes at peak against %d — the group state is following the input",
		large,
		small,
	)
}

@(private = "file")
grouped_query_peak :: proc(t: ^testing.T, solutions: int) -> int {
	g: Guard_DB
	defer guard_close(&g)
	if !guard_open(t, &g, "grouping") {
		return 0
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< solutions {
		fmt.sbprintf(&b, "<http://e/s%d> <http://e/p%d> <http://e/o%d> .\n", i, i %% 2, i)
	}
	if !guard_load_ntriples(t, &g, strings.to_string(b)) {
		return 0
	}
	snap, pinned := guard_snap(t, &g)
	if !pinned {
		return 0
	}

	p: sparql.Parser
	// Every aggregate here answers from O(1) state per group. GROUP_CONCAT
	// and COUNT(DISTINCT …) are deliberately absent: their answers are
	// linear in the input by definition, and this guard is about the ones
	// whose answers are not.
	sparql.parser_init(
		&p,
		transmute([]byte)string(`SELECT ?p (COUNT(?o) AS ?n) (MIN(STR(?o)) AS ?lo) (MAX(STR(?o)) AS ?hi)
		                          WHERE { ?s ?p ?o } GROUP BY ?p`),
	)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, translated := sparql.translate(&p)
	testing.expect(t, translated, "the query should translate")

	// Only the query's allocations are tracked; the store's memory does
	// scale with the data, and that is its business.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	q: sparql.Query
	prepared := sparql.query_init(&q, algebra, snap, "", mem.tracking_allocator(&track))
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)
	groups := 0
	for {
		_, more := sparql.query_next(&q)
		if !more {
			break
		}
		groups += 1
	}
	testing.expectf(t, groups == 2, "expected 2 groups, got %d", groups)
	peak := track.peak_memory_allocated
	sparql.query_destroy(&q)
	return int(peak)
}

// A property path's memory contract (SPARQL-T-0016).
//
// A repeat form cannot stream: `*` and `+` are sets, and a set is not a
// set until something remembers what has been in it. What it *must* not do
// is remember the answer — the visited set, the frontier, and the start
// list are bounded by the graph's nodes, and the solutions built from them
// are handed out one at a time and never retained.
//
// Two measurements, because the property has two halves. Ten times the
// solutions over the same graph must cost the same: the traversal follows
// the graph, not the answer. Four times the graph must cost more: that is
// what proves the traversal's memory is being taken from the query's
// allocator at all, rather than from somewhere this guard cannot see.
@(test)
test_property_path_traversal_is_bounded_by_the_graph :: proc(t: ^testing.T) {
	one_answer := path_query_peak(t, 12, 1)
	ten_answers := path_query_peak(t, 12, 10)
	four_times_the_graph := path_query_peak(t, 48, 1)

	// The slack covers the dynamic arrays' growth doubling; what it does
	// not cover is a retained solution per answer, which would be more than
	// a thousand rows of difference.
	testing.expectf(
		t,
		ten_answers <= one_answer + 8192,
		"10x the solutions over the same graph took %d bytes at peak against %d — the traversal is following the answer",
		ten_answers,
		one_answer,
	)
	testing.expectf(
		t,
		four_times_the_graph > one_answer,
		"4x the graph took %d bytes at peak against %d — the traversal's state is not coming from the query's allocator",
		four_times_the_graph,
		one_answer,
	)
}

// path_query_peak walks every pair of a clique of `nodes` under `:p*` and
// returns the query's peak. fanout multiplies the *answers* without
// touching what the traversal has to hold: the extra triples use a
// predicate the path never follows, and the join above the path re-runs
// per path solution.
@(private = "file")
path_query_peak :: proc(t: ^testing.T, nodes: int, fanout: int) -> int {
	g: Guard_DB
	defer guard_close(&g)
	if !guard_open(t, &g, "path") {
		return 0
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for from in 0 ..< nodes {
		for to in 0 ..< nodes {
			if from == to {
				continue
			}
			fmt.sbprintf(&b, "<http://e/n%d> <http://e/p> <http://e/n%d> .\n", from, to)
		}
	}
	for i in 0 ..< fanout {
		fmt.sbprintf(&b, "<http://e/f%d> <http://e/q> <http://e/g%d> .\n", i, i)
	}
	if !guard_load_ntriples(t, &g, strings.to_string(b)) {
		return 0
	}
	snap, pinned := guard_snap(t, &g)
	if !pinned {
		return 0
	}

	p: sparql.Parser
	sparql.parser_init(
		&p,
		transmute([]byte)string(`SELECT * WHERE { ?x <http://e/p>* ?y . ?f <http://e/q> ?g }`),
	)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, translated := sparql.translate(&p)
	testing.expect(t, translated, "the query should translate")

	// Only the query's allocations are tracked; the store's memory does
	// scale with the data, and that is its business.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	q: sparql.Query
	prepared := sparql.query_init(&q, algebra, snap, "", mem.tracking_allocator(&track))
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)
	solutions := 0
	for {
		_, more := sparql.query_next(&q)
		if !more {
			break
		}
		solutions += 1
	}
	// Every node of the clique reaches every node, itself included. The
	// fanout triples add nodes too — nodes(G) is the whole graph's, not the
	// path's — so each contributes its own zero-length pair; and the join
	// multiplies the lot. Asserted so the guard cannot end up measuring a
	// query that answered nothing.
	want := (nodes * nodes + 2 * fanout) * fanout
	testing.expectf(t, solutions == want, "expected %d solutions, got %d", want, solutions)
	peak := track.peak_memory_allocated
	sparql.query_destroy(&q)
	return int(peak)
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

	// The store is deliberately *inside* the tracked allocator here: what
	// this guard is looking for is anything the engine failed to free, so
	// the store is torn down by hand before the assertion rather than by
	// a defer. See guard_close.
	context.allocator = allocator
	g: Guard_DB
	if !guard_open(t, &g, "evaluation-leaks", allocator) {
		return
	}
	if !guard_load_ntriples(t, &g, `<http://e/a> <http://e/p> <http://e/b> .
<http://e/b> <http://e/p> <http://e/c> .
<http://e/c> <http://e/p> <http://e/a> .
<http://e/a> <http://e/r> <<( <http://e/a> <http://e/p> <http://e/b> )>> .
<http://e/b> <http://e/r> <<( <http://e/b> <http://e/p> <<( <http://e/c> <http://e/p> <http://e/a> )>> )>> .`) {
		guard_close(&g)
		return
	}
	snap, pinned := guard_snap(t, &g)
	if !pinned {
		guard_close(&g)
		return
	}

	QUERIES :: [?]string {
		`SELECT * WHERE { ?s <http://e/p> ?o }`,
		`SELECT DISTINCT ?o WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?o WHERE { ?s <http://e/p> ?o } LIMIT 1 OFFSET 1`,
		`SELECT * WHERE { ?a <http://e/p> ?b . ?b <http://e/p> ?c . ?c <http://e/p> ?a }`,
		// The §17 library allocates where the rest of the engine does not:
		// every string it builds, the compiled regexes it caches for the
		// life of the query, BNODE's per-solution labels, and NOW's lexical
		// form. Each has a different lifetime, so each is a different way
		// to leak (SPARQL-T-0014).
		`SELECT (CONCAT(STR(?s), UCASE("x"), SUBSTR("hello", 2)) AS ?c) WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?s WHERE { ?s <http://e/p> ?o FILTER(REGEX(STR(?o), "^http", "i")) }`,
		`SELECT (REPLACE(STR(?o), "([a-z])", "[$1]") AS ?r) WHERE { ?s <http://e/p> ?o }`,
		`SELECT (BNODE(STR(?s)) AS ?b1) (BNODE(STR(?s)) AS ?b2) (BNODE() AS ?b3) WHERE { ?s <http://e/p> ?o }`,
		`SELECT (NOW() AS ?n) (UUID() AS ?u) (STRUUID() AS ?su) (RAND() AS ?r) WHERE { ?s <http://e/p> ?o }`,
		`SELECT (SHA256(STR(?s)) AS ?h) (<http://www.w3.org/2001/XMLSchema#string>(?s) AS ?c) WHERE { ?s <http://e/p> ?o }`,
		// An invalid pattern is cached as a failure; the compilation's
		// partial allocations must still be released.
		`SELECT ?s WHERE { ?s <http://e/p> ?o FILTER(REGEX(STR(?o), "(unclosed")) }`,
		// A term the store does not hold: the plan collapses, and the
		// partially built pattern must still be released.
		`SELECT * WHERE { <http://e/missing> <http://e/p> ?o }`,
		// The blocking operators own more than the streaming ones do: a
		// group table keyed on owned strings, accumulators holding copies
		// of terms, an exact decimal's lexical form, and every solution
		// plus its materialized sort keys (SPARQL-T-0015). Each is a
		// different lifetime and so a different way to leak, and the
		// abandoned-mid-stream half of this loop catches the ones that are
		// only released on the way out.
		`SELECT (COUNT(*) AS ?n) (COUNT(DISTINCT ?o) AS ?d) WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?s (SUM(?o) AS ?t) (MIN(?o) AS ?lo) (MAX(?o) AS ?hi) (SAMPLE(?o) AS ?any)
		 WHERE { ?s <http://e/p> ?o } GROUP BY ?s`,
		`SELECT (SUM(?v) AS ?t) (AVG(?v) AS ?m) WHERE { VALUES ?v { 1.0 2.2 3.5 } }`,
		`SELECT (GROUP_CONCAT(?o ; SEPARATOR = ", ") AS ?g) WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?kind (COUNT(*) AS ?n) WHERE { ?s <http://e/p> ?o } GROUP BY (DATATYPE(?o) AS ?kind)
		 HAVING (COUNT(*) > 0)`,
		`SELECT ?s ?o WHERE { ?s <http://e/p> ?o } ORDER BY DESC(?o) STR(?s)`,
		`SELECT ?s WHERE { ?s <http://e/p> ?o } ORDER BY (?o + 1) LIMIT 2 OFFSET 1`,
		`SELECT ?g (COUNT(*) AS ?n) WHERE { GRAPH ?g { SELECT (COUNT(*) AS ?c) { ?s ?p ?o } } } GROUP BY ?g`,
		// A property path owns a traversal: a start list, a result list, a
		// frontier, and three membership sets. It also runs its step
		// sub-plan itself rather than through the driver, so the iterators
		// that sub-plan opens are released on a path of their own — and the
		// abandoned-mid-stream half of this loop is where a traversal left
		// part-way through a frontier would show up (SPARQL-T-0016).
		`SELECT * WHERE { ?s <http://e/p>* ?o }`,
		`SELECT ?o WHERE { <http://e/a> <http://e/p>+ ?o }`,
		`SELECT ?s WHERE { ?s <http://e/p>? <http://e/b> }`,
		`SELECT ?o WHERE { <http://e/a> (<http://e/p>/<http://e/p>)+ ?o }`,
		`SELECT ?x WHERE { <http://e/a> ((<http://e/p>)*)* ?x }`,
		`SELECT * WHERE { ?s !(<http://e/p>|^<http://e/q>) ?o }`,
		// A path endpoint the store does not hold: the zero-length path
		// binds it anyway, so it is named rather than short-circuited, and
		// the name it is given is owned by the execution.
		`SELECT ?o WHERE { <http://e/missing> <http://e/p>* ?o }`,
		// A triple term owns things at three different moments
		// (SPARQL-T-0018). A *ground* one is materialized at plan time to
		// be looked up and released again — unless a VALUES cell or a path
		// endpoint keeps it, when the builder owns it instead. A
		// *non-ground* one adds a shape and the internal slots it binds
		// into. And one the query *computes* is a node in the evaluation
		// scratch that has to survive exactly until it has been named.
		`SELECT * WHERE { ?s <http://e/r> <<( <http://e/a> <http://e/p> <http://e/b> )>> }`,
		`SELECT * WHERE { ?s <http://e/r> <<( <http://e/a> <http://e/p> <http://e/nowhere> )>> }`,
		`SELECT * WHERE { ?s <http://e/r> <<( ?a <http://e/p> ?b )>> }`,
		`SELECT * WHERE { ?s <http://e/r> <<( ?a <http://e/p> <<( ?x ?y ?z )>> )>> }`,
		`SELECT ?t WHERE { VALUES ?t { <<( <http://e/a> <http://e/p> <http://e/b> )>>
		                               <<( <http://e/x> <http://e/p> <http://e/y> )>> } }`,
		`SELECT (<<( ?s <http://e/p> ?o )>> AS ?t) (TRIPLE(?s, <http://e/p>, ?o) AS ?u)
		 WHERE { ?s <http://e/p> ?o }`,
		`SELECT ?o WHERE { <<( <http://e/a> <http://e/p> <http://e/b> )>> <http://e/p>* ?o }`,
	}
	for query in QUERIES {
		for stop_early in ([?]bool{false, true}) {
			p: sparql.Parser
			sparql.parser_init(&p, transmute([]byte)query, "", allocator)
			_, parsed := sparql.parse(&p)
			testing.expect(t, parsed)
			algebra, _ := sparql.translate(&p)

			q: sparql.Query
			if sparql.query_init(&q, algebra, snap, sparql.parser_base(&p), allocator) {
				pulled := 0
				for {
					_, more := sparql.query_next(&q)
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
			sparql.query_destroy(&q)
			sparql.parser_destroy(&p)
		}
	}
	// The store is torn down before the assertion, not by a defer: a
	// deferred destroy runs after the check and would leave the store's
	// own live allocations looking like the engine's leaks.
	guard_close(&g)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// The graph-answering result forms' memory contract (SPARQL-T-0017).
//
// A CONSTRUCT or a DESCRIBE answers with a Result_Graph that owns every
// term in it, copied out of whatever the backend materialized. That is
// three owned structures the solution path does not have — the compiled
// template, the graph's triples, and the deduplication keys that make it
// a set — and each is a different lifetime. So the cycle is run under a
// tracking allocator and the count has to come back to zero: the caller
// frees the graph, and freeing the graph frees all of it.
@(test)
test_result_graph_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)

	// The store is inside the tracked allocator and torn down by hand
	// before the assertion; see the note in test_evaluation_no_leaks.
	context.allocator = allocator
	g: Guard_DB
	if !guard_open(t, &g, "result-graph-leaks", allocator) {
		return
	}
	if !guard_load_ntriples(t, &g, `<http://e/a> <http://e/p> <http://e/b> .
<http://e/b> <http://e/p> <http://e/c> .
<http://e/c> <http://e/p> "text" .
<http://e/a> <http://e/r> <<( <http://e/a> <http://e/p> <http://e/b> )>> .`) {
		guard_close(&g)
		return
	}
	snap, pinned := guard_snap(t, &g)
	if !pinned {
		guard_close(&g)
		return
	}

	QUERIES :: [?]string {
		// A template with a variable in every position, and one with a
		// blank node — the two ways a template triple is built.
		`CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }`,
		`CONSTRUCT { _:r <http://e/about> ?s . _:r <http://e/saw> ?o } WHERE { ?s <http://e/p> ?o }`,
		// A template position the pattern leaves unbound, and one it binds
		// to a literal: both drop their triple, and a drop must not leak
		// the graph entry it did not make.
		`CONSTRUCT { ?s <http://e/q> ?missing . ?o <http://e/back> ?s } WHERE { ?s <http://e/p> ?o }`,
		// CONSTRUCT WHERE: the template doubles as the pattern.
		`CONSTRUCT WHERE { ?s <http://e/p> ?o }`,
		// DESCRIBE with no pattern at all, from a pattern, and over a
		// resource the store does not hold.
		`DESCRIBE <http://e/a>`,
		`DESCRIBE ?o WHERE { ?s <http://e/p> ?o }`,
		`DESCRIBE * WHERE { ?s <http://e/p> ?o }`,
		`DESCRIBE <http://e/nobody>`,
		// A template that builds a triple term keeps a node and a label
		// buffer per compiled term, reused across solutions and freed with
		// the template — and a term with an unbound component is not built
		// at all, which must not leave a half-filled node behind
		// (SPARQL-T-0018).
		`CONSTRUCT { ?s <http://e/states> <<( ?s ?p ?o )>> } WHERE { ?s ?p ?o }`,
		`CONSTRUCT { ?s <http://e/states> <<( ?s ?p ?missing )>> } WHERE { ?s ?p ?o }`,
		`CONSTRUCT { ?s <http://e/states> <<( ?s ?p <<( ?s ?p ?o )>> )>> } WHERE { ?s ?p ?o }`,
	}
	for query in QUERIES {
		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)query, "", allocator)
		_, parsed := sparql.parse(&p)
		testing.expectf(t, parsed, "the query should parse: %s", query)
		algebra, _ := sparql.translate(&p)

		q: sparql.Query
		if sparql.query_init(&q, algebra, snap, sparql.parser_base(&p), allocator) {
			graph: sparql.Result_Graph
			if p.query.form == .Construct {
				template: sparql.Template
				sparql.template_build(&template, p.query.template, sparql.query_slots(&q), allocator)
				graph = sparql.query_construct(&q, &template, allocator)
				sparql.template_destroy(&template)
			} else {
				targets: sparql.Describe_Targets
						sparql.describe_build(&targets, p.query, sparql.query_slots(&q), snap, allocator)
				graph = sparql.query_describe(&q, &targets, allocator)
				sparql.describe_destroy(&targets)
			}
			sparql.result_graph_destroy(&graph)
		}
		sparql.query_destroy(&q)
		sparql.parser_destroy(&p)
	}
	guard_close(&g)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
