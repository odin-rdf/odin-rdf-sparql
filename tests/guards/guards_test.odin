package guards

import "core:mem"
import "core:testing"

import sparql "../../sparql"

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
