// The README quick-start example, compiled and asserted here so the
// documentation cannot drift from the real API (the family's
// README-as-contract pattern, SPARQL-T-0009).
package readme

import "core:strings"
import "core:testing"

import sparql "../../sparql"

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
