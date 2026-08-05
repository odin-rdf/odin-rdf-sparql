// The kvstore instantiation of the evaluation engine — the persistent
// twin of `sparql/memstore`. Read the two together: the engine core is
// shared and unchanged, and everything different here is a consequence of
// the backend, not of the query language.
//
// Three differences the adapters absorb:
//
//   - **One handle, not two.** kvstore keeps its dictionary and its
//     quads in one Store, where memstore keeps a Dictionary and a
//     Dataset. The core does not care: it is generic over whatever the
//     dataset handle is.
//   - **Operations can fail.** An LMDB read can return an error, and the
//     core's hot-path signatures have nowhere to put one. Swallowing it
//     would be the worst outcome — a failed read would be
//     indistinguishable from a pattern that matched nothing — so the
//     dataset handle the core is given is a Session, which carries an
//     error slot the adapters write and query_error reports.
//   - **Materialization allocates.** kvstore's lookup_term builds a term
//     from the database's bytes, where memstore's borrows the
//     dictionary's. The Query keeps every term it materialized and frees
//     them on destroy, so both packages offer the same contract: the
//     term is valid until the query is destroyed.
package sparql_kvstore

import "base:runtime"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

// Session is the dataset handle the core executes against: the store,
// plus the place a failed store operation is recorded.
Session :: struct {
	store: ^kvstore.Store,
	err:   kvstore.Error,
}

@(private)
match_adapter :: proc(session: ^Session, pattern: store.Match_Pattern) -> kvstore.Match_Iterator {
	it, err := kvstore.match(session.store, pattern)
	if err != nil {
		session.err = err
		// A failed match must not look like an exhausted one to the
		// caller, but it must still be safe to step and to destroy — so
		// hand back an iterator that is already done. The error is what
		// the caller acts on; this only keeps the walk well-formed.
		return kvstore.Match_Iterator{state = .Done}
	}
	return it
}

@(private)
next_adapter :: proc(it: ^kvstore.Match_Iterator) -> (store.Encoded_Quad, bool) {
	return kvstore.match_next(it)
}

@(private)
destroy_adapter :: proc(it: ^kvstore.Match_Iterator) {
	kvstore.match_destroy(it)
}

// load_adapter materializes a result ID during expression evaluation.
// kvstore builds the term from the database's bytes, so it is owned and
// the expression context releases it when the evaluation ends.
@(private)
load_adapter :: proc(
	data: rawptr,
	id: store.Term_ID,
	allocator: runtime.Allocator,
) -> (
	term: rdf.Term,
	owned: bool,
) {
	session := cast(^Session)data
	loaded, err := kvstore.lookup_term(session.store, id, allocator)
	if err != nil {
		session.err = err
		return nil, false
	}
	return loaded, true
}

// find_adapter is the term-binding bridge. kvstore's find_term serves
// from a read transaction and writes nothing — the reason STORE-T-0014
// exists: resolving a query's ground terms with intern_term would turn
// every query into a write transaction.
@(private)
find_adapter :: proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	session := cast(^Session)data
	resolved, present, err := kvstore.find_term(session.store, term)
	if err != nil {
		session.err = err
		return 0, false
	}
	return resolved, present
}

// exists_adapter is the door back into the generic executor. An
// expression cannot call it directly — the call would complete a cycle
// of generic instantiations that the compiler cannot close — so it goes
// through a procedure value, which is concrete here.
@(private)
exists_adapter :: proc(data: rawptr, index: int) -> bool {
	e := cast(^sparql.Exec(Session, kvstore.Match_Iterator))data
	return sparql.exec_exists(e, index, match_adapter, next_adapter, destroy_adapter)
}

// Query is a prepared query bound to one store.
Query :: struct {
	session:      Session,
	slots:        sparql.Var_Slots,
	plan:         sparql.Plan,
	exec:         sparql.Exec(Session, kvstore.Match_Iterator),
	materialized: [dynamic]rdf.Term,
	unsupported:  string,
	exists_plans: []sparql.Plan,
	exists_nodes: []^sparql.Exists_Expr,
	builder:      sparql.Plan_Builder,
	allocator:    runtime.Allocator,
}

// query_init prepares an algebra tree for evaluation against a store.
// ok is false when the algebra uses an operator this engine does not
// implement yet (q.unsupported names it) or when the store failed while
// the query's terms were being resolved (query_error reports it).
//
// base is the query's base IRI, which IRI() resolves relative
// references against (§17.4.2.8); pass sparql.parser_base of the parser
// the algebra came from. A query with no IRI() call never reads it.
query_init :: proc(
	q: ^Query,
	algebra: sparql.Algebra,
	s: ^kvstore.Store,
	base := "",
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	q.allocator = allocator
	q.session = Session {
		store = s,
	}
	q.materialized = make([dynamic]rdf.Term, allocator)
	sparql.var_slots_init(&q.slots, allocator)

	sparql.plan_builder_init(&q.builder, &q.slots, find_adapter, &q.session, allocator)
	plan, built := sparql.plan_build(&q.builder, algebra)
	if !built {
		q.unsupported = q.builder.unsupported
		return false
	}
	q.plan = plan
	q.exists_plans = q.builder.exists_plans[:]
	q.exists_nodes = q.builder.exists_nodes[:]
	if q.session.err != nil {
		sparql.plan_destroy(plan, allocator)
		q.plan = nil
		return false
	}
	sparql.exec_init(&q.exec, plan, &q.slots, &q.session, load_adapter, &q.session, find_adapter, &q.session, q.exists_plans, q.exists_nodes, exists_adapter, allocator)
	sparql.exec_set_base(&q.exec, base)
	return true
}

// query_next yields the next solution as a row indexed by variable slot.
// A false result means either exhaustion or a store failure; ask
// query_error to tell them apart.
query_next :: proc(q: ^Query) -> (row: []store.Term_ID, ok: bool) {
	return sparql.exec_next(&q.exec, match_adapter, next_adapter, destroy_adapter)
}

// query_error reports the store failure that ended evaluation, or nil if
// evaluation simply ran out of solutions.
query_error :: proc(q: ^Query) -> kvstore.Error {
	return q.session.err
}

query_destroy :: proc(q: ^Query) {
	sparql.exec_destroy(&q.exec, destroy_adapter)
	sparql.plan_destroy(q.plan, q.allocator)
	for sub in q.exists_plans {
		sparql.plan_destroy(sub, q.allocator)
	}
	sparql.plan_builder_destroy(&q.builder)
	sparql.var_slots_destroy(&q.slots)
	for term in q.materialized {
		rdf.destroy_term(term, q.allocator)
	}
	delete(q.materialized)
	q^ = {}
}

// query_term materializes a result ID back into an RDF term. The term is
// owned by the query and valid until query_destroy — the same contract
// the memstore instantiation offers, reached differently.
query_term :: proc(q: ^Query, id: store.Term_ID) -> rdf.Term {
	if computed, is_computed := sparql.exec_computed_term(&q.exec, id); is_computed {
		return computed
	}
	term, err := kvstore.lookup_term(q.session.store, id, q.allocator)
	if err != nil {
		q.session.err = err
		return nil
	}
	append(&q.materialized, term)
	return term
}

query_var_names :: proc(q: ^Query) -> []string {
	return q.slots.names[:]
}

query_var_internal :: proc(q: ^Query) -> []bool {
	return q.slots.internal[:]
}
