// The vendored evaluation suites, with the pinned entry count that
// guards against a manifest-reader regression silently dropping tests.
//
// base is the upstream location a suite's files resolve against, which
// is what a test's query, data documents, and named graphs are named by
// — the sparql10 directories under the DAWG's data-r2 tree, the
// sparql11 ones under the SPARQL 1.1 test tree. A graph loaded from
// qt:graphData is named base + the document's file name, which is
// exactly the IRI those tests' GRAPH clauses use.
//
// Membership here means vendored, not enabled: which suites the
// evaluator is held to is a separate, per-task decision recorded in the
// evaluation tests. Everything listed is read end to end by
// readers_test.odin regardless, so the expected-result readers are held
// to every file the suites ship from the day it is vendored.
package w3c

DATA_R2 :: "http://www.w3.org/2001/sw/DataAccess/tests/data-r2/"
DATA_SPARQL11 :: "http://www.w3.org/2009/sparql/docs/tests/data-sparql11/"
SPARQL12 :: "https://w3c.github.io/rdf-tests/sparql/sparql12/"

Suite :: struct {
	dir:     string, // directory under tests/w3c/
	base:    string, // upstream IRI the directory's files resolve against
	entries: int, // pinned mf:entries count
}

EVAL_SUITES := [?]Suite {
	{"sparql10-algebra", DATA_R2 + "algebra/", 14},
	{"sparql10-ask", DATA_R2 + "ask/", 4},
	{"sparql10-basic", DATA_R2 + "basic/", 27},
	{"sparql10-bnode-coreference", DATA_R2 + "bnode-coreference/", 1},
	{"sparql10-boolean-effective-value", DATA_R2 + "boolean-effective-value/", 7},
	{"sparql10-bound", DATA_R2 + "bound/", 1},
	{"sparql10-cast", DATA_R2 + "cast/", 7},
	{"sparql10-construct", DATA_R2 + "construct/", 5},
	{"sparql10-dataset", DATA_R2 + "dataset/", 12},
	{"sparql10-distinct", DATA_R2 + "distinct/", 11},
	{"sparql10-expr-builtin", DATA_R2 + "expr-builtin/", 25},
	{"sparql10-expr-equals", DATA_R2 + "expr-equals/", 15},
	{"sparql10-expr-ops", DATA_R2 + "expr-ops/", 18},
	{"sparql10-graph", DATA_R2 + "graph/", 17},
	{"sparql10-i18n", DATA_R2 + "i18n/", 5},
	{"sparql10-open-world", DATA_R2 + "open-world/", 18},
	{"sparql10-optional", DATA_R2 + "optional/", 7},
	{"sparql10-optional-filter", DATA_R2 + "optional-filter/", 5},
	{"sparql10-reduced", DATA_R2 + "reduced/", 2},
	{"sparql10-regex", DATA_R2 + "regex/", 21},
	{"sparql10-solution-seq", DATA_R2 + "solution-seq/", 13},
	{"sparql10-sort", DATA_R2 + "sort/", 14},
	{"sparql10-triple-match", DATA_R2 + "triple-match/", 4},
	{"sparql10-type-promotion", DATA_R2 + "type-promotion/", 30},
	{"sparql11-aggregates", DATA_SPARQL11 + "aggregates/", 47},
	{"sparql11-bind", DATA_SPARQL11 + "bind/", 10},
	{"sparql11-bindings", DATA_SPARQL11 + "bindings/", 11},
	{"sparql11-cast", DATA_SPARQL11 + "cast/", 6},
	{"sparql11-construct", DATA_SPARQL11 + "construct/", 7},
	{"sparql11-exists", DATA_SPARQL11 + "exists/", 6},
	{"sparql11-functions", DATA_SPARQL11 + "functions/", 75},
	{"sparql11-grouping", DATA_SPARQL11 + "grouping/", 6},
	{"sparql11-negation", DATA_SPARQL11 + "negation/", 12},
	{"sparql11-project-expression", DATA_SPARQL11 + "project-expression/", 7},
	{"sparql11-property-path", DATA_SPARQL11 + "property-path/", 33},
	{"sparql11-subquery", DATA_SPARQL11 + "subquery/", 14},
	{"sparql12-eval-triple-terms", SPARQL12 + "eval-triple-terms/", 41},
	{"sparql12-expression", SPARQL12 + "expression/", 5},
	{"sparql12-grouping", SPARQL12 + "grouping/", 2},
	{"sparql12-rdf11", SPARQL12 + "rdf11/", 3},
}
