// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and an evaluation engine over
// odin-rdf-record's snapshots. It depends on the sibling checkouts
// through collections -- `rdf:` for the data model and format parsers,
// `record:` for the system of record -- and is consumed the same way
// (see Makefile and ols.json).
//
// **It is one package** (SPARQL-T-0031). It used to be two: the core
// named no backend and was generic over one, and `sparql/kvstore`
// instantiated it against odin-rdf-store. odin-rdf-record is the one and
// only store from here on (owner, 2026-08-24), so the seam that spanned
// backends is retired rather than re-instantiated, and preparing and
// running a query is this package's own API. `sparql/srj` and
// `sparql/srx` stay separate: they are output formats, not
// instantiations.
//
// The package covers SPARQL Query front to algebra: tokenizer
// (SPARQL-T-0002), AST and parser (SPARQL-T-0003/0004/0005), the §18
// algebra with its ARQ-compatible SSE printer (SPARQL-T-0006), the
// §18.2/§18.4 translation (SPARQL-T-0007), and the SPARQL 1.2 surface
// — triple terms, reified triples, reifiers and annotations, VERSION,
// the 1.2 codepoint-escape restriction (SPARQL-T-0008). The W3C
// SPARQL 1.1 and 1.2 syntax suites run green in tests/w3c.
//
// Evaluation (SPARQL-I-0002) turns that algebra into a stream of
// solutions: plan.odin binds the query's variables to slots and its
// ground terms to record ids, exec.odin runs the plan as a pull-based
// chain of index probes over one snapshot, and
// value.odin/expr_eval.odin evaluate expressions -- the numeric tower,
// effective boolean value, and SPARQL's three-valued treatment of type
// errors -- for FILTER, BIND, and the §17 function library.
//
//
// # Using it
//
// Parsing:
//
//	p: sparql.Parser
//	sparql.parser_init(&p, query_text)
//	defer sparql.parser_destroy(&p)
//	query, ok := sparql.parse(&p)
//	algebra, translated := sparql.translate(&p)
//
// Evaluating, against one snapshot of a record store:
//
//	snap, serr := record.store_latest(&store)
//	defer record.snapshot_release(&snap)
//
//	q: sparql.Query
//	defer sparql.query_destroy(&q)
//	if !sparql.query_init(&q, algebra, snap, sparql.parser_base(&p)) {
//		// q.unsupported names the operator this engine does not implement.
//	}
//	for {
//		row, more := sparql.query_next(&q)
//		if !more { break }
//		// row is indexed by variable slot; query_var_names labels it and
//		// query_term materializes an ID.
//	}
//
// `record.store_at(&store, epoch)` in place of `store_latest` answers
// the same query about the past, and nothing in this package changes:
// the coordinate is the epoch, and the snapshot is the whole of the
// dataset a query sees.
//
// A CONSTRUCT or a DESCRIBE answers with a graph rather than a solution
// sequence: compile the query's template or clause against the prepared
// query's slot table (template_build / describe_build), then
// query_construct / query_describe.
//
//
// # The memory contract
//
// Five things have lifetimes worth stating, because they are not the
// same and nothing in the type system says so.
//
// **Query text is the caller's.** It must stay valid and unmoved for the
// parser's lifetime: AST and algebra strings borrow from it wherever
// they can, so an absolute escape-free IRI in the algebra is a slice of
// your buffer.
//
// **The algebra is the parser's.** `translate` hands back a tree the
// parser owns, along with every string derived from the query text
// (prefix expansions, resolved IRIs, unescaped lexical forms, generated
// blank labels and variables). `parser_destroy` frees all of it in one
// call. A prepared query borrows the algebra, so the parser must outlive
// the query — not the other way round.
//
// **A solution row is the execution's, and it is valid until the next
// pull.** `query_next` returns a `[]record.Term_ID` indexed by variable
// slot, holding `UNBOUND` where a variable is unbound. It is the
// working row itself, not a copy: a consumer that keeps a solution
// copies it. The slice's length and the labelling from `query_var_names`
// / `query_var_internal` are fixed for the query's lifetime.
//
// **The snapshot is the caller's.** `query_init` holds it for the
// query's life and `query_destroy` does not release it — see
// `query_init` for why that is the right way round when the snapshot is
// a validator's candidate rather than one this caller acquired.
//
// **A materialized term is valid until `query_destroy`.** What that
// costs varies by term and the caller never has to know which: record
// hands back a borrow of its dictionary arena for most kinds, an owned
// joined string for a split IRI, and an owned tree for a triple term
// (RECORD-A-0008), and `query_destroy` releases each through record's own
// verb. A consumer that wants a term to outlive the query clones it
// (`rdf.clone_term`) — and must, since closing the store frees the arena
// the borrowing kinds point into.
//
// **A Result_Graph is the caller's.** `query_construct` and
// `query_describe` return a graph that owns every term in it, deep-copied
// out of the store, precisely so that it can outlive both the query and
// the dataset. Free it with `result_graph_destroy`; freeing the query
// does not.
//
// Everything else a query allocates — the plan, the slot table, the
// operator state, the terms the query *computed* rather than read — is
// released by `query_destroy`,
// including after a run abandoned mid-stream and after a `query_init`
// that returned false.
//
//
// # Allocator discipline
//
// Every entry point takes an `allocator := context.allocator` and every
// allocation it makes comes from that one. `parser_init`, `query_init`,
// `template_build`, `describe_build`, `query_construct`, and
// `query_describe` each take theirs, and each frees through the same one:
// nothing in this package allocates from `context.allocator` behind a
// caller who passed something else, and nothing uses
// `context.temp_allocator` across a call boundary.
//
// The streaming operators allocate **nothing per solution**. The row
// buffer, the per-pattern scans, and their bookkeeping are allocated
// once when the query is prepared; pulling a million solutions touches
// none of it. Four deliberate exceptions, each stated where it lives: DISTINCT retains a key per distinct row (it has to), the
// blocking operators (GROUP BY, ORDER BY, MINUS's right side, a
// subquery) materialize their own input, the §17 string functions
// allocate the strings they build, and an inlined literal read during
// expression evaluation needs a buffer to materialize into — those are
// pooled and reused, so they are allocated a bounded number of times
// rather than per solution. `tests/guards` holds all of this to
// the code with a tracking allocator, including the leak-free property
// on every error path.
package sparql
