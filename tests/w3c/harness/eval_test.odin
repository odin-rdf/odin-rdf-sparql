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
// end to end. The rest arrive as their operators do.

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
