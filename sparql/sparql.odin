// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and an evaluation engine over
// odin-rdf-store's match interface. It depends on the sibling checkouts
// through collections -- `rdf:` for the data model and format parsers,
// `store:` for the match interface -- and is consumed the same way (see
// Makefile and ols.json).
//
// This package names no storage backend and imports none. Evaluation is
// generic over the backend and is instantiated by the two sibling
// packages `sparql/memstore` and `sparql/kvstore`, which is what a
// consumer imports to run a query; a program that only wants an
// in-memory store therefore never links LMDB (SPARQL-T-0011).
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
// ground terms to store IDs, exec.odin runs the plan as a pull-based
// chain of index probes over the store's match interface, and
// value.odin/expr_eval.odin evaluate expressions -- the numeric tower,
// effective boolean value, and SPARQL's three-valued treatment of type
// errors -- for FILTER.
//
// Typical use: parser_init → parse → translate → walk p.algebra (or
// algebra_to_string for the SSE view); parser_destroy frees it all. To
// evaluate, hand the algebra to one of the instantiation packages —
// query_init → query_next → query_destroy.
package sparql
