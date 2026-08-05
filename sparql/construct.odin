// The result forms that answer with a graph rather than with solutions:
// CONSTRUCT's template instantiation (§16.2) and DESCRIBE (§16.4).
//
// SELECT and ASK answer out of the solution stream directly — a sequence
// of rows, or whether there was one. CONSTRUCT and DESCRIBE do not: they
// turn solutions into RDF, and RDF is where the solution's Term_IDs stop
// being enough. So this is the one part of evaluation that materializes
// terms as a matter of course rather than as a last step.
//
// **Ownership.** A Result_Graph owns every term it holds, deep-copied
// into the allocator it was made with, and `result_graph_destroy` frees
// all of it. That is deliberate and it is what the family's borrowing
// convention forces: memstore's materialized terms borrow its dictionary
// and kvstore's are owned by the query, so a graph that borrowed either
// would outlive its source in one backend and double-free in the other.
// Copying once, at the boundary, makes the answer independent of the
// store it came from — which is what a caller wants from a query result
// anyway.
//
// **The graph is a set.** §16.2 says so, and it is not a detail: a
// template with fewer variables than the pattern instantiates the same
// triple from many solutions, and `CONSTRUCT { ?x :p2 ?v } WHERE { ?x :p
// ?o OPTIONAL { ?o :q ?v } }` over the DAWG's data produces one triple
// from two solutions. Deduplication is by a rendering of the triple's
// terms, which is exact rather than a hash: two triples share a key when
// they are the same triple.
package sparql

import "base:runtime"
import "core:strconv"
import "core:strings"

import rdf "rdf:rdf"
import store "store:store"

// Term_Resolver materializes one of a solution's Term_IDs into the RDF
// term it names.
//
// It is a procedure value rather than a compile-time constant because
// resolving is exactly where the two backends differ — one borrows its
// dictionary's storage, the other builds a term from the database's bytes
// — and because instantiating a template is not a hot path: it runs once
// per template triple per solution, and it allocates a graph entry
// anyway. The term it returns belongs to the resolver; a graph copies
// what it keeps.
Term_Resolver :: #type proc(data: rawptr, id: store.Term_ID) -> rdf.Term

// Result_Graph is the answer of a CONSTRUCT or a DESCRIBE: a set of
// triples, owning every term in it.
Result_Graph :: struct {
	triples:   [dynamic]rdf.Triple,
	// The triples already in the graph, keyed by an exact rendering of
	// their terms. This is the one thing a graph result retains beyond the
	// answer itself, and it is what makes the answer a set.
	seen:      map[string]bool,
	key:       strings.Builder,
	allocator: runtime.Allocator,
}

result_graph_make :: proc(allocator := context.allocator) -> Result_Graph {
	return Result_Graph {
		triples = make([dynamic]rdf.Triple, allocator),
		seen = make(map[string]bool, allocator),
		key = strings.builder_make(allocator),
		allocator = allocator,
	}
}

result_graph_destroy :: proc(g: ^Result_Graph) {
	for t in g.triples {
		rdf.destroy_triple(t, g.allocator)
	}
	delete(g.triples)
	for key in g.seen {
		delete(key, g.allocator)
	}
	delete(g.seen)
	strings.builder_destroy(&g.key)
	g^ = {}
}

// result_graph_triples is the answer, valid until the graph is destroyed.
result_graph_triples :: proc(g: ^Result_Graph) -> []rdf.Triple {
	return g.triples[:]
}

// result_graph_add adds a copy of a triple, and reports whether it was
// new. A triple the graph already holds is not added twice.
result_graph_add :: proc(g: ^Result_Graph, t: rdf.Triple) -> bool {
	strings.builder_reset(&g.key)
	term_key(&g.key, t.subject)
	strings.write_byte(&g.key, '\x1f')
	term_key(&g.key, t.predicate)
	strings.write_byte(&g.key, '\x1f')
	term_key(&g.key, t.object)
	if strings.to_string(g.key) in g.seen {
		return false
	}
	g.seen[strings.clone(strings.to_string(g.key), g.allocator)] = true
	append(&g.triples, rdf.clone_triple(t, g.allocator))
	return true
}

// Template_Node is one position of a CONSTRUCT template triple: a
// variable to read out of the solution, a template blank node, or a
// ground term written in the query.
Template_Node :: struct {
	slot:  int, // >= 0: a variable slot
	blank: int, // >= 0: a template blank node, fresh in every solution
	term:  rdf.Term, // otherwise: the term as written, borrowing the query's parse
}

Template_Triple :: distinct [3]Template_Node

// Template is a CONSTRUCT template compiled against a query's slot table.
//
// blanks counts the distinct blank-node labels the template writes. They
// are *not* slots: §16.2 gives each solution its own blank nodes, so a
// label in the template names a different node in every solution, and
// what the compiled form keeps is an index rather than a name.
Template :: struct {
	triples:   [dynamic]Template_Triple,
	blanks:    int,
	labels:    [dynamic]string, // template label -> blank index, by position
	allocator: runtime.Allocator,
}

// template_build compiles a parsed CONSTRUCT template against the slot
// table a prepared query filled in. Call it after the query is prepared:
// the slots have to exist, and a template variable is looked up rather
// than assigned — a variable the pattern never binds cannot be assigned a
// column in a row whose width is already fixed.
//
// A template triple that can never produce anything is dropped here
// rather than at every solution: a variable the pattern does not bind is
// unbound in every solution, and §16.2 says an unbound position produces
// no triple.
template_build :: proc(
	t: ^Template,
	bp: ^Basic_Pattern,
	slots: ^Var_Slots,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	t.allocator = allocator
	t.triples = make([dynamic]Template_Triple, allocator)
	t.labels = make([dynamic]string, allocator)
	if bp == nil {
		return true
	}
	for source in bp.triples {
		triple: Template_Triple
		instantiable := true
		positions := [3]Pattern_Node{source.subject, source.predicate, source.object}
		for node, i in positions {
			resolved, node_ok := template_node(t, slots, node)
			if !node_ok {
				return false
			}
			if resolved.slot < 0 && resolved.blank < 0 && resolved.term == nil {
				// A variable the pattern never binds.
				instantiable = false
				break
			}
			triple[i] = resolved
		}
		if instantiable {
			append(&t.triples, triple)
		}
	}
	return true
}

template_destroy :: proc(t: ^Template) {
	delete(t.triples)
	delete(t.labels)
	t^ = {}
}

@(private = "file")
template_node :: proc(t: ^Template, slots: ^Var_Slots, node: Pattern_Node) -> (out: Template_Node, ok: bool) {
	out = Template_Node {
		slot  = -1,
		blank = -1,
	}
	switch v in node {
	case Var:
		slot, found := var_slot_lookup(slots, v.name)
		if !found {
			// Every field left at its "nothing" value: the caller reads
			// that as a triple it can drop.
			return out, true
		}
		out.slot = slot
		return out, true
	case rdf.Blank_Node:
		out.blank = template_blank(t, string(v))
		return out, true
	case rdf.IRI:
		out.term = v
		return out, true
	case rdf.Literal:
		out.term = v
		return out, true
	case ^Triple_Term:
		return out, false
	case ^Path_Expr:
		// The grammar forbids a path in a template, so reaching here is a
		// parser bug rather than an unsupported query.
		return out, false
	}
	return out, false
}

@(private = "file")
template_blank :: proc(t: ^Template, label: string) -> int {
	for existing, i in t.labels {
		if existing == label {
			return i
		}
	}
	append(&t.labels, label)
	t.blanks = len(t.labels)
	return len(t.labels) - 1
}

// construct_solution instantiates the template once, for one solution,
// adding what it produces to the graph (§16.2).
//
// Three ways a template triple produces nothing, none of them an error:
// a position whose variable this solution leaves unbound; a subject that
// came back a literal or a triple term; a predicate that is not an IRI.
// The specification's word is that such triples "are not included" —
// a CONSTRUCT over data it does not fit is a smaller graph, not a
// failure.
//
// solution numbers the solution being instantiated and must differ
// between calls: it is what makes the template's blank nodes fresh per
// solution, which is the rule §16.2 spends most of its length on.
construct_solution :: proc(
	graph: ^Result_Graph,
	template: ^Template,
	row: []store.Term_ID,
	solution: int,
	resolve: Term_Resolver,
	resolve_data: rawptr,
) {
	// One buffer per position, not one per triple: a label is a slice of
	// the buffer it was written into, and `_:a rdf:rest _:b` writes two of
	// them into one triple. Sharing a buffer would leave the subject
	// reading the object's label — which the CONSTRUCT-list test catches
	// and nothing else does.
	buffer: [3][48]byte
	for source in template.triples {
		triple: rdf.Triple
		complete := true
		for i in 0 ..< 3 {
			node := source[i]
			switch {
			case node.blank >= 0:
				label := blank_label(buffer[i][:], solution, node.blank)
				triple_set(&triple, i, rdf.Blank_Node(label))
			case node.slot >= 0:
				id := row[node.slot]
				if id == store.UNBOUND {
					complete = false
				} else {
					triple_set(&triple, i, resolve(resolve_data, id))
				}
			case:
				triple_set(&triple, i, node.term)
			}
			if !complete {
				break
			}
		}
		if !complete || !triple_is_rdf(triple) {
			continue
		}
		result_graph_add(graph, triple)
	}
}

@(private = "file")
triple_set :: proc(t: ^rdf.Triple, position: int, term: rdf.Term) {
	switch position {
	case 0:
		t.subject = term
	case 1:
		t.predicate = term
	case 2:
		t.object = term
	}
}

// triple_is_rdf reports whether an instantiated template triple is a
// triple the RDF data model admits: an IRI or blank-node subject, an IRI
// predicate, and any term as object.
@(private = "file")
triple_is_rdf :: proc(t: rdf.Triple) -> bool {
	#partial switch v in t.subject {
	case rdf.IRI, rdf.Blank_Node:
	case:
		return false
	}
	if _, is_iri := t.predicate.(rdf.IRI); !is_iri {
		return false
	}
	return t.object != nil
}

// blank_label names one of a solution's fresh blank nodes. The label is
// written into the caller's buffer and lives only until the triple built
// from it is copied into a graph — which result_graph_add does.
@(private = "file")
blank_label :: proc(buffer: []byte, solution: int, index: int) -> string {
	at := 0
	buffer[at] = 'b'
	at += 1
	at += len(strconv.write_int(buffer[at:], i64(solution), 10))
	buffer[at] = '_'
	at += 1
	at += len(strconv.write_int(buffer[at:], i64(index), 10))
	return string(buffer[:at])
}

// Describe_Targets is a DESCRIBE clause's resource list, compiled against
// a prepared query's slot table the way a template is: the IRIs written
// in the query resolved once, and the slots to read out of every
// solution.
//
// **What this engine's DESCRIBE returns**, since §16.4 leaves it to the
// implementation and says only that the result "describes" the
// resources: for each described resource, every triple of the query's
// default graph with that resource as its *subject*. Nothing else — no
// blank-node closure, no incoming triples, no schema. It is the smallest
// answer that is a description, it is a graph rather than a solution
// sequence, and it is stable, which is what a caller can build on. A
// resource the data says nothing about contributes nothing rather than
// failing.
Describe_Targets :: struct {
	slots:     [dynamic]int,
	ids:       [dynamic]store.Term_ID,
	allocator: runtime.Allocator,
}

// describe_build compiles a query's DESCRIBE clause. find resolves the
// IRIs it names against the store's dictionary without interning them,
// exactly as plan building resolves a pattern's ground terms; an IRI the
// store has never seen describes nothing.
//
// `DESCRIBE *` names every variable in scope, which after plan building
// is every non-internal slot — a pattern blank node is not a variable a
// query can describe any more than it is one a query can project.
describe_build :: proc(
	d: ^Describe_Targets,
	q: ^Query,
	slots: ^Var_Slots,
	find: Term_Finder,
	data: rawptr,
	allocator := context.allocator,
) {
	d.allocator = allocator
	d.slots = make([dynamic]int, allocator)
	d.ids = make([dynamic]store.Term_ID, allocator)
	if q.select_star {
		for internal, slot in slots.internal {
			if !internal {
				append(&d.slots, slot)
			}
		}
		return
	}
	for target in q.describe {
		#partial switch v in target {
		case Var:
			if slot, found := var_slot_lookup(slots, v.name); found {
				append(&d.slots, slot)
			}
		case rdf.IRI:
			if id, found := find(data, v); found {
				append(&d.ids, id)
			}
		}
	}
}

describe_destroy :: proc(d: ^Describe_Targets) {
	delete(d.slots)
	delete(d.ids)
	d^ = {}
}

// describe_collect adds the resources one solution names to the set being
// described. A described resource is described once however many
// solutions name it.
describe_collect :: proc(
	d: ^Describe_Targets,
	row: []store.Term_ID,
	out: ^[dynamic]store.Term_ID,
	seen: ^map[store.Term_ID]bool,
) {
	for slot in d.slots {
		id := row[slot]
		if id == store.UNBOUND || id in seen^ {
			continue
		}
		seen^[id] = true
		append(out, id)
	}
}

// describe_ground adds the IRIs the clause named outright. They do not
// depend on a solution — `DESCRIBE <x>` with no WHERE describes <x> — so
// they are added once, whether or not the pattern had any answers.
describe_ground :: proc(d: ^Describe_Targets, out: ^[dynamic]store.Term_ID, seen: ^map[store.Term_ID]bool) {
	for id in d.ids {
		if id in seen^ {
			continue
		}
		seen^[id] = true
		append(out, id)
	}
}
