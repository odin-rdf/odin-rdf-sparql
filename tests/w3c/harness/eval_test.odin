package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Evaluation suites are enabled one directory at a time, and an enabled
// directory must be fully green against **both** backends — no skip
// lists, no expected-failure files, and an entry the engine cannot yet
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
// than solution sequences. The rest arrive as their operators do.
//
// sparql10-expr-builtin is *not* enabled, and it is worth saying why: 24
// of its 25 entries pass, and the one that does not — dawg-lang-3,
// `?x :p "string"@EN` against `"string"@en` — fails for a reason that
// has nothing to do with §17. Neither the RDF parser nor the SPARQL
// parser normalizes the case of a language tag, so the query's term and
// the stored term are different keys in the dictionary and find_term
// misses. Fixing it means normalizing on both sides of the family, which
// is a data-model change rather than a function-library one.

@(test)
test_eval_sparql10_triple_match_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-triple-match", .Memstore)
}

@(test)
test_eval_sparql10_triple_match_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-triple-match", .Kvstore)
}

@(test)
test_eval_sparql10_basic_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-basic", .Memstore)
}

@(test)
test_eval_sparql10_basic_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-basic", .Kvstore)
}

@(test)
test_eval_sparql10_ask_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-ask", .Memstore)
}

@(test)
test_eval_sparql10_ask_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-ask", .Kvstore)
}

@(test)
test_eval_sparql10_bnode_coreference_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bnode-coreference", .Memstore)
}

@(test)
test_eval_sparql10_bnode_coreference_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bnode-coreference", .Kvstore)
}

@(test)
test_eval_sparql10_expr_equals_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-equals", .Memstore)
}

@(test)
test_eval_sparql10_expr_equals_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-equals", .Kvstore)
}

@(test)
test_eval_sparql10_type_promotion_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-type-promotion", .Memstore)
}

@(test)
test_eval_sparql10_type_promotion_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-type-promotion", .Kvstore)
}


@(test)
test_eval_sparql10_boolean_effective_value_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-boolean-effective-value", .Memstore)
}

@(test)
test_eval_sparql10_boolean_effective_value_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-boolean-effective-value", .Kvstore)
}

@(test)
test_eval_sparql10_bound_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bound", .Memstore)
}

@(test)
test_eval_sparql10_bound_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-bound", .Kvstore)
}

@(test)
test_eval_sparql10_distinct_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-distinct", .Memstore)
}

@(test)
test_eval_sparql10_distinct_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-distinct", .Kvstore)
}

@(test)
test_eval_sparql10_open_world_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-open-world", .Memstore)
}

@(test)
test_eval_sparql10_open_world_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-open-world", .Kvstore)
}

@(test)
test_eval_sparql10_optional_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional", .Memstore)
}

@(test)
test_eval_sparql10_optional_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional", .Kvstore)
}

@(test)
test_eval_sparql10_reduced_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-reduced", .Memstore)
}

@(test)
test_eval_sparql10_reduced_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-reduced", .Kvstore)
}


@(test)
test_eval_algebra_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-algebra", .Memstore)
}

@(test)
test_eval_algebra_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-algebra", .Kvstore)
}

@(test)
test_eval_expr_ops_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-ops", .Memstore)
}

@(test)
test_eval_expr_ops_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-expr-ops", .Kvstore)
}

@(test)
test_eval_optional_filter_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional-filter", .Memstore)
}

@(test)
test_eval_optional_filter_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-optional-filter", .Kvstore)
}

@(test)
test_eval_bind_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bind", .Memstore)
}

@(test)
test_eval_bind_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bind", .Kvstore)
}


@(test)
test_eval_dataset_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-dataset", .Memstore)
}

@(test)
test_eval_dataset_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-dataset", .Kvstore)
}

@(test)
test_eval_exists_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-exists", .Memstore)
}

@(test)
test_eval_exists_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-exists", .Kvstore)
}

@(test)
test_eval_bindings_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bindings", .Memstore)
}

@(test)
test_eval_bindings_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-bindings", .Kvstore)
}

@(test)
test_eval_functions_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-functions", .Memstore)
}

@(test)
test_eval_functions_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-functions", .Kvstore)
}

@(test)
test_eval_regex_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-regex", .Memstore)
}

@(test)
test_eval_regex_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-regex", .Kvstore)
}

@(test)
test_eval_sparql10_cast_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-cast", .Memstore)
}

@(test)
test_eval_sparql10_cast_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-cast", .Kvstore)
}

@(test)
test_eval_sparql11_cast_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-cast", .Memstore)
}

@(test)
test_eval_sparql11_cast_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-cast", .Kvstore)
}

@(test)
test_eval_sparql11_aggregates_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-aggregates", .Memstore)
}

@(test)
test_eval_sparql11_aggregates_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-aggregates", .Kvstore)
}

@(test)
test_eval_sparql11_grouping_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-grouping", .Memstore)
}

@(test)
test_eval_sparql11_grouping_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-grouping", .Kvstore)
}

@(test)
test_eval_sparql10_sort_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-sort", .Memstore)
}

@(test)
test_eval_sparql10_sort_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-sort", .Kvstore)
}

@(test)
test_eval_sparql10_solution_seq_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-solution-seq", .Memstore)
}

@(test)
test_eval_sparql10_solution_seq_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-solution-seq", .Kvstore)
}

@(test)
test_eval_sparql11_project_expression_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-project-expression", .Memstore)
}

@(test)
test_eval_sparql11_project_expression_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-project-expression", .Kvstore)
}

@(test)
test_eval_sparql11_property_path_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-property-path", .Memstore)
}

@(test)
test_eval_sparql11_property_path_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-property-path", .Kvstore)
}

@(test)
test_eval_sparql10_construct_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-construct", .Memstore)
}

@(test)
test_eval_sparql10_construct_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql10-construct", .Kvstore)
}

@(test)
test_eval_sparql11_construct_memstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-construct", .Memstore)
}

@(test)
test_eval_sparql11_construct_kvstore :: proc(t: ^testing.T) {
	run_eval_suite(t, "sparql11-construct", .Kvstore)
}

// run_eval_suite runs every evaluation entry of a directory: load,
// evaluate, compare. The suite's pinned entry count is asserted here too,
// so a manifest-reader regression cannot quietly shrink what "fully
// green" covers.
run_eval_suite :: proc(t: ^testing.T, dir: string, backend: Backend) {
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

	passed, syntax_only := 0, 0
	for e in entries {
		if !strings.contains(e.type_str, "QueryEvaluationTest") {
			// A syntax entry mixed into an evaluation directory is
			// covered by the syntax-level guard in readers_test.odin.
			syntax_only += 1
			continue
		}

		actual, status, detail := evaluate_entry(suite, e, backend)
		defer result_set_destroy(&actual)
		if !testing.expectf(
			t,
			status == .Ok,
			"%s/%s [%s] (%s): %v — %s",
			suite.dir,
			e.id,
			backend_name(backend),
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
			"%s/%s [%s] (%s): %s\n--- got ---\n%s--- want ---\n%s",
			suite.dir,
			e.id,
			backend_name(backend),
			e.name,
			reason,
			actual_text,
			expected_text,
		)
	}
	log.infof(
		"%s [%s]: %d/%d evaluation tests passed (%d syntax-only entries)",
		suite.dir,
		backend_name(backend),
		passed,
		len(entries) - syntax_only,
		syntax_only,
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
