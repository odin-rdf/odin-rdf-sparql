package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import sparql "../../../sparql"

SUITE_ROOT :: #directory + ".."

// Test-file IRIs resolve against the upstream suite location, per the
// W3C convention.
DATA_SPARQL11 :: "http://www.w3.org/2009/sparql/docs/tests/data-sparql11/"

// Suite directories are enabled individually; once enabled, a
// directory must be fully green — no skip lists, no expected-failure
// files. Positive syntax tests and evaluation tests must parse (the
// evaluation itself belongs to the evaluation initiative); negative
// syntax tests must be rejected. An unhandled mf:type fails hard:
// nothing may be silently skipped.

@(test)
test_w3c_sparql11_syntax_query :: proc(t: ^testing.T) {
	run_suite(t, "sparql11-syntax-query", DATA_SPARQL11 + "syntax-query/", 94)
}

@(test)
test_w3c_sparql11_aggregates :: proc(t: ^testing.T) {
	run_suite(t, "sparql11-aggregates", DATA_SPARQL11 + "aggregates/", 47)
}

@(test)
test_w3c_sparql11_construct :: proc(t: ^testing.T) {
	run_suite(t, "sparql11-construct", DATA_SPARQL11 + "construct/", 7)
}

@(test)
test_w3c_sparql11_grouping :: proc(t: ^testing.T) {
	run_suite(t, "sparql11-grouping", DATA_SPARQL11 + "grouping/", 6)
}

// run_suite runs every manifest entry. expected_count pins the entry
// count recorded when the suite was vendored — the guard against a
// manifest-reader regression silently dropping tests.
run_suite :: proc(t: ^testing.T, suite: string, base_prefix: string, expected_count: int) {
	manifest_path, _ := filepath.join({SUITE_ROOT, suite, "manifest.ttl"})
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
		len(entries) == expected_count,
		"%s: manifest yielded %d entries, expected %d — reader regression?",
		suite,
		len(entries),
		expected_count,
	)

	passed := 0
	for e in entries {
		kind: enum {
			Positive,
			Negative,
		}
		switch {
		case strings.contains(e.type_str, "PositiveSyntaxTest11"):
			kind = .Positive
		case strings.contains(e.type_str, "NegativeSyntaxTest11"):
			kind = .Negative
		case strings.contains(e.type_str, "QueryEvaluationTest"):
			// Evaluation belongs to the evaluation initiative; at this
			// layer the query must parse.
			kind = .Positive
		case:
			testing.expectf(t, false, "%s: unhandled test type %q — nothing may be silently skipped", e.id, e.type_str)
			continue
		}

		if !testing.expectf(t, e.action != "", "%s: entry has no resolvable query file", e.id) {
			continue
		}
		path, _ := filepath.join({SUITE_ROOT, suite, e.action})
		content, read_err := os.read_entire_file(path, context.allocator)
		delete(path)
		if !testing.expectf(t, read_err == nil, "%s: cannot read action file %q: %v", e.id, e.action, read_err) {
			continue
		}
		defer delete(content)

		base := strings.concatenate({base_prefix, e.action})
		defer delete(base)

		p: sparql.Parser
		sparql.parser_init(&p, content, base)
		_, ok := sparql.parse(&p)
		switch kind {
		case .Positive:
			if testing.expectf(
				t,
				ok,
				"%s (%s): should parse, got %s at %d:%d",
				e.id,
				e.name,
				sparql.error_message(p.err.kind),
				p.err.line,
				p.err.column,
			) {
				passed += 1
			}
		case .Negative:
			if testing.expectf(t, !ok, "%s (%s): malformed query was accepted", e.id, e.name) {
				passed += 1
			}
		}
		sparql.parser_destroy(&p)
	}
	log.infof("%s: %d/%d syntax-level conformance tests passed", suite, passed, len(entries))
}
