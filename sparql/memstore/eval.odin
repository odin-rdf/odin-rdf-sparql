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

// Query is a prepared query bound to one dataset: the slot table, the
// plan, and the running execution state.
Query :: struct {
	slots:       sparql.Var_Slots,
	plan:        sparql.Plan,
	exec:        sparql.Exec(memstore.Dataset, memstore.Match_Iterator),
	dictionary:  ^memstore.Dictionary,
	unsupported: string,
	allocator:   runtime.Allocator,
}

// query_init prepares an algebra tree for evaluation against a dataset.
// ok is false when the algebra uses an operator this engine does not
// implement yet, in which case q.unsupported names it — an unimplemented
// operator is reported, never mistaken for a query with no answers.
query_init :: proc(
	q: ^Query,
	algebra: sparql.Algebra,
	dictionary: ^memstore.Dictionary,
	dataset: ^memstore.Dataset,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	q.allocator = allocator
	q.dictionary = dictionary
	sparql.var_slots_init(&q.slots, allocator)

	builder: sparql.Plan_Builder
	sparql.plan_builder_init(&builder, &q.slots, find_adapter, dictionary, allocator)
	plan, built := sparql.plan_build(&builder, algebra)
	if !built {
		q.unsupported = builder.unsupported
		return false
	}
	q.plan = plan
	sparql.exec_init(&q.exec, plan, &q.slots, dataset, load_adapter, dictionary, allocator)
	return true
}

// query_next yields the next solution as a row indexed by variable slot,
// holding store.UNBOUND where a variable is unbound. The row is valid
// until the next call.
query_next :: proc(q: ^Query) -> (row: []store.Term_ID, ok: bool) {
	return sparql.exec_next(&q.exec, match_adapter, next_adapter, destroy_adapter)
}

query_destroy :: proc(q: ^Query) {
	sparql.exec_destroy(&q.exec, destroy_adapter)
	sparql.plan_destroy(q.plan, q.allocator)
	sparql.var_slots_destroy(&q.slots)
	q^ = {}
}

// query_term materializes a result ID back into an RDF term. The term
// borrows the dictionary's storage and is valid as long as the
// dictionary is — memstore's lookup_term does not copy, and this engine
// does not make it copy.
query_term :: proc(q: ^Query, id: store.Term_ID) -> rdf.Term {
	return memstore.lookup_term(q.dictionary, id)
}

// query_var_names and query_var_internal describe the row's columns: the
// variable each slot carries, and whether it is a pattern blank node
// rather than a query variable. A blank-node slot is never part of an
// answer, which is what makes `SELECT *` mean "every variable" and not
// "every slot".
query_var_names :: proc(q: ^Query) -> []string {
	return q.slots.names[:]
}

query_var_internal :: proc(q: ^Query) -> []bool {
	return q.slots.internal[:]
}
