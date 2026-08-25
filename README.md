# odin-rdf-sparql

[![CI](https://github.com/odin-rdf/odin-rdf-sparql/actions/workflows/ci.yml/badge.svg)](https://github.com/odin-rdf/odin-rdf-sparql/actions/workflows/ci.yml)

A SPARQL query engine for the Odin RDF family: a complete SPARQL 1.1
Query parser with the SPARQL 1.2 surface (triple terms, reified
triples, annotations, VERSION), translating queries to the W3C SPARQL
algebra (§18.2/§18.4), and an evaluation engine that runs that algebra
against an epoch-pinned snapshot of [odin-rdf-record](../odin-rdf-record).
Written in Odin with no external dependencies and no native code, and
validated by the vendored official W3C suites: **352 syntax tests** (154
SPARQL 1.1, 198 SPARQL 1.2) and **537 evaluation tests across 38 suite
directories**, no skip list and no expected-failure file.

This is a top layer of the family stack —
[odin-rdf-parser](../odin-rdf-parser) (formats and data model) →
[odin-rdf-record](../odin-rdf-record) (the system of record: an
append-only hash-chained log replayed into a memory-resident projection)
→ this engine, a peer of [odin-rdf-shacl](../odin-rdf-shacl). SPARQL
Update, the HTTP and Graph Store protocols, federation (SERVICE), and
full-text search are out of scope per the project vision.

## Packages

| Package           | Description                                                             |
| ----------------- | ----------------------------------------------------------------------- |
| `sparql`          | Tokenizer, recursive-descent parser (query text → AST), §18.2/§18.4 translation (AST → algebra), the SSE algebra printer, the evaluation engine, and the prepared-query API |
| `sparql/srj`      | Writes the SPARQL Query Results **JSON** Format (SELECT and ASK)        |
| `sparql/srx`      | Writes the SPARQL Query Results **XML** Format (SELECT and ASK)         |

**The engine is one package.** It used to be two: `sparql` named no
storage backend and was generic over one, and `sparql/kvstore`
instantiated it against odin-rdf-store's LMDB backend. odin-rdf-record is
the one and only store from here on, so that seam is retired rather than
re-instantiated, and preparing and running a query is `sparql`'s own API.
`srj` and `srx` stay separate because they are output formats, not
instantiations. The sibling checkouts are reached through collections —
`rdf:` for the data model, `record:` for the system of record — as
declared in the Makefile and `ols.json`.

The two result writers follow odin-rdf-parser's emitter shape —
`emitter_init` / `emit` / `emitter_finish` for the streaming SELECT
form, and a stateless `emit_boolean` for ASK. They allocate nothing:
solutions are written one at a time straight to an `io.Writer`, so
nothing materializes the result set. CONSTRUCT and DESCRIBE answer with
a graph rather than a result set and are emitted through
odin-rdf-parser's format emitters instead.

```odin
import "sparql/srj"

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
import "sparql"

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
import "rdf:rdf"
import "record:record"
import "record:record/ingest"
import "sparql"

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
	// A store is a directory of log segments, opened once and kept. It
	// must not be copied or moved after store_open: the writer inside it
	// holds a pointer to its own file handles.
	db: record.Store
	_, open_err, load_err, write_err := record.store_open(
		&db, "/var/lib/example/rdf", record.posix_file_ops())
	if open_err != .None || load_err != .None || write_err != .None {
		fmt.eprintfln("cannot open the store: %v %v %v", open_err, load_err, write_err)
		return
	}
	defer record.store_close(&db)

	// Loading is ingest (document → ops) then apply (ops → one epoch).
	// blank_prefix scopes the document's blank-node labels.
	ops, ing_err := ingest.turtle(
		transmute([]byte)string(DATA), nil, context.allocator,
		blank_prefix = "people_", base = "http://example/")
	if ing_err.kind != .None {
		fmt.eprintfln("data did not parse: %v", ing_err.kind)
		return
	}
	defer ingest.ops_destroy(ops, context.allocator)
	if _, _, apply_err := record.apply(&db, {ops = ops}); apply_err != (record.Apply_Error{}) {
		fmt.eprintfln("data did not load: %v", apply_err)
		return
	}

	// The dataset the query answers about. store_at(&db, epoch) in place
	// of store_latest asks the same question of the past.
	snap, snap_err := record.store_latest(&db)
	if snap_err != .None {
		return
	}
	defer record.snapshot_release(&snap)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p)   // the parser owns the algebra
	if _, parsed := sparql.parse(&p); !parsed {
		return
	}
	algebra, _ := sparql.translate(&p)

	// A prepared query borrows the algebra and the snapshot, so both
	// outlive it. query_destroy releases neither.
	q: sparql.Query
	defer sparql.query_destroy(&q)
	if !sparql.query_init(&q, algebra, snap, sparql.parser_base(&p)) {
		fmt.eprintfln("unsupported: %s", q.unsupported)
		return
	}

	names := sparql.query_var_names(&q)
	internal := sparql.query_var_internal(&q)
	for {
		// A row is Term_IDs indexed by variable slot, valid until the
		// next pull. Deep-copy it if you keep it.
		row, more := sparql.query_next(&q)
		if !more {
			break
		}
		for id, slot in row {
			if id == sparql.UNBOUND || internal[slot] {
				continue   // unbound, or a pattern blank node
			}
			#partial switch term in sparql.query_term(&q, id) {
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

`record.posix_file_ops()` is the durable form, and what an application
uses. **The suites in this repository use `record.Mem_FS` and
`record.mem_file_ops(&fs)` instead** — the same store with its log in
memory, so a test needs no directory, no cleanup and no uniqueness, and
the Windows CI runner works even though `record` has no Windows
`File_Ops`. `tests/readme` therefore compiles this example with the
memory seam substituted for the two `posix_file_ops` lines; nothing else
about it differs.

There is **no error to check after a run**. A read on record cannot fail
— the projection is memory-resident — so an exhausted query is the only
kind there is, and the `query_error` this engine had against LMDB is
gone.

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
- The **snapshot is yours**. `query_init` holds it for the query's life
  and `query_destroy` does not release it — see *A query is one snapshot*
  below for why that is the right way round.
- A **term** from `query_term` is valid until `query_destroy`. What that
  costs varies by term and you never have to know which: record hands
  back a borrow of its dictionary arena for most kinds, an owned joined
  string for a split IRI, and an owned tree for a triple term, and
  `query_destroy` releases each through record's own verb. Clone it
  (`rdf.clone_term`) to outlive the query — and you must, since closing
  the store frees the arena the borrowing kinds point into.
- A **Result_Graph** from `query_construct` / `query_describe` owns
  every term in it and is the caller's: free it with
  `sparql.result_graph_destroy`. That is what lets it outlive both the
  query and the store.
- `query_destroy` frees everything else — the plan, the slot table, the
  operator state, and every term the query computed — including after a
  run abandoned mid-stream. A `query_init` that returned false has
  already freed its own allocations, so calling `query_destroy` on one is
  safe and unnecessary in equal measure.

### A query is one snapshot

`query_init` takes a `record.Snapshot` and holds it for the query's life,
so every read a query makes — binding its ground terms, matching each
pattern at each depth, materializing terms at the answer boundary — sees
one dataset. Without that they are independent reads, and a writer
committing between two of them yields a solution assembled from two
datasets, which is not an answer to the query. It is the property the
engine already gives `NOW()` (§17.4.5.1), moved from the clock to the
data.

**A snapshot is a resource: acquire, use, release.** `store_latest`
pins the published head and `store_at(&db, epoch)` pins a past one; the
query reads whichever it is handed and answers about that dataset, with
no source change and no separate as-of entry point. The coordinate is the
epoch.

**It is the caller's, and `query_destroy` does not release it.** That is
deliberate, and it is what makes the one case below work.

Two consequences worth knowing before you meet them:

- **A live snapshot pins one index set**, so a store being written to
  holds the superseded set alive for as long as the query does. A query
  is a fine lifetime for that; a request handler that keeps a `Query`
  open across unrelated work is making a memory-sizing decision.
- **A query can see an uncommitted write — through record's validation
  hook.** A consumer deciding whether a candidate may join the dataset
  wires a `record.Validator` at `store_open`, and `apply` hands its
  `check` *the dataset the write would produce*: head plus changeset, as
  an ordinary snapshot at the epoch it would commit at. So querying a
  candidate is the ordinary call, and there is no second constructor for
  it:

  ```odin
  check :: proc(data: rawptr, candidate: record.Snapshot,
                ops: []record.Resident_Op, allocator: runtime.Allocator) -> bool {
      q: sparql.Query
      defer sparql.query_destroy(&q)   // does not release the candidate
      if !sparql.query_init(&q, algebra, candidate) {
          return true
      }
      _, found := sparql.query_next(&q)
      return !found                     // false under .Enforce refuses the write
  }

  record.store_open(&db, dir, ops, record.Validator{check = check, data = ctx})
  ```

  The candidate is a handle record releases itself, which is why
  `query_init` takes a snapshot it does not own: a query that released it
  would drop a reference it never took. An ordinary query at that moment
  is not refused — it answers about the committed head, because that is
  the snapshot it was handed. The wrong snapshot gives you an answer, not
  a diagnostic.

Allocator discipline: every entry point takes an
`allocator := context.allocator`, allocates only from it, and frees
through it. The streaming operators allocate **nothing per solution**;
the deliberate exceptions are DISTINCT (which must retain what it has
seen), the blocking operators (GROUP BY, ORDER BY, MINUS's right side, a
subquery), and the §17 string functions.

One more exception with the store's name on it: an inlined literal read
during expression evaluation materializes into a buffer the term borrows,
so the engine keeps a small pool of them. They are allocated a bounded
number of times and reused, not allocated per solution.

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
no skip lists, no expected-failure files.

There is **no `Term_ID` width matrix**. It existed because
odin-rdf-store's id width was a build-time choice and this project
compiled the store's sources into its own binaries; odin-rdf-record's
widths are fixed by design, its inline term encoding having been frozen
at first write. `make test` runs once, and the same run on all three CI
runners, because nothing here links native code.

```sh
make test    # unit tests, guards, the README examples, the W3C suites
make check   # vet + strict-style over every package
make bench   # the benchmarks -- see below, this is two builds
```

Or individually:

```sh
odin test sparql            -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record
odin test tests/guards      -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record
odin test tests/w3c/harness -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record
odin test tests/readme      -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record
```

All three README examples above — the parser quick start, the evaluation
walk-through, and the query over a validator's candidate — are compiled
and asserted by `tests/readme`, so they cannot drift from the real API.

## Benchmarks

`bench/` is a synthetic corpus and a fixed query mix — one query per
operator class, from a two-pattern join to a property path — reported one
line per case. It is a regression instrument rather than a claim about
real-world cost.

**`make bench` builds and runs the same workload twice, and the two runs
answer different questions.** Every instrument perturbs what it measures,
so they are two builds rather than two code paths:

- **Timing.** The plain build: the real path through the engine, the real
  allocator, nothing wrapped. Best of five after a warm-up. Wall clock
  only.
- **Instrumented.** Built with `-define:SPARQL_COUNT_READS=true`, which
  compiles a tally into the engine's read seam (`sparql/counting.odin`).
  It reports how many questions evaluating each query asked the store,
  and **asserts them against pinned integers** in `bench/config.odin`.
  No timing is taken here and none should be quoted from it.

The pins are the point. A read count is a property of the plan and the
executor rather than of the machine, so it can be an exact integer that
fails the build when it moves — which is stricter than any timing
threshold could be, and is what proved the port to odin-rdf-record moved
cost rather than behaviour: fourteen of the sixteen pins taken against
odin-rdf-store reproduce against record to the integer. A pin is not a
claim that a number must never move, only that it must never move
unnoticed; re-pinning is a deliberate edit with a reason in the commit.

A read counter cannot see everything, and one verb exists because of it.
`candidates` is `record.range_len` summed over every window the engine
opened — what the store was *handed*, where the other verbs count what it
gave back. record filters a residual pattern inside its own scan loop, so
without it a query whose window is the entire store looks identical to one
that read a prefix.
