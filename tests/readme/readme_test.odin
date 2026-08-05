// The README quick-start examples, compiled and asserted here so the
// documentation cannot drift from the real API (the family's
// README-as-contract pattern, SPARQL-T-0009 for the parser half,
// SPARQL-T-0019 for the evaluation half).
package readme

import "core:fmt"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import memstore "store:store/memstore"

import sparql "../../sparql"
import sparql_memstore "../../sparql/memstore"

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

@(test)
readme_evaluation :: proc(t: ^testing.T) {
	// A dictionary and a dataset are the in-memory backend's two halves.
	dictionary: memstore.Dictionary
	memstore.dictionary_init(&dictionary)
	defer memstore.dictionary_destroy(&dictionary)
	dataset: memstore.Dataset
	memstore.dataset_init(&dataset)
	defer memstore.dataset_destroy(&dataset)
	_, load_err := memstore.load_turtle(
		&dictionary,
		&dataset,
		transmute([]byte)string(DATA),
		"http://example/",
	)
	if !testing.expectf(t, load_err.message == "", "data did not load: %s", load_err.message) {
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
	q: sparql_memstore.Query
	defer sparql_memstore.query_destroy(&q)
	if !sparql_memstore.query_init(&q, algebra, &dictionary, &dataset, sparql.parser_base(&p)) {
		testing.expectf(t, false, "unsupported: %s", q.unsupported)
		return
	}

	answer := strings.builder_make()
	defer strings.builder_destroy(&answer)
	names := sparql_memstore.query_var_names(&q)
	internal := sparql_memstore.query_var_internal(&q)
	for {
		// A row is Term_IDs indexed by variable slot, valid until the
		// next pull. Deep-copy it if you keep it.
		row, more := sparql_memstore.query_next(&q)
		if !more {
			break
		}
		for id, slot in row {
			if id == store.UNBOUND || internal[slot] {
				continue // unbound, or a pattern blank node
			}
			#partial switch term in sparql_memstore.query_term(&q, id) {
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
