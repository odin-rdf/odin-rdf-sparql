package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import sparql "../../../sparql"

// Test-file IRIs resolve against the upstream suite location, per the
// W3C convention; the prefixes and SUITE_ROOT live alongside the
// vendored evaluation suites, which resolve the same way.

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

@(test)
test_w3c_sparql12_syntax :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-syntax", SPARQL12 + "syntax/", 6)
}

@(test)
test_w3c_sparql12_triple_terms_positive :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-syntax-triple-terms-positive", SPARQL12 + "syntax-triple-terms-positive/", 113)
}

@(test)
test_w3c_sparql12_triple_terms_negative :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-syntax-triple-terms-negative", SPARQL12 + "syntax-triple-terms-negative/", 65)
}

@(test)
test_w3c_sparql12_codepoint_escapes :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-codepoint-escapes", SPARQL12 + "codepoint-escapes/", 14)
}

@(test)
test_w3c_sparql12_lang_basedir :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-lang-basedir", SPARQL12 + "lang-basedir/", 11)
}

@(test)
test_w3c_sparql12_version :: proc(t: ^testing.T) {
	run_suite(t, "sparql12-version", SPARQL12 + "version/", 9)
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
	update_out_of_scope := 0
	for e in entries {
		kind: enum {
			Positive,
			Negative,
		}
		switch {
		case strings.contains(e.type_str, "UpdateSyntaxTest"),
		     strings.contains(e.type_str, "UpdateEvaluationTest"):
			// SPARQL Update is out of the engine's scope by design
			// (vision constraint) — acknowledged explicitly here and
			// counted, never silently skipped.
			update_out_of_scope += 1
			continue
		case strings.contains(e.type_str, "PositiveSyntaxTest"):
			kind = .Positive
		case strings.contains(e.type_str, "NegativeSyntaxTest"):
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
	if update_out_of_scope > 0 {
		log.infof(
			"%s: %d/%d syntax-level conformance tests passed (%d Update tests out of engine scope)",
			suite,
			passed,
			len(entries) - update_out_of_scope,
			update_out_of_scope,
		)
	} else {
		log.infof("%s: %d/%d syntax-level conformance tests passed", suite, passed, len(entries))
	}
}
