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
// results itself. This is the memstore instantiation; the kvstore side
// arrives with the backend-binding decision in SPARQL-T-0011, and the
// dual-backend discipline is applied there.
package w3c

import "core:os"
import "core:path/filepath"
import "core:strings"

import rdf "rdf:rdf"
import store "store:store"
import memstore "store:store/memstore"

// SUITE_ROOT is tests/w3c/, the directory the vendored suites sit in.
SUITE_ROOT :: #directory + ".."

// Test_Dataset is a loaded dataset with the dictionary its IDs come
// from. The two are inseparable — an ID means nothing without the
// dictionary that assigned it — so they are handed around together.
Test_Dataset :: struct {
	dictionary: memstore.Dictionary,
	dataset:    memstore.Dataset,
}

test_dataset_init :: proc(td: ^Test_Dataset) {
	memstore.dictionary_init(&td.dictionary)
	memstore.dataset_init(&td.dataset)
}

test_dataset_destroy :: proc(td: ^Test_Dataset) {
	memstore.dataset_destroy(&td.dataset)
	memstore.dictionary_destroy(&td.dictionary)
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

	load_err: store.Load_Error
	switch {
	case strings.has_suffix(name, ".ttl"):
		_, load_err = memstore.load_turtle(&td.dictionary, &td.dataset, content, base, graph)
	case strings.has_suffix(name, ".nt"):
		_, load_err = memstore.load_triples(&td.dictionary, &td.dataset, content, graph)
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
	if load_err.message != "" {
		return false, load_err.message
	}
	return true, ""
}
