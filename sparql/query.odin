// The prepared query: the engine's public entry point (SPARQL-T-0031).
//
// This file was `sparql/kvstore/eval.odin` until the port. It existed as
// a separate package because the engine core named no backend and had to
// be instantiated against one — and everything in it that was not the
// public API was there to bridge that gap: a Session carrying an error
// slot, five adapters, and two more to break a cycle of generic
// instantiations the compiler could not close. odin-rdf-record is the
// one and only store (owner, 2026-08-24), so the bridge is gone and what
// is left is the API itself.
//
// Three things went with it and are worth naming, because their absence
// is the shape of the port:
//
//   - **No error slot.** A kvstore read could fail, and the core's
//     hot-path signatures had nowhere to put a failure, so the dataset
//     handle carried one and `query_error` reported it. record's
//     projection is memory-resident: a read cannot fail. An empty answer
//     is the answer, and every `err != nil` branch behind that slot is
//     deleted rather than ported.
//   - **No second constructor.** `query_init_txn` prepared a query
//     against a transaction the caller held, where `query_init` opened
//     its own. On record the distinction has nothing to name: a snapshot
//     is a snapshot whether it came from `store_latest`, from `store_at`,
//     or from a `Validator`'s candidate at the epoch a write would
//     create. The consumer that motivated the second constructor — one
//     judging whether a candidate may join the dataset — reaches it
//     through record's validation hook, and calls the ordinary one.
//   - **No transaction.** SPARQL-T-0024's property is unchanged and now
//     costs nothing to state: a query is one dataset, and on record a
//     snapshot *is* a dataset. Where a kvstore query pinned pages for as
//     long as it lived, a record snapshot pins one index set, and the
//     as-of query odin-rdf-store needed `txn_begin_as_of` for is
//     `store_at`.
package sparql

import "base:runtime"

import rdf "rdf:rdf"
import record "record:record"

// Materialized_Term is one term `query_term` built, and what it takes to
// release it.
//
// The id is kept because `record.snapshot_term_destroy` needs it — a
// decoded term cannot say whether it borrows the dictionary arena, owns
// a joined IRI, or owns a whole triple-term tree (RECORD-A-0008) — and
// the buffer because an inlined literal materializes into caller-supplied
// bytes and *borrows* them, so they have to outlive the term.
@(private)
Materialized_Term :: struct {
	id:   record.Term_ID,
	term: rdf.Term,
	buf:  []byte,
}

// Query is a prepared query bound to one snapshot of one store.
//
// It must not be copied after query_init: the executor and the plan
// builder hold pointers into it, and the expression context holds one
// back to the executor.
Query :: struct {
	snapshot:     record.Snapshot,
	slots:        Var_Slots,
	plan:         Plan,
	exec:         Exec,
	materialized: [dynamic]Materialized_Term,
	unsupported:  string,
	exists_plans: []Plan,
	exists_nodes: []^Exists_Expr,
	builder:      Plan_Builder,
	allocator:    runtime.Allocator,
}

// query_init prepares an algebra tree for evaluation against one
// snapshot.
//
// ok is false when the algebra uses an operator this engine does not
// implement yet, and q.unsupported names it. That is the only way
// preparation fails: binding the query's ground terms cannot, because a
// term the store has never seen is an ordinary answer (the pattern
// matches nothing) rather than an error.
//
// **The snapshot is what makes the answer an answer.** A query is
// defined against one dataset; term binding, one scan per pattern per
// depth, and materialization at the answer boundary are otherwise three
// independent reads, and nothing would make them agree if a writer
// committed between them. The result would be a solution assembled from
// two datasets, which is not an answer to the query at all. This is the
// same property the engine already gives NOW() (§17.4.5.1), moved from
// the clock to the data.
//
// **The snapshot is the caller's and is not released here** — the same
// rule as the algebra and the store. It must outlive the Query, and
// nothing checks that, for the same reason nothing checks that the store
// does. Releasing it from `query_destroy` was considered and is wrong in
// the one case the single constructor exists to serve: a `Validator`'s
// candidate is a borrowed handle record releases itself, and a query
// that released it too would drop a reference it never took.
//
// base is the query's base IRI, which IRI() resolves relative references
// against (§17.4.2.8); pass sparql.parser_base of the parser the algebra
// came from. A query with no IRI() call never reads it.
query_init :: proc(
	q: ^Query,
	algebra: Algebra,
	snapshot: record.Snapshot,
	base := "",
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	q.allocator = allocator
	q.snapshot = snapshot
	q.materialized = make([dynamic]Materialized_Term, allocator)
	var_slots_init(&q.slots, allocator)

	plan_builder_init(&q.builder, &q.slots, snapshot, allocator)
	plan, built := plan_build(&q.builder, algebra)
	if !built {
		q.unsupported = q.builder.unsupported
		return false
	}
	q.plan = plan
	q.exists_plans = q.builder.exists_plans[:]
	q.exists_nodes = q.builder.exists_nodes[:]
	exec_init(&q.exec, plan, &q.slots, snapshot, q.exists_plans, q.exists_nodes, allocator)
	exec_set_base(&q.exec, base)
	return true
}

// query_next yields the next solution as a row indexed by variable slot.
// A false result means exhaustion — there is nothing else it can mean.
query_next :: proc(q: ^Query) -> (row: []record.Term_ID, ok: bool) {
	return exec_next(&q.exec)
}

// query_destroy releases everything preparing and running the query
// allocated: the plan and its EXISTS sub-plans, the slot table, the
// operator state, every term the query computed, and every term
// query_term materialized. Safe on a query whose query_init returned
// false.
//
// It does not free the algebra (the parser owns that), the store, the
// snapshot (see query_init), or a Result_Graph a CONSTRUCT or DESCRIBE
// handed back.
query_destroy :: proc(q: ^Query) {
	exec_destroy(&q.exec)
	plan_destroy(q.plan, q.allocator)
	for sub in q.exists_plans {
		plan_destroy(sub, q.allocator)
	}
	plan_builder_destroy(&q.builder)
	var_slots_destroy(&q.slots)
	// Through record's verb and not rdf.destroy_term: a term decoded out
	// of the dictionary arena borrows memory the store owns, and freeing
	// it would corrupt the store rather than the query.
	for entry in q.materialized {
		record.snapshot_term_destroy(q.snapshot, entry.id, entry.term, q.allocator)
		delete(entry.buf, q.allocator)
	}
	delete(q.materialized)
	q^ = {}
}

// query_term materializes a result ID back into an RDF term. The term is
// owned by the query and valid until query_destroy.
query_term :: proc(q: ^Query, id: record.Term_ID) -> rdf.Term {
	if computed, is_computed := exec_computed_term(&q.exec, id); is_computed {
		return computed
	}
	// The answer boundary, and it is a store round trip like any other.
	// No `load` tick: nothing in the *evaluation* asked for this — the
	// caller did, once it had a row in hand. Counting it as a load would
	// make the comparable half of the tally depend on whether the
	// benchmark bothered to render its answers.
	when SPARQL_COUNT_READS {
		read_counts.store_ops += 1
	}
	// An inlined literal decodes into these bytes and borrows them, so
	// the buffer is kept beside the term rather than on the stack. A
	// dictionary term ignores it; 16 bytes is what record's contract asks
	// for and is cheaper than deciding which case this is.
	buf := make([]byte, record.INLINE_LEXICAL_MAX, q.allocator)
	term, ok := record.snapshot_term(q.snapshot, id, buf, q.allocator)
	if !ok {
		delete(buf, q.allocator)
		return nil
	}
	append(&q.materialized, Materialized_Term{id = id, term = term, buf = buf})
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
// template_build for why that has to happen after preparation.
query_slots :: proc(q: ^Query) -> ^Var_Slots {
	return &q.slots
}

// query_find resolves a ground term to its store ID without interning
// it, for a DESCRIBE clause's IRIs.
query_find :: proc(q: ^Query, term: rdf.Term) -> (id: record.Term_ID, found: bool) {
	return exec_resolve(q.snapshot, term)
}

// query_snapshot is the dataset this query answers about — what
// describe_build is compiled against, and the epoch a caller reporting
// on the answer would name.
query_snapshot :: proc(q: ^Query) -> record.Snapshot {
	return q.snapshot
}

// query_construct runs the query and instantiates a CONSTRUCT template
// once per solution (§16.2), returning the graph.
//
// The graph owns every term in it and the caller frees it with
// result_graph_destroy. The copy is deliberate: the terms query_term
// hands out are the query's own bookkeeping, which query_destroy
// releases, so a result that borrowed them would be freed out from under
// its holder.
query_construct :: proc(
	q: ^Query,
	template: ^Template,
	allocator := context.allocator,
) -> Result_Graph {
	graph := result_graph_make(allocator)
	solution := 0
	for {
		row, more := query_next(q)
		if !more {
			break
		}
		construct_solution(&graph, template, row, solution, q)
		solution += 1
	}
	return graph
}

// query_describe runs the query and describes every resource its
// DESCRIBE clause names (§16.4). Ownership is the same contract as
// query_construct's.
query_describe :: proc(
	q: ^Query,
	targets: ^Describe_Targets,
	allocator := context.allocator,
) -> Result_Graph {
	graph := result_graph_make(allocator)
	subjects := make([dynamic]record.Term_ID, allocator)
	defer delete(subjects)
	seen := make(map[record.Term_ID]bool, allocator)
	defer delete(seen)

	describe_ground(targets, &subjects, &seen)
	for {
		row, more := query_next(q)
		if !more {
			break
		}
		describe_collect(targets, row, &subjects, &seen)
	}
	exec_describe(&q.exec, subjects[:], &graph, q)
	return graph
}
