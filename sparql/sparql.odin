// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and, in a later initiative,
// an evaluation engine over odin-rdf-store's match interface. It
// depends on the sibling checkouts through collections -- `rdf:` for
// the data model and format parsers, `store:` for the match interface
// -- and is consumed the same way (see Makefile and ols.json).
//
// The package is under construction (SPARQL-I-0001). The tokenizer
// lands with SPARQL-T-0002, the parser core with SPARQL-T-0003; until
// then this file only establishes the package.
package sparql
