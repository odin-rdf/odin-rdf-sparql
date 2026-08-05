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

// result_graph_make prepares an empty graph. Everything it and the
// triples added to it own comes from the given allocator; free it with
// result_graph_destroy.
result_graph_make :: proc(allocator := context.allocator) -> Result_Graph {
	return Result_Graph {
		triples = make([dynamic]rdf.Triple, allocator),
		seen = make(map[string]bool, allocator),
		key = strings.builder_make(allocator),
		allocator = allocator,
	}
}

// result_graph_destroy frees the graph and every term in it. The
// triples result_graph_triples handed out become invalid; a caller that
// keeps one clones it first.
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
// variable to read out of the solution, a template blank node, a ground
// term written in the query, or a triple term to build per solution
// out of nodes of its own.
Template_Node :: struct {
	slot:  int, // >= 0: a variable slot
	blank: int, // >= 0: a template blank node, fresh in every solution
	// >= 0: the index in Template.terms of a triple term to instantiate.
	triple: int,
	term:  rdf.Term, // otherwise: the term as written, borrowing the query's parse
}

// Template_Term is a SPARQL 1.2 triple term in a template: its three
// positions, compiled exactly as a triple's are.
//
// A triple term's own components can be triple terms, so the compiled
// forms live in one list and refer to each other by index — the same
// reason the plan's shapes do (plan.odin). A child is always listed
// after its parent, so instantiating the list backwards builds every
// nested term before the one that contains it.
Template_Term :: distinct [3]Template_Node

// Template_Triple is one triple of a template, compiled: three positions
// to fill per solution.
Template_Triple :: distinct [3]Template_Node

// Template is a CONSTRUCT template compiled against a query's slot table.
//
// blanks counts the distinct blank-node labels the template writes. They
// are *not* slots: §16.2 gives each solution its own blank nodes, so a
// label in the template names a different node in every solution, and
// what the compiled form keeps is an index rather than a name.
Template :: struct {
	triples:   [dynamic]Template_Triple,
	// The triple terms the template writes, in the order compiled: a
	// parent before the terms nested inside it.
	terms:     [dynamic]Template_Term,
	blanks:    int,
	labels:    [dynamic]string, // template label -> blank index, by position
	// Per-solution scratch, sized once when the template is compiled.
	// nodes is the triple each compiled term is instantiated into and
	// built says whether this solution could instantiate it; buffers
	// holds one blank-node label per position, because a label is a
	// slice of the buffer it was written into and two positions of one
	// triple must not share.
	nodes:     []rdf.Triple,
	built:     []rdf.Term,
	buffers:   [][48]byte,
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
	t.terms = make([dynamic]Template_Term, allocator)
	t.labels = make([dynamic]string, allocator)
	defer template_scratch(t)
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
			if template_node_empty(resolved) {
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

// template_scratch sizes the per-solution working memory: one node per
// compiled triple term, and a label buffer for every position that could
// hold a blank node — the three of the triple being built plus the three
// of each term.
@(private = "file")
template_scratch :: proc(t: ^Template) {
	t.nodes = make([]rdf.Triple, len(t.terms), t.allocator)
	t.built = make([]rdf.Term, len(t.terms), t.allocator)
	t.buffers = make([][48]byte, 3 + 3 * len(t.terms), t.allocator)
}

// template_destroy frees the compiled template and its per-solution
// scratch. It does not free the graph a CONSTRUCT built — the two have
// different lifetimes, and the graph outlives the template that made it.
template_destroy :: proc(t: ^Template) {
	delete(t.triples)
	delete(t.terms)
	delete(t.labels)
	delete(t.nodes, t.allocator)
	delete(t.built, t.allocator)
	delete(t.buffers, t.allocator)
	t^ = {}
}

// template_node_empty reports a position that can never be instantiated:
// a variable the pattern never binds. Every field is at its "nothing"
// value, which the caller reads as a triple it can drop.
@(private = "file")
template_node_empty :: proc(node: Template_Node) -> bool {
	return node.slot < 0 && node.blank < 0 && node.triple < 0 && node.term == nil
}

@(private = "file")
template_node :: proc(t: ^Template, slots: ^Var_Slots, node: Pattern_Node) -> (out: Template_Node, ok: bool) {
	out = Template_Node {
		slot   = -1,
		blank  = -1,
		triple = -1,
	}
	switch v in node {
	case Var:
		slot, found := var_slot_lookup(slots, v.name)
		if !found {
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
		index, term_ok := template_term(t, slots, v)
		if !term_ok {
			return out, false
		}
		out.triple = index
		return out, true
	case ^Path_Expr:
		// The grammar forbids a path in a template, so reaching here is a
		// parser bug rather than an unsupported query.
		return out, false
	}
	return out, false
}

// template_term compiles a triple term and returns its index. The
// placeholder is appended before the components are compiled, so a
// nested term lands after the one that contains it — which is what lets
// instantiation walk the list backwards and build children first.
//
// A component that can never be instantiated is left as it is rather
// than making the whole template invalid: the term simply produces
// nothing in every solution, and so does whatever contains it.
@(private = "file")
template_term :: proc(t: ^Template, slots: ^Var_Slots, tt: ^Triple_Term) -> (index: int, ok: bool) {
	if tt == nil {
		return -1, false
	}
	index = len(t.terms)
	append(&t.terms, Template_Term{})
	for node, i in ([3]Pattern_Node{tt.subject, tt.predicate, tt.object}) {
		resolved, node_ok := template_node(t, slots, node)
		if !node_ok {
			return -1, false
		}
		t.terms[index][i] = resolved
	}
	return index, true
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
	template_build_terms(template, row, solution, resolve, resolve_data)
	for source in template.triples {
		triple: rdf.Triple
		complete := true
		for i in 0 ..< 3 {
			// One buffer per position, not one per triple: a label is a
			// slice of the buffer it was written into, and
			// `_:a rdf:rest _:b` writes two of them into one triple.
			// Sharing a buffer would leave the subject reading the
			// object's label — which the CONSTRUCT-list test catches and
			// nothing else does.
			term, ok := template_value(template, source[i], row, solution, resolve, resolve_data, i)
			if !ok {
				complete = false
				break
			}
			triple_set(&triple, i, term)
		}
		if !complete || !triple_is_rdf(triple) {
			continue
		}
		result_graph_add(graph, triple)
	}
}

// template_build_terms instantiates this solution's triple terms, from
// the end of the list to the front: a nested term is compiled after the
// one that contains it, so building backwards means every component is
// ready when the term that holds it is reached.
@(private = "file")
template_build_terms :: proc(
	t: ^Template,
	row: []store.Term_ID,
	solution: int,
	resolve: Term_Resolver,
	resolve_data: rawptr,
) {
	#reverse for source, index in t.terms {
		t.built[index] = nil
		node := &t.nodes[index]
		node^ = {}
		complete := true
		for i in 0 ..< 3 {
			term, ok := template_value(t, source[i], row, solution, resolve, resolve_data, 3 + 3 * index + i)
			if !ok {
				complete = false
				break
			}
			triple_set(node, i, term)
		}
		// A triple term the data model does not admit — a literal
		// subject, a predicate that is not an IRI — is not built, and
		// nothing that would have contained it is either. Same rule as
		// the enclosing triple's, for the same reason.
		if complete && triple_is_rdf(node^) {
			t.built[index] = node
		}
	}
}

// template_value is one instantiated template position, or ok=false when
// this solution cannot fill it: an unbound variable, or a triple term
// that could not be built. buffer names the label scratch a blank node
// in this position writes into.
@(private = "file")
template_value :: proc(
	t: ^Template,
	node: Template_Node,
	row: []store.Term_ID,
	solution: int,
	resolve: Term_Resolver,
	resolve_data: rawptr,
	buffer: int,
) -> (
	term: rdf.Term,
	ok: bool,
) {
	switch {
	case node.blank >= 0:
		return rdf.Blank_Node(blank_label(t.buffers[buffer][:], solution, node.blank)), true
	case node.slot >= 0:
		id := row[node.slot]
		if id == store.UNBOUND {
			return nil, false
		}
		return resolve(resolve_data, id), true
	case node.triple >= 0:
		built := t.built[node.triple]
		return built, built != nil
	}
	return node.term, node.term != nil
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

// describe_destroy frees the compiled clause. As with a template, the
// graph it helped build is the caller's and is freed separately.
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
