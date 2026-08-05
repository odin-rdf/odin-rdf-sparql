// A tiny in-memory graph with a subject index, shared by the pieces of
// the harness that have to read RDF as data rather than load it into a
// store: the manifest reader and the result-set-vocabulary reader.
//
// This is deliberately not the store — a manifest is read before any
// store exists, and an expected result is compared as terms, not as
// IDs. Statements are cloned in, so the graph outlives the source
// buffer it was parsed from.
package w3c

import "core:strings"

import rdf "rdf:rdf"
import turtle "rdf:rdf/turtle"

// Graph_Index owns its statements and an index from subject to the
// positions of the statements about it.
Graph_Index :: struct {
	statements: [dynamic]rdf.Triple,
	by_subject: map[string][dynamic]int,
}

// graph_from_turtle parses a Turtle document with the family's parser.
// ok is false on a syntax error, in which case the statements read
// before it are still returned — callers assert on what they expected to
// find rather than on the parse alone.
graph_from_turtle :: proc(source: string, base: string) -> (g: Graph_Index, ok: bool) {
	g.statements = make([dynamic]rdf.Triple)
	g.by_subject = make(map[string][dynamic]int)

	p: turtle.Parser
	turtle.parser_init(&p, transmute([]byte)source, base)
	defer turtle.parser_destroy(&p)
	for {
		t, more := turtle.parser_next(&p)
		if !more {
			break
		}
		append(&g.statements, rdf.clone_triple(t))
	}
	for t, i in g.statements {
		key := term_key(t.subject)
		if key == "" {
			continue
		}
		if positions, found := &g.by_subject[key]; found {
			append(positions, i)
			delete(key)
		} else {
			positions := make([dynamic]int)
			append(&positions, i)
			g.by_subject[key] = positions
		}
	}
	return g, p.err.kind == .None
}

graph_destroy :: proc(g: ^Graph_Index) {
	for t in g.statements {
		rdf.destroy_triple(t)
	}
	delete(g.statements)
	for key, positions in g.by_subject {
		delete(key)
		delete(positions)
	}
	delete(g.by_subject)
	g^ = {}
}

// graph_object returns the first object of (subject, predicate), or nil.
graph_object :: proc(g: ^Graph_Index, subject: rdf.Term, predicate: rdf.IRI) -> rdf.Term {
	key := term_key(subject)
	defer delete(key)
	positions, found := g.by_subject[key]
	if !found {
		return nil
	}
	for i in positions {
		if p, is_iri := g.statements[i].predicate.(rdf.IRI); is_iri && p == predicate {
			return g.statements[i].object
		}
	}
	return nil
}

// graph_objects collects every object of (subject, predicate) in
// statement order. The caller frees the returned array; the terms it
// holds belong to the graph.
graph_objects :: proc(g: ^Graph_Index, subject: rdf.Term, predicate: rdf.IRI) -> [dynamic]rdf.Term {
	out := make([dynamic]rdf.Term)
	key := term_key(subject)
	defer delete(key)
	positions, found := g.by_subject[key]
	if !found {
		return out
	}
	for i in positions {
		if p, is_iri := g.statements[i].predicate.(rdf.IRI); is_iri && p == predicate {
			append(&out, g.statements[i].object)
		}
	}
	return out
}

// graph_subject_of_type returns the first subject typed with the given
// class, or nil when the graph has none.
graph_subject_of_type :: proc(g: ^Graph_Index, class: rdf.IRI) -> rdf.Term {
	for t in g.statements {
		p, is_iri := t.predicate.(rdf.IRI)
		if !is_iri || p != rdf.RDF_TYPE {
			continue
		}
		if o, o_is_iri := t.object.(rdf.IRI); o_is_iri && o == class {
			return t.subject
		}
	}
	return nil
}

// term_key is the index key of a subject term: a kind tag plus its
// label, which distinguishes an IRI from a blank node with the same
// text. Literals and triple terms never index anything here, so they
// key to "". The caller owns the returned string.
@(private)
term_key :: proc(term: rdf.Term) -> string {
	#partial switch v in term {
	case rdf.IRI:
		return strings.concatenate({"I", string(v)})
	case rdf.Blank_Node:
		return strings.concatenate({"B", string(v)})
	}
	return ""
}
