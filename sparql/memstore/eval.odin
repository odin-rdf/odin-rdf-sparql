// The memstore instantiation of the evaluation engine.
//
// The engine core (package sparql) names no storage backend and imports
// none. This package is the other half: it binds the core's three
// hot-path store operations to memstore's, resolves the query's ground
// terms through memstore's dictionary, and materializes result IDs back
// into RDF terms. `sparql/kvstore` is the same file against the
// persistent backend, and the two are meant to stay recognizably
// parallel — a change to one is a question about the other.
//
// Why an instantiation package rather than a backend switch inside the
// core: kvstore foreign-imports a static LMDB archive, so a core that
// imported it would put LMDB into the link of every consumer, including
// the ones that only ever want an in-memory store. The backends also
// differ in shape — memstore keeps a dictionary and a dataset, kvstore
// keeps one handle; memstore's operations cannot fail, kvstore's can;
// memstore's lookup_term borrows, kvstore's allocates — and absorbing
// those three differences is exactly what these packages are for.
package sparql_memstore

import "base:runtime"

import rdf "rdf:rdf"
import store "store:store"
import memstore "store:store/memstore"

import sparql ".."

// The three hot-path adapters. They are ordinary procedures, passed to
// the core as compile-time constants, so the executor monomorphizes
// against them and every call is direct.
@(private)
match_adapter :: proc(dataset: ^memstore.Dataset, pattern: store.Match_Pattern) -> memstore.Match_Iterator {
	return memstore.match(dataset, pattern)
}

@(private)
next_adapter :: proc(it: ^memstore.Match_Iterator) -> (store.Encoded_Quad, bool) {
	return memstore.match_next(it)
}

@(private)
destroy_adapter :: proc(it: ^memstore.Match_Iterator) {
	memstore.match_destroy(it)
}

// load_adapter materializes a result ID during expression evaluation.
// memstore's lookup_term borrows the dictionary's storage, so nothing is
// owned and nothing needs freeing.
@(private)
load_adapter :: proc(
	data: rawptr,
	id: store.Term_ID,
	allocator: runtime.Allocator,
) -> (
	term: rdf.Term,
	owned: bool,
) {
	dictionary := cast(^memstore.Dictionary)data
	return memstore.lookup_term(dictionary, id), false
}

// find_adapter is the term-binding bridge: the store's non-interning
// lookup, so preparing a query never assigns an ID.
@(private)
find_adapter :: proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	dictionary := cast(^memstore.Dictionary)data
	return memstore.find_term(dictionary, term)
}

// triple_adapter takes a stored triple term apart, for a triple-term
// pattern that is not ground. memstore's dictionary keeps the component
// IDs it interned the term from, so this is an array read and the
// pattern costs no allocation — see sparql.Triple_Reader for the
// direction the match interface is missing.
@(private)
triple_adapter :: proc(data: rawptr, id: store.Term_ID) -> (parts: [3]store.Term_ID, ok: bool) {
	dictionary := cast(^memstore.Dictionary)data
	if store.id_kind(id) != .Triple {
		return {}, false
	}
	counter := int(store.id_counter(id))
	if counter >= len(dictionary.triples) {
		return {}, false
	}
	return dictionary.triples[counter], true
}

// exists_adapter is the door back into the generic executor. An
// expression cannot call it directly — the call would complete a cycle
// of generic instantiations that the compiler cannot close — so it goes
// through a procedure value, which is concrete here.
@(private)
exists_adapter :: proc(data: rawptr, index: int) -> bool {
	e := cast(^sparql.Exec(memstore.Dataset, memstore.Match_Iterator))data
	return sparql.exec_exists(e, index, match_adapter, next_adapter, destroy_adapter)
}

// expand_adapter is the same door for a property path's step: the
// traversal is running inside the executor and has to run an operator tree
// to expand a frontier node, which only a concrete procedure can ask for.
@(private)
expand_adapter :: proc(
	data: rawptr,
	node: int,
	from: store.Term_ID,
	backward: bool,
	out: ^[dynamic]store.Term_ID,
) {
	e := cast(^sparql.Exec(memstore.Dataset, memstore.Match_Iterator))data
	sparql.exec_path_expand(e, node, from, backward, out, match_adapter, next_adapter, destroy_adapter)
}

// Query is a prepared query bound to one dataset: the slot table, the
// plan, and the running execution state.
Query :: struct {
	slots:       sparql.Var_Slots,
	plan:        sparql.Plan,
	exec:        sparql.Exec(memstore.Dataset, memstore.Match_Iterator),
	dictionary:  ^memstore.Dictionary,
	unsupported: string,
	// The EXISTS sub-plans plan building produced, owned here and
	// destroyed with the query.
	exists_plans: []sparql.Plan,
	exists_nodes: []^sparql.Exists_Expr,
	builder:      sparql.Plan_Builder,
	allocator:   runtime.Allocator,
}

// query_init prepares an algebra tree for evaluation against a dataset.
// ok is false when the algebra uses an operator this engine does not
// implement yet, in which case q.unsupported names it — an unimplemented
// operator is reported, never mistaken for a query with no answers.
//
// base is the query's base IRI, which IRI() resolves relative
// references against (§17.4.2.8); pass sparql.parser_base of the parser
// the algebra came from. A query with no IRI() call never reads it.
query_init :: proc(
	q: ^Query,
	algebra: sparql.Algebra,
	dictionary: ^memstore.Dictionary,
	dataset: ^memstore.Dataset,
	base := "",
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	q.allocator = allocator
	q.dictionary = dictionary
	sparql.var_slots_init(&q.slots, allocator)

	sparql.plan_builder_init(&q.builder, &q.slots, find_adapter, dictionary, allocator)
	plan, built := sparql.plan_build(&q.builder, algebra)
	if !built {
		q.unsupported = q.builder.unsupported
		return false
	}
	q.plan = plan
	q.exists_plans = q.builder.exists_plans[:]
	q.exists_nodes = q.builder.exists_nodes[:]
	sparql.exec_init(&q.exec, plan, &q.slots, dataset, load_adapter, dictionary, find_adapter, dictionary, triple_adapter, dictionary, q.exists_plans, q.exists_nodes, exists_adapter, expand_adapter, allocator)
	sparql.exec_set_base(&q.exec, base)
	return true
}

// query_next yields the next solution as a row indexed by variable slot,
// holding store.UNBOUND where a variable is unbound. The row is valid
// until the next call.
query_next :: proc(q: ^Query) -> (row: []store.Term_ID, ok: bool) {
	return sparql.exec_next(&q.exec, match_adapter, next_adapter, destroy_adapter)
}

// query_destroy releases everything preparing and running the query
// allocated: the plan and its EXISTS sub-plans, the slot table, the
// operator state, every match iterator a run left open, and every term
// the query computed. Safe on a query whose query_init returned false —
// a refused query still allocated the part of the plan that built.
//
// It does not free the algebra (the parser owns that), the dataset, or a
// Result_Graph a CONSTRUCT or DESCRIBE handed back. A term from
// query_term borrows the dictionary and outlives the query.
query_destroy :: proc(q: ^Query) {
	sparql.exec_destroy(&q.exec, destroy_adapter)
	sparql.plan_destroy(q.plan, q.allocator)
	for sub in q.exists_plans {
		sparql.plan_destroy(sub, q.allocator)
	}
	sparql.plan_builder_destroy(&q.builder)
	sparql.var_slots_destroy(&q.slots)
	q^ = {}
}

// query_term materializes a result ID back into an RDF term. The term
// borrows the dictionary's storage and is valid as long as the
// dictionary is — memstore's lookup_term does not copy, and this engine
// does not make it copy.
query_term :: proc(q: ^Query, id: store.Term_ID) -> rdf.Term {
	// A term the query computed rather than read has no store ID; the
	// engine named it itself, so it answers first.
	if computed, is_computed := sparql.exec_computed_term(&q.exec, id); is_computed {
		return computed
	}
	return memstore.lookup_term(q.dictionary, id)
}

// query_var_names and query_var_internal describe the row's columns: the
// variable each slot carries, and whether it is a pattern blank node
// rather than a query variable. A blank-node slot is never part of an
// answer, which is what makes `SELECT *` mean "every variable" and not
// "every slot".
//
// Both are indexed by slot, are as wide as a solution row, and borrow the
// query's slot table — valid until query_destroy.
query_var_names :: proc(q: ^Query) -> []string {
	return q.slots.names[:]
}

query_var_internal :: proc(q: ^Query) -> []bool {
	return q.slots.internal[:]
}

// query_slots is the prepared query's slot table, which is what a
// CONSTRUCT template or a DESCRIBE clause is compiled against — see
// sparql.template_build for why that has to happen after preparation.
query_slots :: proc(q: ^Query) -> ^sparql.Var_Slots {
	return &q.slots
}

// query_find resolves a ground term to its store ID without interning it,
// for a DESCRIBE clause's IRIs.
query_find :: proc(q: ^Query, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	return find_adapter(q.dictionary, term)
}

@(private)
resolve_adapter :: proc(data: rawptr, id: store.Term_ID) -> rdf.Term {
	return query_term(cast(^Query)data, id)
}

// query_construct runs the query and instantiates a CONSTRUCT template
// once per solution (§16.2), returning the graph.
//
// The graph owns every term in it, deep-copied out of the dictionary, and
// the caller frees it with sparql.result_graph_destroy. That is what lets
// an answer outlive the store it was read from — memstore's materialized
// terms borrow the dictionary's storage, and a result that borrowed it
// would be a dangling one the moment the dataset went away.
query_construct :: proc(
	q: ^Query,
	template: ^sparql.Template,
	allocator := context.allocator,
) -> sparql.Result_Graph {
	graph := sparql.result_graph_make(allocator)
	solution := 0
	for {
		row, more := query_next(q)
		if !more {
			break
		}
		sparql.construct_solution(&graph, template, row, solution, resolve_adapter, q)
		solution += 1
	}
	return graph
}

// query_describe runs the query and describes every resource its DESCRIBE
// clause names (§16.4). Ownership is the same contract as
// query_construct's.
query_describe :: proc(
	q: ^Query,
	targets: ^sparql.Describe_Targets,
	allocator := context.allocator,
) -> sparql.Result_Graph {
	graph := sparql.result_graph_make(allocator)
	subjects := make([dynamic]store.Term_ID, allocator)
	defer delete(subjects)
	seen := make(map[store.Term_ID]bool, allocator)
	defer delete(seen)

	sparql.describe_ground(targets, &subjects, &seen)
	for {
		row, more := query_next(q)
		if !more {
			break
		}
		sparql.describe_collect(targets, row, &subjects, &seen)
	}
	sparql.exec_describe(
		&q.exec,
		subjects[:],
		&graph,
		resolve_adapter,
		q,
		match_adapter,
		next_adapter,
		destroy_adapter,
	)
	return graph
}
