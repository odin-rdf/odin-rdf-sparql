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
