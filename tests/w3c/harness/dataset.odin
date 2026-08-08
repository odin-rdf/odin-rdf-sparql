// Building the RDF dataset a W3C evaluation test runs against.
//
// A manifest entry names its data as `qt:data` (documents that make up
// the default graph) and `qt:graphData` (documents that each become a
// named graph). The name of such a graph is the document's own absolute
// IRI — the suite's upstream location plus the file name — which is
// exactly what those tests' GRAPH clauses and FROM NAMED clauses say.
// Get that IRI wrong and a GRAPH test silently matches nothing, so it
// is derived here in one place from the suite's recorded base.
//
// Documents load through the store's own bulk loaders, not through a
// second ingestion path: the harness parses only manifests and expected
// results itself.
//
// This was the in-memory instantiation until odin-rdf-store retired that
// backend (STORE-A-0006); the evaluation runner has always had its own
// kvstore loading path, so what survives here is the loader that
// readers_test.odin uses to prove every suite's data documents are
// readable. It now needs a database directory, which test_dataset_init
// creates and test_dataset_destroy removes.
package w3c

import "core:os"
import "core:path/filepath"
import "core:strings"


import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

// SUITE_ROOT is tests/w3c/, the directory the vendored suites sit in.
SUITE_ROOT :: #directory + ".."

// Test_Dataset is a loaded dataset. It carries its own scratch database:
// the store holds the dictionary its IDs come from, and the two are
// inseparable — an ID means nothing without the dictionary that assigned
// it.
//
// There is no path: an ephemeral store has none to make unique, and the
// collisions this struct used to guard against cannot arise. Suites run on
// several threads at once, and two datasets sharing a path used to fail as
// a store error that reproduced only under load.
Test_Dataset :: struct {
	store: ^kvstore.Store,
	err:   kvstore.Error,
}

test_dataset_init :: proc(td: ^Test_Dataset) {
	td.store, td.err = kvstore.open_ephemeral()
}

test_dataset_destroy :: proc(td: ^Test_Dataset) {
	if td.store != nil {
		kvstore.close(td.store)
	}
}

// load_entry_dataset loads an entry's documents into td. reason
// describes the first failure and is "" on success; it names the
// document, because a suite failing wholesale for one unreadable data
// file is otherwise a long hunt.
load_entry_dataset :: proc(td: ^Test_Dataset, suite: Suite, e: Entry) -> (ok: bool, reason: string) {
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
@(private = "file")
load_document :: proc(td: ^Test_Dataset, suite: Suite, name: string, graph: rdf.Graph_Label) -> (ok: bool, reason: string) {
	path, _ := filepath.join({SUITE_ROOT, suite.dir, name})
	defer delete(path)
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false, "cannot read data document"
	}
	defer delete(content)

	base := strings.concatenate({suite.base, name})
	defer delete(base)

	if td.store == nil {
		return false, "scratch store did not open"
	}

	load_err: store.Load_Error
	db_err: kvstore.Error
	switch {
	case strings.has_suffix(name, ".ttl"):
		_, load_err, db_err = kvstore.load_turtle(td.store, content, base, graph)
	case strings.has_suffix(name, ".nt"):
		_, load_err, db_err = kvstore.load_triples(td.store, content, graph)
	case strings.has_suffix(name, ".trig"):
		// A quad-bearing document names its own graphs, so the target
		// graph is the document's rather than the caller's. The suites
		// only ever name one as qt:data, which is what "load it as it
		// stands" means for a document that already says where each
		// statement lives.
		_, load_err, db_err = kvstore.load_trig(td.store, content, base)
	case strings.has_suffix(name, ".nq"):
		_, load_err, db_err = kvstore.load_quads(td.store, content)
	case strings.has_suffix(name, ".rdf"):
		// RDF/XML. odin-rdf-parser implements N-Triples, N-Quads,
		// Turtle, and TriG — not RDF/XML — so the ten sparql11-subquery
		// entries whose data is RDF/XML cannot be loaded yet. Reported,
		// never skipped silently; the count is pinned in readers_test.odin
		// and the decision belongs to SPARQL-T-0013.
		return false, "data document is RDF/XML, which the family's parser does not implement"
	case:
		return false, "data document is in an unrecognized format"
	}
	if db_err != nil {
		return false, "the store rejected the document"
	}
	if load_err.message != "" {
		return false, load_err.message
	}
	return true, ""
}
