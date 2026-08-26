// Building the RDF dataset a W3C evaluation test runs against — **the
// one loader**, used by the evaluator and by the reader guarantee alike.
//
// A manifest entry names its data as `qt:data` (documents that make up
// the default graph) and `qt:graphData` (documents that each become a
// named graph). The name of such a graph is the document's own absolute
// IRI — the suite's upstream location plus the file name — which is
// exactly what those tests' GRAPH clauses and FROM NAMED clauses say.
// Get that IRI wrong and a GRAPH test silently matches nothing, so it
// is derived here in one place from the suite's recorded base.
//
// Documents load through `record/ingest`, not through a second ingestion
// path: the harness parses only manifests and expected results itself.
//
// **There were two of these** (SPARQL-T-0033). This file loaded for
// `readers_test.odin` and `eval_runner.odin` had a near-copy of it for
// the evaluator, because there were two backends and two instantiations
// to load into. One backend, one loader: the reader guarantee now holds
// through the same code the evaluator uses, which is what it was always
// meant to assert.
//
// **There is still no path.** An `open_ephemeral` store had none to make
// unique and record's memory seam has no filesystem at all, so the
// collision this struct used to guard against cannot arise. Suites run
// on several threads at once, and two datasets sharing a path used to
// fail as a store error that reproduced only under load; that history is
// why the struct is shaped this way and is worth keeping in view.
package w3c

import "core:os"
import "core:path/filepath"
import "core:strings"

import rdf "rdf:rdf"
import "record:record"
import "record:record/ingest"

// SUITE_ROOT is tests/w3c/, the directory the vendored suites sit in.
SUITE_ROOT :: #directory + ".."

// Test_Dataset is a loaded dataset: a record store over the memory seam,
// plus the snapshot queries against it read.
//
// The store holds the dictionary its IDs come from, and the two are
// inseparable — an ID means nothing without the dictionary that assigned
// it, and on record the terms a snapshot decodes borrow that
// dictionary's arena.
//
// **It must not be copied or moved after test_dataset_init**: record's
// writer holds a pointer to the `Mem_FS` inside it. Declare one in place
// and pass `^Test_Dataset`.
Test_Dataset :: struct {
	fs:     record.Mem_FS,
	store:  record.Store,
	snap:   record.Snapshot,
	pinned: bool,
	open:   bool,
	// How many documents have been loaded. It scopes each one's
	// blank-node labels, so two documents of one entry cannot collide by
	// sharing a label — which would silently merge two blank nodes and
	// change what a bnode-coreference entry means.
	loaded: int,
	// Set when the store would not open at all, which is a harness
	// failure rather than a test result.
	failed: string,
}

test_dataset_init :: proc(td: ^Test_Dataset) {
	_, open_err, load_err, write_err := record.store_open(&td.store, "w3c", record.mem_file_ops(&td.fs))
	if open_err != .None {
		td.failed = "the scratch store did not open"
		return
	}
	if load_err != .None || write_err != .None {
		record.store_close(&td.store)
		td.failed = "the scratch store did not boot"
		return
	}
	td.open = true
}

// test_dataset_snapshot pins the dataset every query of one entry
// answers about — once, after the last document has been applied.
test_dataset_snapshot :: proc(td: ^Test_Dataset) -> (record.Snapshot, bool) {
	if td.pinned {
		return td.snap, true
	}
	if !td.open {
		return {}, false
	}
	snap, err := record.store_latest(&td.store)
	if err != .None {
		return {}, false
	}
	td.snap = snap
	td.pinned = true
	return td.snap, true
}

// test_dataset_destroy releases the snapshot and closes the store, in
// that order — `store_destroy` asserts that every snapshot has been
// released.
test_dataset_destroy :: proc(td: ^Test_Dataset) {
	if td.pinned {
		record.snapshot_release(&td.snap)
		td.pinned = false
	}
	if td.open {
		record.store_close(&td.store)
		td.open = false
	}
	record.mem_fs_destroy(&td.fs)
}

// test_dataset_quads counts the quads visible in the dataset, for the
// reader guarantee's running total.
//
// It walks rather than reading a stored count, because record keeps
// none: a fact has a lifetime, so "how many quads" is a question about
// an epoch and is answered by the scan that any other read would use.
// `range_len` would be cheaper and would be the wrong number — it counts
// fact *generations* in the window, including retracted ones.
test_dataset_quads :: proc(td: ^Test_Dataset) -> int {
	snap, pinned := test_dataset_snapshot(td)
	if !pinned {
		return 0
	}
	sc := record.range_iter(record.snapshot_match(snap, {}), record.Filter{origin = .Any, scope = .All})
	n := 0
	for {
		if _, ok := record.scan_next(&sc); !ok {
			break
		}
		n += 1
	}
	return n
}

// load_entry_dataset loads an entry's documents into td. reason
// describes the first failure and is "" on success; it names the
// document, because a suite failing wholesale for one unreadable data
// file is otherwise a long hunt.
load_entry_dataset :: proc(td: ^Test_Dataset, suite: Suite, e: Entry) -> (ok: bool, reason: string) {
	if td.failed != "" {
		return false, td.failed
	}
	for name in e.data {
		if loaded, why := load_document(td, suite, name, nil); !loaded {
			return false, why
		}
	}
	for name in e.graph_data {
		// The graph's name is the document's absolute IRI.
		graph_iri := strings.concatenate({suite.base, name})
		defer delete(graph_iri)
		if loaded, why := load_document(td, suite, name, rdf.IRI(graph_iri)); !loaded {
			return false, why
		}
	}
	return true, ""
}

// load_declared_document loads a document a query named in a FROM or
// FROM NAMED clause. Same mechanics as an entry's data; separate name
// because the two come from different places — the manifest and the
// query — and confusing them makes a dataset test very hard to read.
load_declared_document :: proc(
	td: ^Test_Dataset,
	suite: Suite,
	name: string,
	graph: rdf.Graph_Label,
) -> (
	ok: bool,
	reason: string,
) {
	return load_document(td, suite, name, graph)
}

// load_document loads one file into the given graph (nil for the
// default graph), dispatching on the extension the suites use.
//
// **`base` is not optional.** The suites' data documents use relative
// IRIs throughout and resolve them against their own upstream location;
// a document loaded without it produces terms that do not match the
// query's, and the entry fails as a wrong answer rather than as a load
// error.
@(private = "file")
load_document :: proc(td: ^Test_Dataset, suite: Suite, name: string, graph: rdf.Graph_Label) -> (ok: bool, reason: string) {
	if !td.open {
		return false, "scratch store did not open"
	}
	path, _ := filepath.join({SUITE_ROOT, suite.dir, name})
	defer delete(path)
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false, "cannot read data document"
	}
	defer delete(content)

	base := strings.concatenate({suite.base, name})
	defer delete(base)

	scope := document_scope(td)
	defer delete(scope)

	ops: []record.Op
	err: ingest.Error
	switch {
	case strings.has_suffix(name, ".ttl"):
		ops, err = ingest.turtle(content, graph, context.allocator, blank_prefix = scope, base = base)
	case strings.has_suffix(name, ".nt"):
		ops, err = ingest.ntriples(content, graph, context.allocator, blank_prefix = scope)
	case strings.has_suffix(name, ".trig"):
		// A quad-bearing document names its own graphs, so the target
		// graph is the document's rather than the caller's. The suites
		// only ever name one as qt:data, which is what "load it as it
		// stands" means for a document that already says where each
		// statement lives.
		ops, err = ingest.trig(content, context.allocator, blank_prefix = scope, base = base)
	case strings.has_suffix(name, ".nq"):
		ops, err = ingest.nquads(content, context.allocator, blank_prefix = scope)
	case strings.has_suffix(name, ".rdf"):
		// RDF/XML. odin-rdf-parser implements N-Triples, N-Quads,
		// Turtle, and TriG — not RDF/XML — so the ten sparql11-subquery
		// entries whose data is RDF/XML cannot be loaded. Reported,
		// never skipped silently; the count is pinned in
		// readers_test.odin. **This is a parser decision, not a record
		// limitation**, and the reason string should keep saying so.
		return false, "data document is RDF/XML, which the family's parser does not implement"
	case:
		return false, "data document is in an unrecognized format"
	}
	if err.kind != .None {
		if err.kind == .Syntax {
			return false, "the data document did not parse"
		}
		return false, "the data document could not be ingested"
	}
	defer ingest.ops_destroy(ops, context.allocator)

	// **An empty document is a document, and record refuses an empty
	// changeset** (`.Empty`, log.md's decision 6: a commit that says
	// nothing is a caller mistake, not an epoch). Several suites ship
	// one deliberately — `sparql11-aggregates`' empty-group entries are
	// the clearest case, where the whole point is that the data is empty
	// — so there is nothing to apply and nothing wrong.
	if len(ops) == 0 {
		return true, ""
	}

	// **One apply per document, and a changeset is a delta.** record
	// refuses an assert of a quad that is already live with
	// `.Already_Live` at the offending op, where odin-rdf-store's insert
	// was idempotent. Two of an entry's documents stating the same triple
	// is legal and does happen, so that case is named rather than
	// reported as a bare failure.
	if _, _, apply_err := record.apply(&td.store, {ops = ops}); apply_err != (record.Apply_Error{}) {
		if apply_err.kind == .Already_Live {
			return false, "a later document re-asserted a quad an earlier one already stated"
		}
		if apply_err.kind == .Unsupported_Term {
			return false, "the data document holds a term this store's format cannot encode"
		}
		return false, "the store rejected the document"
	}
	return true, ""
}

// document_scope is the blank-node load scope for one document: label
// characters only (record refuses anything else), and distinct per
// document within one dataset.
//
// Two documents sharing a scope would merge blank nodes that the RDF
// data model says are distinct, which changes what an entry means rather
// than making it fail — `sparql10-bnode-coreference` and the CONSTRUCT
// directories are where it would show. The comparison is isomorphism-based,
// so a stable arbitrary prefix is all that is needed.
@(private = "file")
document_scope :: proc(td: ^Test_Dataset) -> string {
	n := td.loaded
	td.loaded += 1
	out := make([]byte, 8)
	copy(out, "w3c_")
	digits := "0123456789"
	out[4] = digits[(n / 100) % 10]
	out[5] = digits[(n / 10) % 10]
	out[6] = digits[n % 10]
	out[7] = '_'
	return string(out)
}
