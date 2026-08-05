// Package w3c runs the vendored W3C SPARQL conformance suites.
// Manifests are parsed with the family's own Turtle parser, reached
// through the `rdf:` collection -- the harness that will validate the
// query parser runs on the family's format parser, the same
// arrangement as odin-rdf-parser's harness (mirrored per
// SPARQL-T-0001).
//
// Circularity guard: a Turtle-parser bug that silently dropped
// manifest entries could mask conformance failures, so each suite test
// asserts the exact entry count recorded when the suite was vendored.
package w3c

import "core:strings"

import rdf "rdf:rdf"

// MANIFEST_BASE anchors the manifests' relative IRIs; action and
// result file names are recovered by stripping it again. Entry
// identifiers in the SPARQL manifests are absolute prefixed-name IRIs
// (<...>/manifest#name); only their fragment is kept.
MANIFEST_BASE :: "https://manifest.invalid/"

MF_NS :: "http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#"
MF_MANIFEST :: rdf.IRI(MF_NS + "Manifest")
MF_ENTRIES :: rdf.IRI(MF_NS + "entries")
MF_NAME :: rdf.IRI(MF_NS + "name")
MF_ACTION :: rdf.IRI(MF_NS + "action")
MF_RESULT :: rdf.IRI(MF_NS + "result")
MF_RESULT_CARDINALITY :: rdf.IRI(MF_NS + "resultCardinality")
MF_LAX_CARDINALITY :: rdf.IRI(MF_NS + "LaxCardinality")

// SPARQL evaluation entries wrap their action in a node -- mf:action
// [ qt:query <q.rq> ; qt:data <d.ttl> ] -- while syntax entries point
// straight at the query file. The reader resolves both to the query
// file name so no entry is dropped for having the other shape.
QT_NS :: "http://www.w3.org/2001/sw/DataAccess/tests/test-query#"
QT_QUERY :: rdf.IRI(QT_NS + "query")
QT_DATA :: rdf.IRI(QT_NS + "data")
QT_GRAPH_DATA :: rdf.IRI(QT_NS + "graphData")

// Entry is one manifest entry. File references are relative to the
// suite directory: the manifests name them relative, and the reader
// strips MANIFEST_BASE back off. data holds the qt:data documents,
// which load into the default graph; graph_data holds the qt:graphData
// documents, each of which loads into a named graph whose name is the
// document's absolute IRI.
Entry :: struct {
	id:              string, // entry IRI fragment, e.g. "agg01"
	name:            string, // mf:name
	type_str:        string, // full rdf:type IRI, e.g. ...#QueryEvaluationTest
	action:          string, // query file name relative to the suite directory
	result:          string, // expected-result file for eval tests ("" otherwise)
	data:            [dynamic]string, // qt:data documents (default graph)
	graph_data:      [dynamic]string, // qt:graphData documents (named graphs)
	lax_cardinality: bool, // mf:resultCardinality mf:LaxCardinality
}

destroy_entries :: proc(entries: ^[dynamic]Entry) {
	for e in entries {
		delete(e.id)
		delete(e.name)
		delete(e.type_str)
		delete(e.action)
		delete(e.result)
		for d in e.data {
			delete(d)
		}
		delete(e.data)
		for d in e.graph_data {
			delete(d)
		}
		delete(e.graph_data)
	}
	delete(entries^)
}

// parse_manifest reads a manifest.ttl with the real Turtle parser and
// walks the mf:entries collection, preserving the manifest's order.
// Every list entry is returned, including ones whose action failed to
// resolve (action == "") -- the caller asserts on those rather than
// this reader dropping them silently. Returned entries own their
// strings; free with destroy_entries.
parse_manifest :: proc(source: string) -> [dynamic]Entry {
	g, _ := graph_from_turtle(source, MANIFEST_BASE)
	defer graph_destroy(&g)

	entries := make([dynamic]Entry)
	manifest_subject := graph_subject_of_type(&g, MF_MANIFEST)
	if manifest_subject == nil {
		// Callers assert on the entry count; an empty list fails loudly.
		return entries
	}

	cell := graph_object(&g, manifest_subject, MF_ENTRIES)
	for cell != nil {
		if iri, is_iri := cell.(rdf.IRI); is_iri && iri == rdf.RDF_NIL {
			break
		}
		entry_node := graph_object(&g, cell, rdf.RDF_FIRST)
		if entry_node == nil {
			break
		}
		append(&entries, read_entry(&g, entry_node))
		cell = graph_object(&g, cell, rdf.RDF_REST)
	}
	return entries
}

@(private = "file")
read_entry :: proc(g: ^Graph_Index, entry_node: rdf.Term) -> (e: Entry) {
	e.data = make([dynamic]string)
	e.graph_data = make([dynamic]string)

	if id, is_iri := entry_node.(rdf.IRI); is_iri {
		e.id = strings.clone(short_id(string(id)))
	} else {
		e.id = strings.clone("")
	}
	e.type_str = clone_iri(graph_object(g, entry_node, rdf.RDF_TYPE))
	e.name = clone_lexical(graph_object(g, entry_node, MF_NAME))
	e.result = clone_relative(graph_object(g, entry_node, MF_RESULT))

	if cardinality := graph_object(g, entry_node, MF_RESULT_CARDINALITY); cardinality != nil {
		if iri, is_iri := cardinality.(rdf.IRI); is_iri && iri == MF_LAX_CARDINALITY {
			e.lax_cardinality = true
		}
	}

	action := graph_object(g, entry_node, MF_ACTION)
	e.action = strings.clone("")
	#partial switch v in action {
	case rdf.IRI:
		delete(e.action)
		e.action = strings.clone(strip_base(string(v)))
	case rdf.Blank_Node:
		delete(e.action)
		e.action = clone_relative(graph_object(g, action, QT_QUERY))
		collect_relative(g, action, QT_DATA, &e.data)
		collect_relative(g, action, QT_GRAPH_DATA, &e.graph_data)
	}
	return e
}

@(private = "file")
collect_relative :: proc(g: ^Graph_Index, subject: rdf.Term, predicate: rdf.IRI, out: ^[dynamic]string) {
	objects := graph_objects(g, subject, predicate)
	defer delete(objects)
	for o in objects {
		if iri, is_iri := o.(rdf.IRI); is_iri {
			append(out, strings.clone(strip_base(string(iri))))
		}
	}
}

@(private = "file")
clone_iri :: proc(term: rdf.Term) -> string {
	if iri, is_iri := term.(rdf.IRI); is_iri {
		return strings.clone(string(iri))
	}
	return strings.clone("")
}

@(private = "file")
clone_relative :: proc(term: rdf.Term) -> string {
	if iri, is_iri := term.(rdf.IRI); is_iri {
		return strings.clone(strip_base(string(iri)))
	}
	return strings.clone("")
}

@(private = "file")
clone_lexical :: proc(term: rdf.Term) -> string {
	if lit, is_literal := term.(rdf.Literal); is_literal {
		return strings.clone(lit.lexical)
	}
	return strings.clone("")
}

@(private = "file")
strip_base :: proc(iri: string) -> string {
	if strings.has_prefix(iri, MANIFEST_BASE) {
		return iri[len(MANIFEST_BASE):]
	}
	return iri
}

@(private = "file")
short_id :: proc(iri: string) -> string {
	if idx := strings.last_index_byte(iri, '#'); idx >= 0 {
		return iri[idx + 1:]
	}
	return strip_base(iri)
}
