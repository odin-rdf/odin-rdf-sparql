// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and, in a later initiative,
// an evaluation engine over odin-rdf-store's match interface. It
// depends on the sibling checkouts through collections -- `rdf:` for
// the data model and format parsers, `store:` for the match interface
// -- and is consumed the same way (see Makefile and ols.json).
//
// The package covers SPARQL Query front to algebra: tokenizer
// (SPARQL-T-0002), AST and parser (SPARQL-T-0003/0004/0005), the §18
// algebra with its ARQ-compatible SSE printer (SPARQL-T-0006), the
// §18.2/§18.4 translation (SPARQL-T-0007), and the SPARQL 1.2 surface
// — triple terms, reified triples, reifiers and annotations, VERSION,
// the 1.2 codepoint-escape restriction (SPARQL-T-0008). The W3C
// SPARQL 1.1 and 1.2 syntax suites run green in tests/w3c. Typical
// use: parser_init → parse → translate → walk p.algebra (or
// algebra_to_string for the SSE view); parser_destroy frees it all.
package sparql
