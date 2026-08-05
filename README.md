# odin-rdf-sparql

A SPARQL query engine for the Odin RDF family: a complete SPARQL 1.1
Query parser with the SPARQL 1.2 surface (triple terms, reified
triples, annotations, VERSION), translating queries to the W3C SPARQL
algebra (§18.2/§18.4) with an ARQ-compatible SSE printer. Written in
Odin with no external dependencies, and validated by the vendored
official W3C syntax suites: **all 342 in-scope conformance tests pass**
(154 SPARQL 1.1, 188 SPARQL 1.2), at both `Term_ID` widths.

This is the third layer of the family stack —
[odin-rdf-parser](../odin-rdf-parser) (formats and data model) →
[odin-rdf-store](../odin-rdf-store) (storage, match interface) → this
engine. The evaluation engine over the store's match interface is the
next initiative; SPARQL Update, the HTTP protocols, and federation
(SERVICE) are out of scope per the project vision.

## Packages

| Package  | Description                                                             |
| -------- | ----------------------------------------------------------------------- |
| `sparql` | Tokenizer, recursive-descent parser (query text → AST), §18.2/§18.4 translation (AST → algebra), and the SSE algebra printer |

The sibling checkouts are reached through collections — `rdf:` for the
data model, `store:` for the match interface — as declared in the
Makefile and `ols.json`.

## Quick start

Parsing a query and printing its algebra:

```odin
import "core:fmt"
import sparql "sparql"

QUERY :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT ?name WHERE {
	?person a foaf:Person ; foaf:name ?name .
	FILTER(STRLEN(?name) > 0)
}
ORDER BY ?name LIMIT 10
`

run :: proc() {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(QUERY))
	defer sparql.parser_destroy(&p)

	query, ok := sparql.parse(&p)
	if !ok {
		fmt.eprintfln("parse error at line %d, column %d: %s",
			p.err.line, p.err.column, sparql.error_message(p.err.kind))
		return
	}
	_ = query // the AST; positions, prologue-resolved IRIs, patterns

	algebra, _ := sparql.translate(&p)
	sse := sparql.algebra_to_string(algebra)
	defer delete(sse)
	fmt.print(sse)
	// (slice _ 10
	//   (project (?name)
	//     (order (?name)
	//       (filter (> (strlen ?name) 0)
	//         (bgp (triple ?person <…type> <…Person>) (triple ?person <…name> ?name))))))
}
```

## Memory model

The family's contract, in three parts:

- The query text is caller-owned and must stay valid and unmoved for
  the parser's lifetime; AST and algebra strings borrow from it where
  possible (an absolute, escape-free IRI is a slice of your buffer).
- Every derived allocation — prefix expansions, resolved IRIs,
  unescaped lexical forms, generated blank labels and variables — is
  owned by the parser (via its intern table) until `parser_destroy`.
- `parser_destroy` frees everything: the AST, the algebra, and all
  derived strings, in one call. Nothing else needs freeing except
  strings you asked for explicitly (`algebra_to_string`).

Allocation guards in `tests/guards` enforce this in CI: scanning
allocates nothing at all, and parse/translate/destroy cycles are
leak-free including every error path.

## Conformance and testing

The W3C SPARQL syntax suites are vendored under `tests/w3c/` (see its
README for provenance) and run hermetically. The full matrix runs at
both `Term_ID` widths:

```sh
make test    # the whole matrix: unit tests, guards, W3C suites × {64, 32}
make check   # vet + strict-style over every package
```

Or individually:

```sh
odin test sparql            -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/guards      -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/w3c/harness -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/readme      -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
```

The README example above is compiled and asserted by `tests/readme`,
so it cannot drift from the real API.
