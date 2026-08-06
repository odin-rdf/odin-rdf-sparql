package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Development instrument, not a guard: runs every entry of every
// vendored evaluation suite and reports where the engine stands. What
// makes it worth keeping in the tree is that it turns "which directory
// should this task enable" from a guess into a measurement.
//
// It is kept in the tree rather than written and thrown away each time,
// because every enablement decision in SPARQL-T-0012 and T-0013 came out
// of it: which directory is one operator away from green, and which is
// failing on semantics. It asserts nothing, so it cannot fail; set
// DETAIL to a directory's name to see its mismatches in full.
//
// DETAIL names the directories whose mismatches are printed in full.
DETAIL :: [?]string{}

@(test)
zz_survey :: proc(t: ^testing.T) {
	for suite in EVAL_SUITES {
		manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
		defer delete(manifest_path)
		manifest_data, err := os.read_entire_file(manifest_path, context.allocator)
		if err != nil {continue}
		defer delete(manifest_data)
		entries := parse_manifest(string(manifest_data))
		defer destroy_entries(&entries)

		pass, fail, unsup, failed := 0, 0, 0, 0
		reason := ""
		for e in entries {
			if !strings.contains(e.type_str, "QueryEvaluationTest") {continue}
			actual, status, detail := evaluate_entry(suite, e, .Memstore)
			defer result_set_destroy(&actual)
			if status == .Unsupported {
				unsup += 1
				if reason == "" {reason = detail}
				continue
			}
			if status == .Failed {
				failed += 1
				if reason == "" {reason = detail}
				continue
			}
			ep, _ := filepath.join({SUITE_ROOT, suite.dir, e.result})
			defer delete(ep)
			eb := strings.concatenate({suite.base, e.result})
			defer delete(eb)
			expected, read_ok := read_expected(ep, eb)
			if !read_ok {fail += 1; continue}
			defer result_set_destroy(&expected)
			equal, _ := results_equal(
				&actual,
				&expected,
				Compare_Options{ordered = query_is_ordered(suite, e), lax_cardinality = e.lax_cardinality},
			)
			if equal {
				pass += 1
				continue
			}
			fail += 1
			wanted := false
			for name in DETAIL {
				if name == suite.dir {wanted = true}
			}
			if !wanted {continue}
			at := result_set_to_string(&actual)
			defer delete(at)
			et := result_set_to_string(&expected)
			defer delete(et)
			log.infof("MISMATCH %s/%s (%s)\n got:\n%s want:\n%s", suite.dir, e.id, e.name, at, et)
		}
		log.infof(
			// Right-aligned, not left: %-3d fills on the right with '0', so 1
			// and 10 both render as "100" and a directory's ten RDF/XML
			// failures read as one. That misreading reached the initiative's
			// exit table and tests/w3c/README.md before it was caught.
			"SURVEY %-34s pass %3d mismatch %3d unsupported %3d failed %3d %s",
			suite.dir,
			pass,
			fail,
			unsup,
			failed,
			reason,
		)
	}
}
