package w3c

import "core:os"
import "core:path/filepath"
import "core:testing"

SUITE_ROOT :: #directory + ".."

// Suite directories are enabled individually. A directory appears here
// once vendored -- manifest reading, pinned entry count, action files
// present on disk -- and its pass/fail execution wires up as the
// grammar lands (SPARQL-T-0005), where positive/negative dispatch on
// mf:type must fail hard on anything unhandled: nothing may be
// silently skipped.

@(test)
test_manifest_sparql11_syntax_query :: proc(t: ^testing.T) {
	check_manifest(t, "sparql11-syntax-query", 94)
}

@(test)
test_manifest_sparql11_aggregates :: proc(t: ^testing.T) {
	check_manifest(t, "sparql11-aggregates", 47)
}

@(test)
test_manifest_sparql11_construct :: proc(t: ^testing.T) {
	check_manifest(t, "sparql11-construct", 7)
}

@(test)
test_manifest_sparql11_grouping :: proc(t: ^testing.T) {
	check_manifest(t, "sparql11-grouping", 6)
}

// check_manifest parses a vendored suite's manifest and asserts the
// pinned entry count, that every entry resolved to a query file, and
// that every referenced file exists on disk -- the vendoring is
// complete and hermetic before any query parsing exists.
check_manifest :: proc(t: ^testing.T, suite: string, expected_count: int) {
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

	for e in entries {
		if !testing.expectf(
			t,
			e.action != "",
			"%s: entry has no resolvable query file — nothing may be silently skipped",
			e.id,
		) {
			continue
		}
		check_file(t, suite, e.id, e.action)
		if e.result != "" {
			check_file(t, suite, e.id, e.result)
		}
	}
}

@(private = "file")
check_file :: proc(t: ^testing.T, suite: string, id: string, name: string) {
	path, _ := filepath.join({SUITE_ROOT, suite, name})
	defer delete(path)
	testing.expectf(t, os.exists(path), "%s: file %q missing from vendored suite", id, name)
}
