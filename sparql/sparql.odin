// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and, in a later initiative,
// an evaluation engine over odin-rdf-store's match interface. It
// depends on the sibling checkouts through collections -- `rdf:` for
// the data model and format parsers, `store:` for the match interface
// -- and is consumed the same way (see Makefile and ols.json).
//
// The package is under construction (SPARQL-I-0001). The parser is
// complete for SPARQL 1.1 Query: tokenizer (SPARQL-T-0002), AST and
// parser core (SPARQL-T-0003), expressions and FILTER/BIND
// (SPARQL-T-0004), and the full grammar — property paths, aggregates
// with GROUP BY/HAVING, subqueries, VALUES, CONSTRUCT/DESCRIBE, MINUS
// — with the W3C SPARQL 1.1 syntax suites green (SPARQL-T-0005).
// Algebra translation follows (SPARQL-T-0006/0007).
package sparql
