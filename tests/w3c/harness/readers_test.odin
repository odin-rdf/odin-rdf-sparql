package w3c

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import memstore "store:store/memstore"

import sparql "../../../sparql"

// The guard behind the expected-result readers: every file the vendored
// evaluation suites name as an expectation is read, in every format they
// use. The readers work over narrow subsets of XML, JSON, and the
// result-set vocabulary (see xml.odin and rsvocab.odin), and this is
// what holds those subset assumptions to the real corpus rather than to
// the handful of files anyone happened to look at.
//
// It also pins each suite's entry count, for the same reason the syntax
// suites do: a manifest reader that quietly dropped entries would make
// every later evaluation task look greener than it is.
@(test)
test_expected_result_readers :: proc(t: ^testing.T) {
	total, boolean_count, graph_count, bindings_count := 0, 0, 0, 0
	srx_count, srj_count, turtle_count, rdfxml_count := 0, 0, 0, 0
	// The "empty tuple" answer: a solution that binds nothing, which a
	// query with no projected variables produces over a matching
	// pattern. It is not the same answer as no solution at all, and the
	// suites contain both — so the count is logged rather than treated
	// as a reader fault.
	empty_solution_count := 0

	for suite in EVAL_SUITES {
		manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
		defer delete(manifest_path)
		manifest_data, manifest_err := os.read_entire_file(manifest_path, context.allocator)
		if !testing.expectf(t, manifest_err == nil, "cannot read manifest %s: %v", manifest_path, manifest_err) {
			continue
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

		for e in entries {
			if e.result == "" {
				continue
			}
			if strings.has_suffix(e.result, ".csv") || strings.has_suffix(e.result, ".tsv") {
				// Result-serialization formats; out of the engine's scope
				// and never vendored, so a reference to one is a vendoring
				// mistake rather than a reader gap.
				testing.expectf(t, false, "%s/%s: expectation in an out-of-scope format %q", suite.dir, e.id, e.result)
				continue
			}
			path, _ := filepath.join({SUITE_ROOT, suite.dir, e.result})
			defer delete(path)
			base := strings.concatenate({suite.base, e.result})
			defer delete(base)

			expected, ok := read_expected(path, base)
			if !testing.expectf(t, ok, "%s/%s: cannot read expectation %q", suite.dir, e.id, e.result) {
				continue
			}
			defer result_set_destroy(&expected)

			total += 1
			switch {
			case strings.has_suffix(e.result, ".srx"):
				srx_count += 1
			case strings.has_suffix(e.result, ".srj"):
				srj_count += 1
			case strings.has_suffix(e.result, ".ttl"):
				turtle_count += 1
			case strings.has_suffix(e.result, ".rdf"):
				rdfxml_count += 1
			}
			switch expected.kind {
			case .Boolean:
				boolean_count += 1
			case .Graph:
				graph_count += 1
			case .Bindings:
				bindings_count += 1
				for row in expected.rows {
					bound := 0
					for term in row {
						if term != nil {
							bound += 1
						}
					}
					if bound == 0 {
						empty_solution_count += 1
					}
				}
			}
		}
	}

	testing.expect(t, total > 400, "far fewer expectations read than the suites ship")
	// Every format the suites use must actually be exercised — a reader
	// that no vendored file reaches is a reader nothing tests.
	testing.expect(t, srx_count > 0, "no .srx expectation was read")
	testing.expect(t, srj_count > 0, "no .srj expectation was read")
	testing.expect(t, turtle_count > 0, "no .ttl expectation was read")
	testing.expect(t, rdfxml_count > 0, "no .rdf expectation was read")
	log.infof(
		"read %d expectations (%d bindings, %d boolean, %d graph; %d empty-tuple solutions); "+
		"formats: %d srx, %d srj, %d ttl, %d rdf",
		total,
		bindings_count,
		boolean_count,
		graph_count,
		empty_solution_count,
		srx_count,
		srj_count,
		turtle_count,
		rdfxml_count,
	)
}

// Every vendored evaluation entry must name a query file and, for a
// query-evaluation test, an expectation. This is the manifest side of
// the same guard: it catches an action shape the reader does not
// understand, which would otherwise surface much later as a suite that
// mysteriously runs no tests.
@(test)
test_evaluation_entries_are_complete :: proc(t: ^testing.T) {
	with_data, with_graph_data, update_out_of_scope := 0, 0, 0
	for suite in EVAL_SUITES {
		manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
		defer delete(manifest_path)
		manifest_data, manifest_err := os.read_entire_file(manifest_path, context.allocator)
		if !testing.expectf(t, manifest_err == nil, "cannot read manifest %s: %v", manifest_path, manifest_err) {
			continue
		}
		defer delete(manifest_data)

		entries := parse_manifest(string(manifest_data))
		defer destroy_entries(&entries)
		for e in entries {
			if strings.contains(e.type_str, "UpdateEvaluationTest") {
				// SPARQL Update is out of the engine's scope by design
				// (vision constraint), and an Update entry names a
				// ut:request rather than a qt:query. Counted and
				// acknowledged, the way the syntax harness does it, never
				// silently skipped.
				update_out_of_scope += 1
				continue
			}
			testing.expectf(t, e.action != "", "%s/%s: entry has no resolvable query file", suite.dir, e.id)
			if !strings.contains(e.type_str, "QueryEvaluationTest") {
				continue
			}
			testing.expectf(t, e.result != "", "%s/%s: evaluation entry names no expectation", suite.dir, e.id)
			if len(e.data) > 0 {
				with_data += 1
			}
			if len(e.graph_data) > 0 {
				with_graph_data += 1
			}
		}
	}
	testing.expect(t, with_data > 0, "no entry resolved a qt:data document")
	testing.expect(t, with_graph_data > 0, "no entry resolved a qt:graphData document")
	testing.expectf(
		t,
		update_out_of_scope == UPDATE_ENTRIES,
		"%d Update entries in the vendored evaluation suites, expected %d — the exclusion moved",
		update_out_of_scope,
		UPDATE_ENTRIES,
	)
	log.infof(
		"%d entries carry qt:data, %d carry qt:graphData (%d Update entries out of engine scope)",
		with_data,
		with_graph_data,
		update_out_of_scope,
	)
}

// The number of SPARQL Update entries mixed into the vendored evaluation
// directories: the three in sparql12-eval-triple-terms. Update is out of
// the engine's scope by the vision, and pinning the count means neither
// growing nor shrinking it can pass unnoticed.
UPDATE_ENTRIES :: 3

// The number of evaluation entries whose data is RDF/XML, a format
// odin-rdf-parser does not implement. Pinned rather than tolerated: the
// entries are real tests that will need a decision (a harness-side
// reader, or an acknowledged exclusion) when subqueries are evaluated in
// SPARQL-T-0013, and pinning the count means neither growing nor
// shrinking it can pass unnoticed.
RDF_XML_DATA_ENTRIES :: 10

// The manifest-to-store path: every evaluation entry's data documents
// resolve to files that the store's own loaders ingest, into the default
// graph or into a named graph whose name is the document's absolute IRI.
// Evaluation itself is not run here — no evaluator exists yet — but a
// test whose dataset does not load could never pass, and finding that
// out now is much cheaper than finding it out one suite at a time.
@(test)
test_entry_datasets_load :: proc(t: ^testing.T) {
	loaded, quads, rdfxml_blocked := 0, 0, 0
	for suite in EVAL_SUITES {
		manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
		defer delete(manifest_path)
		manifest_data, manifest_err := os.read_entire_file(manifest_path, context.allocator)
		if !testing.expectf(t, manifest_err == nil, "cannot read manifest %s: %v", manifest_path, manifest_err) {
			continue
		}
		defer delete(manifest_data)

		entries := parse_manifest(string(manifest_data))
		defer destroy_entries(&entries)
		for e in entries {
			if len(e.data) == 0 && len(e.graph_data) == 0 {
				continue
			}
			if entry_has_rdfxml_data(e) {
				rdfxml_blocked += 1
				continue
			}
			td: Test_Dataset
			test_dataset_init(&td)
			defer test_dataset_destroy(&td)
			ok, reason := load_entry_dataset(&td, suite, e)
			if !testing.expectf(t, ok, "%s/%s: dataset did not load: %s", suite.dir, e.id, reason) {
				continue
			}
			loaded += 1
			quads += memstore.count(&td.dataset)
		}
	}
	testing.expectf(
		t,
		rdfxml_blocked == RDF_XML_DATA_ENTRIES,
		"%d entries have RDF/XML data, expected %d — the exclusion list moved",
		rdfxml_blocked,
		RDF_XML_DATA_ENTRIES,
	)
	testing.expect(t, loaded > 400, "far fewer datasets loaded than the suites ship")
	log.infof("%d entry datasets loaded, %d quads total (%d blocked on RDF/XML data)", loaded, quads, rdfxml_blocked)
}

@(private = "file")
entry_has_rdfxml_data :: proc(e: Entry) -> bool {
	for name in e.data {
		if strings.has_suffix(name, ".rdf") {
			return true
		}
	}
	for name in e.graph_data {
		if strings.has_suffix(name, ".rdf") {
			return true
		}
	}
	return false
}

// The parse-level floor for the newly vendored evaluation suites: every
// query in them must parse and translate, whatever the evaluator can do
// with it yet. This is the same guard the syntax suites apply, extended
// to the evaluation corpus the moment it lands, so a query the parser
// cannot read shows up here rather than as a confusing evaluation
// failure in a later task.
@(test)
test_evaluation_queries_parse :: proc(t: ^testing.T) {
	parsed := 0
	for suite in EVAL_SUITES {
		manifest_path, _ := filepath.join({SUITE_ROOT, suite.dir, "manifest.ttl"})
		defer delete(manifest_path)
		manifest_data, manifest_err := os.read_entire_file(manifest_path, context.allocator)
		if !testing.expectf(t, manifest_err == nil, "cannot read manifest %s: %v", manifest_path, manifest_err) {
			continue
		}
		defer delete(manifest_data)

		entries := parse_manifest(string(manifest_data))
		defer destroy_entries(&entries)
		for e in entries {
			if strings.contains(e.type_str, "NegativeSyntaxTest") ||
			   strings.contains(e.type_str, "UpdateEvaluationTest") ||
			   e.action == "" {
				continue
			}
			path, _ := filepath.join({SUITE_ROOT, suite.dir, e.action})
			defer delete(path)
			content, read_err := os.read_entire_file(path, context.allocator)
			if !testing.expectf(t, read_err == nil, "%s/%s: cannot read %q", suite.dir, e.id, e.action) {
				continue
			}
			defer delete(content)
			base := strings.concatenate({suite.base, e.action})
			defer delete(base)

			p: sparql.Parser
			sparql.parser_init(&p, content, base)
			defer sparql.parser_destroy(&p)
			_, ok := sparql.parse(&p)
			if testing.expectf(
				t,
				ok,
				"%s/%s (%s): should parse, got %s at %d:%d",
				suite.dir,
				e.id,
				e.name,
				sparql.error_message(p.err.kind),
				p.err.line,
				p.err.column,
			) {
				parsed += 1
			}
		}
	}
	log.infof("%d evaluation-suite queries parse", parsed)
}
