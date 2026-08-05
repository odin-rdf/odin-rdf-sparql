// Package sparql is a SPARQL query engine for the Odin RDF family: a
// query parser (grammar -> AST -> algebra) and, in a later initiative,
// an evaluation engine over odin-rdf-store's match interface. It
// depends on the sibling checkouts through collections -- `rdf:` for
// the data model and format parsers, `store:` for the match interface
// -- and is consumed the same way (see Makefile and ols.json).
//
// The package is under construction (SPARQL-I-0001). The tokenizer
// (scanner.odin, token.odin, error.odin) landed with SPARQL-T-0002; the
// AST and parser core (ast.odin, parser.odin, resolve.odin) with
// SPARQL-T-0003; expressions, FILTER/BIND, and expression projections
// (expr.odin, expr_parse.odin) with SPARQL-T-0004. Property paths,
// aggregates, subqueries, VALUES, and CONSTRUCT/DESCRIBE arrive with
// SPARQL-T-0005.
package sparql
