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
import turtle "rdf:rdf/turtle"

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

// SPARQL evaluation entries wrap their action in a node -- mf:action
// [ qt:query <q.rq> ; qt:data <d.ttl> ] -- while syntax entries point
// straight at the query file. The reader resolves both to the query
// file name so no entry is dropped for having the other shape.
QT_QUERY :: rdf.IRI("http://www.w3.org/2001/sw/DataAccess/tests/test-query#query")

Entry :: struct {
	id:       string, // entry IRI fragment, e.g. "agg01"
	name:     string, // mf:name
	type_str: string, // full rdf:type IRI, e.g. ...#QueryEvaluationTest
	action:   string, // query file name relative to the suite directory
	result:   string, // expected-result file for eval tests ("" otherwise)
}

destroy_entries :: proc(entries: ^[dynamic]Entry) {
	for e in entries {
		delete(e.id)
		delete(e.name)
		delete(e.type_str)
		delete(e.action)
		delete(e.result)
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
	statements: [dynamic]rdf.Triple
	defer {
		for t in statements {
			rdf.destroy_triple(t)
		}
		delete(statements)
	}

	p: turtle.Parser
	turtle.parser_init(&p, transmute([]byte)source, MANIFEST_BASE)
	defer turtle.parser_destroy(&p)
	for {
		t, ok := turtle.parser_next(&p)
		if !ok {
			break
		}
		append(&statements, rdf.clone_triple(t))
	}
	entries := make([dynamic]Entry)
	if p.err.kind != .None {
		// Callers assert on the entry count; an empty list fails loudly.
		return entries
	}

	// Index statements by subject for the walk below.
	by_subject: map[string][dynamic]int
	defer {
		for key, idxs in by_subject {
			delete(key)
			delete(idxs)
		}
		delete(by_subject)
	}
	for t, i in statements {
		key := subject_key(t.subject)
		if key == "" {
			continue
		}
		if idxs, found := &by_subject[key]; found {
			append(idxs, i)
			delete(key)
		} else {
			lst: [dynamic]int
			append(&lst, i)
			by_subject[key] = lst
		}
	}

	object_of :: proc(
		statements: []rdf.Triple,
		by_subject: ^map[string][dynamic]int,
		subject: rdf.Term,
		predicate: rdf.IRI,
	) -> rdf.Term {
		key := subject_key(subject)
		defer delete(key)
		idxs, found := by_subject[key]
		if !found {
			return nil
		}
		for i in idxs {
			if pred, is_iri := statements[i].predicate.(rdf.IRI); is_iri && pred == predicate {
				return statements[i].object
			}
		}
		return nil
	}

	// Find the manifest node and the head of its entry collection.
	manifest_subject: rdf.Term
	for t in statements {
		if pred, is_iri := t.predicate.(rdf.IRI); is_iri && pred == rdf.RDF_TYPE {
			if obj, obj_iri := t.object.(rdf.IRI); obj_iri && obj == MF_MANIFEST {
				manifest_subject = t.subject
				break
			}
		}
	}
	if manifest_subject == nil {
		return entries
	}

	cell := object_of(statements[:], &by_subject, manifest_subject, MF_ENTRIES)
	for cell != nil {
		if iri, is_iri := cell.(rdf.IRI); is_iri && iri == rdf.RDF_NIL {
			break
		}
		entry_node := object_of(statements[:], &by_subject, cell, rdf.RDF_FIRST)
		if entry_node == nil {
			break
		}

		e: Entry
		if id, is_iri := entry_node.(rdf.IRI); is_iri {
			e.id = strings.clone(short_id(string(id)))
		}
		if type_term := object_of(statements[:], &by_subject, entry_node, rdf.RDF_TYPE); type_term != nil {
			if iri, is_iri := type_term.(rdf.IRI); is_iri {
				e.type_str = strings.clone(string(iri))
			}
		}
		if name_term := object_of(statements[:], &by_subject, entry_node, MF_NAME); name_term != nil {
			if lit, is_lit := name_term.(rdf.Literal); is_lit {
				e.name = strings.clone(lit.lexical)
			}
		}
		if action_term := object_of(statements[:], &by_subject, entry_node, MF_ACTION); action_term != nil {
			#partial switch v in action_term {
			case rdf.IRI:
				e.action = strings.clone(strip_base(string(v)))
			case rdf.Blank_Node:
				if q := object_of(statements[:], &by_subject, action_term, QT_QUERY); q != nil {
					if iri, is_iri := q.(rdf.IRI); is_iri {
						e.action = strings.clone(strip_base(string(iri)))
					}
				}
			}
		}
		if result_term := object_of(statements[:], &by_subject, entry_node, MF_RESULT); result_term != nil {
			if iri, is_iri := result_term.(rdf.IRI); is_iri {
				e.result = strings.clone(strip_base(string(iri)))
			}
		}
		append(&entries, e)

		cell = object_of(statements[:], &by_subject, cell, rdf.RDF_REST)
	}
	return entries
}

@(private = "file")
subject_key :: proc(term: rdf.Term) -> string {
	#partial switch v in term {
	case rdf.IRI:
		return strings.concatenate({"I", string(v)})
	case rdf.Blank_Node:
		return strings.concatenate({"B", string(v)})
	}
	return ""
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
