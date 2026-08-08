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
//   - **A query is one snapshot.** Every read goes through a read
//     transaction taken at query_init and ended at query_destroy
//     (SPARQL-T-0024), because a persistent store is a store somebody
//     else can be writing to. That is a property the in-memory backend
//     had no way to offer and a single-threaded suite has no way to
//     miss.
package sparql_kvstore

import "base:runtime"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

// Session is the dataset handle the core executes against: the
// transaction every read goes through, plus the place a failed store
// operation is recorded.
//
// **It is a transaction rather than a store, and never both** — the
// snapshot is not optional (SPARQL-T-0024). A query is defined against
// one dataset, and reading each pattern through its own autocommit
// transaction would answer about a sequence of them. So there is exactly
// one read path here, not a transactional one beside an autocommit one:
// a branch the suite could not exercise is a branch that rots.
//
// `txn` is non-nil for the whole life of a prepared Query. Where it comes
// from is query_init's business, or the caller's — see query_init_txn.
Session :: struct {
	txn: ^kvstore.Txn,
	err: kvstore.Error,
}

@(private)
match_adapter :: proc(session: ^Session, pattern: store.Match_Pattern) -> kvstore.Match_Iterator {
	// The iterator borrows the transaction: match_destroy closes the
	// cursor and leaves the transaction alone, so the executor's
	// open-and-close per pattern per depth is unaffected. It just stops
	// opening a fresh snapshot each time.
	it, err := kvstore.match_txn(session.txn, pattern)
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
	loaded, err := kvstore.lookup_term_txn(session.txn, id, allocator)
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
	resolved, present, err := kvstore.find_term_txn(session.txn, term)
	if err != nil {
		session.err = err
		return 0, false
	}
	return resolved, present
}

// triple_adapter takes a stored triple term apart, for a triple-term
// pattern that is not ground. Where memstore reads the component IDs it
// already holds, kvstore has to materialize the whole term and look each
// component up again — two round trips through the database for
// something the dictionary knows outright. That is the store evidence
// sparql.Triple_Reader records for SPARQL-T-0019.
@(private)
triple_adapter :: proc(data: rawptr, id: store.Term_ID) -> (parts: [3]store.Term_ID, ok: bool) {
	session := cast(^Session)data
	if store.id_kind(id) != .Triple {
		return {}, false
	}
	term, err := kvstore.lookup_term_txn(session.txn, id, context.allocator)
	if err != nil {
		session.err = err
		return {}, false
	}
	defer rdf.destroy_term(term, context.allocator)
	triple, is_triple := term.(^rdf.Triple)
	if !is_triple || triple == nil {
		return {}, false
	}
	for component, i in ([3]rdf.Term{triple.subject, triple.predicate, triple.object}) {
		resolved, present, find_err := kvstore.find_term_txn(session.txn, component)
		if find_err != nil {
			session.err = find_err
			return {}, false
		}
		if !present {
			// A component of a stored term is itself stored, so this
			// cannot happen against a consistent store; reporting it as
			// "no match" rather than asserting keeps a corrupted database
			// from taking the process down.
			return {}, false
		}
		parts[i] = resolved
	}
	return parts, true
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
	e := cast(^sparql.Exec(Session, kvstore.Match_Iterator))data
	sparql.exec_path_expand(e, node, from, backward, out, match_adapter, next_adapter, destroy_adapter)
}

// Query is a prepared query bound to one snapshot of one store.
//
// `txn` is the snapshot when this query opened its own — `session.txn`
// points at it, so a Query must not be copied after query_init. That was
// already true (the executor and the plan builder hold pointers into it);
// this adds one more reason rather than a new rule.
Query :: struct {
	session:      Session,
	txn:          kvstore.Txn,
	owns_txn:     bool,
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

// query_init prepares an algebra tree for evaluation against a store,
// **taking a read transaction that lives exactly as long as the Query**.
// query_destroy ends it.
//
// ok is false when the algebra uses an operator this engine does not
// implement yet (q.unsupported names it), when the store failed while the
// query's terms were being resolved, or when the transaction could not be
// opened at all — query_error reports the last two, and a failed init
// leaves no transaction behind.
//
// **The snapshot is what makes the answer an answer.** A query is defined
// against one dataset; term binding, one match iterator per pattern per
// depth, and materialization at the answer boundary are otherwise three
// independent reads, and nothing would make them agree if a writer
// committed between them. The result would be a solution assembled from
// two datasets, which is not an answer to the query at all. This is the
// same property the engine already gives NOW() (§17.4.5.1), moved from the
// clock to the data.
//
// **Its cost is that an open read transaction pins pages**, so a
// concurrent writer grows the file for as long as this query lives. The
// life of a query is a fine lifetime for that. A request handler that
// keeps a Query open across unrelated work is making a storage-sizing
// decision, and should know it is making one.
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
	tx, err := kvstore.txn_begin(s, .Read)
	if err != nil {
		q.session.err = err
		return false
	}
	// The handle is moved here and never copied again: this one is the
	// only one that will be ended.
	q.txn = tx
	q.owns_txn = true
	return query_prepare(q, algebra, &q.txn, base, allocator)
}

// query_init_txn prepares a query against a transaction the caller
// already holds, and **does not end it** — query_destroy leaves it open
// for the caller to commit or abort.
//
// Either mode is accepted, and the reason to reach for this rather than
// query_init is a write transaction: a consumer deciding whether a
// candidate may join the dataset needs the query to see the candidate,
// which means running inside the transaction that carries it. Through a
// read transaction it is simply a way to make several queries one answer
// about one dataset.
//
// The caller's transaction must outlive the Query. Nothing here checks
// that, for the same reason nothing checks that the store outlives it.
query_init_txn :: proc(
	q: ^Query,
	algebra: sparql.Algebra,
	tx: ^kvstore.Txn,
	base := "",
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	q.owns_txn = false
	return query_prepare(q, algebra, tx, base, allocator)
}

// The preparation both constructors share, once the transaction is
// settled. On every failure path it releases a transaction this Query
// opened, so a caller that abandons a failed init without calling
// query_destroy still leaks nothing; txn_abort zeroes its handle, so the
// destroy that usually follows is a no-op rather than a double end.
@(private)
query_prepare :: proc(
	q: ^Query,
	algebra: sparql.Algebra,
	tx: ^kvstore.Txn,
	base: string,
	allocator: runtime.Allocator,
) -> (
	ok: bool,
) {
	q.allocator = allocator
	q.session = Session {
		txn = tx,
	}
	q.materialized = make([dynamic]rdf.Term, allocator)
	sparql.var_slots_init(&q.slots, allocator)

	sparql.plan_builder_init(&q.builder, &q.slots, find_adapter, &q.session, allocator)
	plan, built := sparql.plan_build(&q.builder, algebra)
	if !built {
		q.unsupported = q.builder.unsupported
		query_txn_end(q)
		return false
	}
	q.plan = plan
	q.exists_plans = q.builder.exists_plans[:]
	q.exists_nodes = q.builder.exists_nodes[:]
	if q.session.err != nil {
		sparql.plan_destroy(plan, allocator)
		q.plan = nil
		query_txn_end(q)
		return false
	}
	sparql.exec_init(&q.exec, plan, &q.slots, &q.session, load_adapter, &q.session, find_adapter, &q.session, triple_adapter, &q.session, q.exists_plans, q.exists_nodes, exists_adapter, expand_adapter, allocator)
	sparql.exec_set_base(&q.exec, base)
	return true
}

// query_txn_end releases the snapshot if this Query opened it, and does
// nothing to one the caller supplied. Abort rather than commit: on a read
// transaction the two are equivalent, and abort is the one that says what
// is meant.
@(private)
query_txn_end :: proc(q: ^Query) {
	if q.owns_txn {
		kvstore.txn_abort(&q.txn)
		q.owns_txn = false
	}
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

// query_destroy releases everything preparing and running the query
// allocated: the plan and its EXISTS sub-plans, the slot table, the
// operator state, every match cursor a run left open, every term the
// query computed, and — unlike the memstore instantiation — every term
// query_term materialized, because kvstore's lookup_term builds rather
// than borrows. Safe on a query whose query_init returned false.
//
// **It also ends the snapshot**, which is why a Query is not something to
// hold idly: until this runs, a concurrent writer cannot reuse the pages
// this query can still see. A transaction handed in by query_init_txn is
// the caller's and is left open.
//
// It does not free the algebra (the parser owns that), the store, or a
// Result_Graph a CONSTRUCT or DESCRIBE handed back.
query_destroy :: proc(q: ^Query) {
	// Cursors first: a match iterator borrows the transaction, so every
	// one of them has to be closed before the transaction it reads
	// through goes away.
	sparql.exec_destroy(&q.exec, destroy_adapter)
	query_txn_end(q)
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
	term, err := kvstore.lookup_term_txn(q.session.txn, id, q.allocator)
	if err != nil {
		q.session.err = err
		return nil
	}
	append(&q.materialized, term)
	return term
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
	return find_adapter(&q.session, term)
}

@(private)
resolve_adapter :: proc(data: rawptr, id: store.Term_ID) -> rdf.Term {
	return query_term(cast(^Query)data, id)
}

// query_construct runs the query and instantiates a CONSTRUCT template
// once per solution (§16.2), returning the graph.
//
// The graph owns every term in it and the caller frees it with
// sparql.result_graph_destroy. Here the copy is the second one: kvstore
// builds each term from the database's bytes into the query's own
// bookkeeping, which query_destroy releases, so a result that borrowed it
// would be freed out from under its holder.
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
