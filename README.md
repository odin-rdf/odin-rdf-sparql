# odin-rdf-sparql

[![CI](https://github.com/odin-rdf/odin-rdf-sparql/actions/workflows/ci.yml/badge.svg)](https://github.com/odin-rdf/odin-rdf-sparql/actions/workflows/ci.yml)

A SPARQL query engine for the Odin RDF family: a complete SPARQL 1.1
Query parser with the SPARQL 1.2 surface (triple terms, reified
triples, annotations, VERSION), translating queries to the W3C SPARQL
algebra (§18.2/§18.4), and an evaluation engine that runs that algebra
against any odin-rdf-store backend through the match interface alone.
Written in Odin with no external dependencies, and validated by the
vendored official W3C suites: **352 syntax tests** (154 SPARQL 1.1, 198
SPARQL 1.2) and **483 evaluation tests across 35 suite directories**,
every one of them run against **both** storage backends at **both**
`Term_ID` widths.

This is the third layer of the family stack —
[odin-rdf-parser](../odin-rdf-parser) (formats and data model) →
[odin-rdf-store](../odin-rdf-store) (storage, match interface) → this
engine. SPARQL Update, the HTTP and Graph Store protocols, federation
(SERVICE), and full-text search are out of scope per the project vision.

## Packages

| Package           | Description                                                             |
| ----------------- | ----------------------------------------------------------------------- |
| `sparql`          | Tokenizer, recursive-descent parser (query text → AST), §18.2/§18.4 translation (AST → algebra), the SSE algebra printer, and the backend-independent evaluation engine |
| `sparql/srj`      | Writes the SPARQL Query Results **JSON** Format (SELECT and ASK)        |
| `sparql/srx`      | Writes the SPARQL Query Results **XML** Format (SELECT and ASK)         |
| `sparql/memstore` | The engine instantiated against the in-memory backend                   |
| `sparql/kvstore`  | The engine instantiated against the persistent (LMDB) backend           |

`sparql` names no storage backend and imports none, so a program that
only wants an in-memory store never links LMDB. The sibling checkouts
are reached through collections — `rdf:` for the data model, `store:`
for the match interface — as declared in the Makefile and `ols.json`.

The two result writers follow odin-rdf-parser's emitter shape —
`emitter_init` / `emit` / `emitter_finish` for the streaming SELECT
form, and a stateless `emit_boolean` for ASK. They allocate nothing:
solutions are written one at a time straight to an `io.Writer`, so
nothing materializes the result set. CONSTRUCT and DESCRIBE answer with
a graph rather than a result set and are emitted through
odin-rdf-parser's format emitters instead.

```odin
import srj "sparql/srj"

e: srj.Emitter
srj.emitter_init(&e, w, []string{"s", "o"}) // w: io.Writer
for row in solutions {
    srj.emit(&e, row) // []rdf.Term aligned to the variables; nil is unbound
}
srj.emitter_finish(&e)
```

## Quick start

### Parsing a query and printing its algebra

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

### Evaluating a query against a store

```odin
import "core:fmt"
import rdf "rdf:rdf"
import store "store:store"
import memstore "store:store/memstore"

import sparql "sparql"
import sparql_memstore "sparql/memstore"

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

evaluate :: proc() {
	// A dictionary and a dataset are the in-memory backend's two halves.
	dictionary: memstore.Dictionary
	memstore.dictionary_init(&dictionary)
	defer memstore.dictionary_destroy(&dictionary)
	dataset: memstore.Dataset
	memstore.dataset_init(&dataset)
	defer memstore.dataset_destroy(&dataset)
	_, load_err := memstore.load_turtle(
		&dictionary, &dataset, transmute([]byte)string(DATA), "http://example/")
	if load_err.message != "" {
		fmt.eprintfln("data did not load: %s", load_err.message)
		return
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p)   // the parser owns the algebra
	if _, parsed := sparql.parse(&p); !parsed {
		return
	}
	algebra, _ := sparql.translate(&p)

	// A prepared query borrows the algebra, so the parser outlives it.
	q: sparql_memstore.Query
	defer sparql_memstore.query_destroy(&q)
	if !sparql_memstore.query_init(&q, algebra, &dictionary, &dataset, sparql.parser_base(&p)) {
		fmt.eprintfln("unsupported: %s", q.unsupported)
		return
	}

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
				continue   // unbound, or a pattern blank node
			}
			#partial switch term in sparql_memstore.query_term(&q, id) {
			case rdf.IRI:
				fmt.printf("?%s=<%s> ", names[slot], string(term))
			case rdf.Literal:
				fmt.printf("?%s=%q ", names[slot], term.lexical)
			}
		}
		fmt.println()
	}
	// ?name="Alice" ?friend="Bob"
	// ?name="Bob"
}
```

`sparql/kvstore` is the same code against the persistent backend: one
`^kvstore.Store` in place of the dictionary/dataset pair, and
`query_error` afterwards, because a read from LMDB can fail and an
exhausted query and a failed one must not look alike.

CONSTRUCT and DESCRIBE answer with a graph rather than a solution
sequence — compile the template or the clause against the prepared
query's slot table (`sparql.template_build` / `sparql.describe_build`),
then call `query_construct` / `query_describe`.

## Memory model

The family's contract. The parser's half:

- The query text is caller-owned and must stay valid and unmoved for
  the parser's lifetime; AST and algebra strings borrow from it where
  possible (an absolute, escape-free IRI is a slice of your buffer).
- Every derived allocation — prefix expansions, resolved IRIs,
  unescaped lexical forms, generated blank labels and variables — is
  owned by the parser (via its intern table) until `parser_destroy`.
- `parser_destroy` frees everything: the AST, the algebra, and all
  derived strings, in one call. Nothing else needs freeing except
  strings you asked for explicitly (`algebra_to_string`).

The evaluator's half:

- A prepared query **borrows the algebra**, so the parser must outlive
  the query.
- A **solution row** is the execution's working row, valid until the
  next `query_next`. A consumer that keeps a solution copies it.
- A **term** from `query_term` is valid until `query_destroy` on both
  backends — memstore borrows its dictionary's storage, kvstore builds
  the term and frees it later, and the contract is the same either way.
  Clone it to outlive the query.
- A **Result_Graph** from `query_construct` / `query_describe` owns
  every term in it and is the caller's: free it with
  `sparql.result_graph_destroy`. That is what lets it outlive both the
  query and the store.
- `query_destroy` frees everything else — the plan, the slot table, the
  operator state, every match iterator a run left open, and every term
  the query computed — including after a run abandoned mid-stream and
  after a `query_init` that returned false.

Allocator discipline: every entry point takes an
`allocator := context.allocator`, allocates only from it, and frees
through it. The streaming operators allocate **nothing per solution**;
the deliberate exceptions are DISTINCT (which must retain what it has
seen), the blocking operators (GROUP BY, ORDER BY, MINUS's right side, a
subquery), and the §17 string functions.

Allocation guards in `tests/guards` enforce all of it in CI: scanning
allocates nothing at all; parse/translate/destroy and
prepare/run/destroy cycles are leak-free including every error path and
every mid-stream abandonment; a 5000-solution join and a 500-solution
triple-term join both stream at zero allocations; and grouping and
property-path traversal are measured to be bounded by their groups and
by the graph rather than by their input.

## Conformance and testing

The W3C SPARQL syntax and evaluation suites are vendored under
`tests/w3c/` (see its README for provenance and for the per-directory
enablement discipline) and run hermetically. Enabled means fully green:
no skip lists, no expected-failure files. The full matrix runs at both
`Term_ID` widths:

```sh
make test    # the whole matrix: unit tests, guards, W3C suites × {64, 32}
make check   # vet + strict-style over every package
```

Or individually:

```sh
odin test sparql            -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test sparql/memstore   -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test sparql/kvstore    -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/guards      -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/w3c/harness -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
odin test tests/readme      -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store
```

Both README examples above are compiled and asserted by `tests/readme`,
so they cannot drift from the real API.
