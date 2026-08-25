package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Evaluation suites are enabled one directory at a time, and an enabled
// directory must be fully green — no skip lists, no expected-failure
// files, and an entry the engine cannot yet
// evaluate counts as a failure rather than a pass. That is the same rule
// the syntax suites follow, and it is what keeps "enabled" meaning
// something.
//
// SPARQL-T-0011 enabled the two directories whose queries are basic
// graph patterns and nothing else. SPARQL-T-0012 added the four the
// expression engine unlocks — equality and the value space, numeric
// promotion, ASK, blank-node coreference. SPARQL-T-0013 adds the six the
// algebra operators unlock: OPTIONAL, DISTINCT and REDUCED over real
// solution sequences, BOUND, EBV in context, and open-world semantics
// end to end. SPARQL-T-0014 adds the four the §17 function library
// unlocks: the 75-entry functions directory, the two cast directories,
// and regex. SPARQL-T-0015 adds the five the blocking operators unlock:
// the 42-entry aggregates directory, grouping, the two sorting
// directories (sort, and solution-seq for the slice-after-sort layering),
// and project-expression, whose seventh entry was the one ORDER BY held
// back. SPARQL-T-0016 adds the 33-entry property-path directory, which is
// the whole of §18.4 in one place: the repeat forms and their zero-length
// cases, negated property sets in both directions, and the precedence
// tests that pin alternation and sequence as bags against the repeats as
// sets. SPARQL-T-0017 adds the two CONSTRUCT directories, whose
// expectations are RDF graphs compared up to blank-node renaming rather
// than solution sequences. SPARQL-T-0020 adds the last two the engine's
// own semantics held back — sparql10-graph and sparql11-negation, one
// entry short each, and the same entry twice: what a GRAPH clause does to
// an operator inside it that sees more than one solution at a time. The
// rest arrive as their operators do.
//
// **sparql10-expr-builtin is enabled as of SPARQL-T-0033, and the port
// is what enabled it.** It sat out for one entry: dawg-lang-3,
// `?x :p "string"@EN` against `"string"@en`, which failed because
// neither the RDF parser nor the SPARQL parser normalized the case of a
// language tag, so the query's term and the stored term were different
// keys in odin-rdf-store's dictionary and `find_term` missed. The note
// here used to say that fixing it meant normalizing on both sides of the
// family — a data-model change rather than a function-library one.
//
// odin-rdf-record made it, for its own reasons: its canonical term
// encoding folds a language tag to lowercase on intern, so `"string"@EN`
// and `"string"@en` are one term. That is RDF 1.1's own rule (Concepts
// §3.3: the value space of language tags is lower case) and the DAWG
// expects exactly this match, so the entry passes for the right reason
// rather than by luck. All 25 pass, and the directory is held to the
// same standard as the rest.
//
// Two directories are still out, both for reasons the port did not touch:
// `sparql11-subquery` (ten entries whose data is RDF/XML, which
// odin-rdf-parser does not implement — the count is pinned in
// readers_test.odin) and `sparql10-i18n` (`normalization-02` expects an
// IRI to match unnormalized, and the two parsers disagree: Turtle's
// removes dot segments where SPARQL's does not. Measured at
// SPARQL-T-0033; it is parser-side and belongs to the family's IRI
// normalization question, not to any store).
//
// *(Amended 2026-08-25: the last clause is wrong. It is **not** a
// normalization question. The entry's data holds both the normalized IRI
// and the as-written one, the query asks for the as-written one byte for
// byte, and it expects that one and explicitly not the other — so it
// asserts the do-nothing policy this family already has. It fails because
// odin-rdf-parser's Turtle parser runs an *absolute* IRI through RFC 3986
// par. 5.2 reference resolution and strips its dot segments, base or no
// base, which Turtle par. 6.3 does not permit; this engine's query parser
// is the one behaving correctly. Filed as `RDF-T-0026` against the
// parser, and this directory waits on that rather than on
// `SPARQL-T-0021`.)*
//
// *(Amended 2026-08-25, later the same day: `RDF-T-0026` is fixed. The
// parser's `resolve()` returns a reference that carries a scheme byte
// for byte — base or no base — and never enters §5.2, so `:s2`'s object
// is now the IRI the document wrote. **`sparql10-i18n` is enabled below
// at 5/5**, and nothing in this engine changed to get there: the entry
// was always asking for the do-nothing policy this side already had.
// **One directory is out now** — `sparql11-subquery`, whose reason is
// permanent.)*

@(test)
test_eval_sparql10_expr_builtin :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-builtin")
}

@(test)
test_eval_sparql10_triple_match :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-triple-match")
}

@(test)
test_eval_sparql10_basic :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-basic")
}

@(test)
test_eval_sparql10_ask :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-ask")
}

@(test)
test_eval_sparql10_bnode_coreference :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bnode-coreference")
}

@(test)
test_eval_sparql10_expr_equals :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-equals")
}

@(test)
test_eval_sparql10_type_promotion :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-type-promotion")
}


@(test)
test_eval_sparql10_boolean_effective_value :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-boolean-effective-value")
}

@(test)
test_eval_sparql10_bound :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bound")
}

@(test)
test_eval_sparql10_distinct :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-distinct")
}

@(test)
test_eval_sparql10_open_world :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-open-world")
}

@(test)
test_eval_sparql10_optional :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional")
}

@(test)
test_eval_sparql10_reduced :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-reduced")
}


@(test)
test_eval_algebra :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-algebra")
}

@(test)
test_eval_expr_ops :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-ops")
}

@(test)
test_eval_optional_filter :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional-filter")
}

@(test)
test_eval_bind :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bind")
}


@(test)
test_eval_dataset :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-dataset")
}

@(test)
test_eval_exists :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-exists")
}

@(test)
test_eval_bindings :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bindings")
}

@(test)
test_eval_functions :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-functions")
}

@(test)
test_eval_regex :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-regex")
}

@(test)
test_eval_sparql10_cast :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-cast")
}

@(test)
test_eval_sparql11_cast :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-cast")
}

@(test)
test_eval_sparql11_aggregates :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-aggregates")
}

@(test)
test_eval_sparql11_grouping :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-grouping")
}

@(test)
test_eval_sparql10_sort :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-sort")
}

@(test)
test_eval_sparql10_solution_seq :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-solution-seq")
}

@(test)
test_eval_sparql11_project_expression :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-project-expression")
}

@(test)
test_eval_sparql11_property_path :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-property-path")
}

@(test)
test_eval_sparql10_construct :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-construct")
}

@(test)
test_eval_sparql11_construct :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-construct")
}

// The SPARQL 1.2 evaluation directories (SPARQL-T-0018). The three
// mf:UpdateEvaluationTest entries in eval-triple-terms are counted as
// out-of-engine-scope entries by run_eval_suite, the same way a syntax
// entry in an evaluation directory is.
@(test)
test_eval_sparql12_eval_triple_terms :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql12-eval-triple-terms")
}

@(test)
test_eval_sparql12_expression :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql12-expression")
}

@(test)
test_eval_sparql12_grouping :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql12-grouping")
}

@(test)
test_eval_sparql12_rdf11 :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql12-rdf11")
}

// The two GRAPH-scoping directories (SPARQL-T-0020). Each was one entry
// short of green, and both entries were the same reading of §18.5: the
// variable a GRAPH clause binds is not in scope inside the clause, so
// `Graph(?g, P)` evaluates P against one graph at a time and joins ?g on
// afterwards. Whichever of the two is read first, the other stops being
// a surprise — see Plan_Graph_Bind.
@(test)
test_eval_sparql10_graph :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-graph")
}

@(test)
test_eval_sparql11_negation :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-negation")
}

// The last directory a bug held back, and the bug was not here
// (`RDF-T-0026`, filed from `SPARQL-T-0021`'s split). `normalization-02`
// stores `eXAMPLE://a/./b/../b/%63/%7bfoo%7d#xyz` and asks for it byte
// for byte, expecting that term and explicitly not the normalized one
// beside it in the data; it failed while odin-rdf-parser resolved
// absolute IRIs it should have left alone. Enabled at 5/5 with the
// parser fixed — a suite entry asserting that a term survives loading
// unchanged, which is worth having asserted whatever else moves.
@(test)
test_eval_sparql10_i18n :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-i18n")
}

// run_eval_suite runs every evaluation entry of a directory: load,
// evaluate, compare. The suite's pinned entry count is asserted here too,
// so a manifest-reader regression cannot quietly shrink what "fully
// green" covers.
run_eval_suite :: proc(t: ^testing.T, dir: string) {
	suite, found := find_suite(dir)
	if !testing.expectf(t, found, "%s is not a vendored evaluation suite", dir) {
		return
	}

	manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
	defer delete(manifest_path)
	manifest_data, manifest_err := os.read_entire_file(manifest_path, context.allocator)
	if !testing.expectf(t, manifest_err == nil, "cannot read manifest %s: %v", manifest_path, manifest_err) {
		return
	}
	defer delete(manifest_data)

	entries := parse_manifest(string(manifest_data))
	defer destroy_entries(&entries)
	testing.expectf(
		t,
		len(entries) == suite.entries,
		"%s: manifest yielded %d entries, expected %d — reader regression?",
		suite.dir,
		len(entries),
		suite.entries,
	)

	passed, not_evaluated := 0, 0
	for e in entries {
		if !strings.contains(e.type_str, "QueryEvaluationTest") {
			// A syntax entry mixed into an evaluation directory is
			// covered by the syntax-level guard in readers_test.odin; a
			// SPARQL Update entry is out of the engine's scope by the
			// vision and counted there too. Either way it is accounted
			// for, never silently skipped.
			not_evaluated += 1
			continue
		}

		actual, status, detail := evaluate_entry(suite, e)
		defer result_set_destroy(&actual)
		if !testing.expectf(
			t,
			status == .Ok,
			"%s/%s (%s): %v — %s",
			suite.dir,
			e.id,
			e.name,
			status,
			detail,
		) {
			continue
		}

		expected_path, _ := filepath.join({SUITE_ROOT, suite.dir, e.result})
		defer delete(expected_path)
		expected_base := strings.concatenate({suite.base, e.result})
		defer delete(expected_base)
		expected, read_ok := read_expected(expected_path, expected_base)
		if !testing.expectf(t, read_ok, "%s/%s: cannot read expectation %q", suite.dir, e.id, e.result) {
			continue
		}
		defer result_set_destroy(&expected)

		options := Compare_Options {
			ordered         = query_is_ordered(suite, e),
			lax_cardinality = e.lax_cardinality,
		}
		equal, reason := results_equal(&actual, &expected, options)
		if equal {
			passed += 1
			continue
		}

		actual_text := result_set_to_string(&actual)
		defer delete(actual_text)
		expected_text := result_set_to_string(&expected)
		defer delete(expected_text)
		testing.expectf(
			t,
			false,
			"%s/%s (%s): %s\n--- got ---\n%s--- want ---\n%s",
			suite.dir,
			e.id,
			e.name,
			reason,
			actual_text,
			expected_text,
		)
	}
	log.infof(
		"%s: %d/%d evaluation tests passed (%d entries not evaluated)",
		suite.dir,
		passed,
		len(entries) - not_evaluated,
		not_evaluated,
	)
}

@(private = "file")
find_suite :: proc(dir: string) -> (suite: Suite, found: bool) {
	for candidate in EVAL_SUITES {
		if candidate.dir == dir {
			return candidate, true
		}
	}
	return {}, false
}
