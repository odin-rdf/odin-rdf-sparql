// Running a W3C evaluation test end to end: load the entry's data,
// parse and translate its query, evaluate it, and turn the answer into
// the Result_Set that comparison understands.
//
// Both backends run every enabled test. That is the initiative's
// dual-backend discipline and it is not ceremony: the engine core is
// generic over the backend, so a difference between memstore and kvstore
// is either a backend bug or a place where the core leaked an assumption
// about one of them. Running both is how either becomes visible.
//
// The two backends have different types all the way down — different
// store handles, different query types, different failure modes — so
// this file dispatches on an enum rather than abstracting over them. The
// duplication is real and deliberate: the alternative is a procedure-
// pointer interface, which is fine in test code but would obscure that
// these are two genuinely separate instantiations.
package w3c

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql "../../../sparql"
import sparql_kv "../../../sparql/kvstore"
import sparql_mem "../../../sparql/memstore"

Backend :: enum {
	Memstore,
	Kvstore,
}

backend_name :: proc(b: Backend) -> string {
	switch b {
	case .Memstore:
		return "memstore"
	case .Kvstore:
		return "kvstore"
	}
	return "?"
}

// Eval_Status separates the three outcomes a test run can have. They
// must stay separate: an operator the engine has not implemented is not
// a wrong answer, and neither is a store failure — collapsing either
// into "no solutions" would make an unfinished engine look correct.
Eval_Status :: enum {
	Ok,
	Unsupported, // the engine does not implement something the query uses
	Failed, // the data would not load, the query would not parse, or the store errored
}

// evaluate_entry runs one manifest entry against one backend. detail is
// a static description when status is not Ok. The caller owns the result
// and frees it with result_set_destroy.
evaluate_entry :: proc(
	suite: Suite,
	e: Entry,
	backend: Backend,
) -> (
	rs: Result_Set,
	status: Eval_Status,
	detail: string,
) {
	query_path, _ := filepath.join({SUITE_ROOT, suite.dir, e.action})
	defer delete(query_path)
	source, read_err := os.read_entire_file(query_path, context.allocator)
	if read_err != nil {
		return {}, .Failed, "cannot read the query file"
	}
	defer delete(source)

	base := strings.concatenate({suite.base, e.action})
	defer delete(base)

	p: sparql.Parser
	sparql.parser_init(&p, source, base)
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !parsed {
		return {}, .Failed, "the query did not parse"
	}
	algebra, translated := sparql.translate(&p)
	if !translated {
		return {}, .Failed, "the query did not translate"
	}

	// Result forms other than SELECT, and FROM/FROM NAMED dataset
	// construction, arrive with later tasks. They are refused by name
	// rather than attempted.
	if p.query.form != .Select {
		return {}, .Unsupported, "result form other than SELECT"
	}
	if len(p.query.datasets) > 0 {
		return {}, .Unsupported, "FROM / FROM NAMED"
	}

	switch backend {
	case .Memstore:
		return evaluate_memstore(suite, e, algebra)
	case .Kvstore:
		return evaluate_kvstore(suite, e, algebra)
	}
	return {}, .Failed, "unknown backend"
}

// query_is_ordered reports whether an entry's query asks for an order,
// which decides whether its answer is compared as a sequence or as a
// multiset. It re-parses rather than threading the query out of
// evaluate_entry, because a parser owns its algebra and outliving it is
// the kind of borrow that goes wrong quietly.
query_is_ordered :: proc(suite: Suite, e: Entry) -> bool {
	query_path, _ := filepath.join({SUITE_ROOT, suite.dir, e.action})
	defer delete(query_path)
	source, read_err := os.read_entire_file(query_path, context.allocator)
	if read_err != nil {
		return false
	}
	defer delete(source)
	base := strings.concatenate({suite.base, e.action})
	defer delete(base)

	p: sparql.Parser
	sparql.parser_init(&p, source, base)
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !parsed {
		return false
	}
	return len(p.query.order) > 0
}

@(private = "file")
evaluate_memstore :: proc(
	suite: Suite,
	e: Entry,
	algebra: sparql.Algebra,
) -> (
	rs: Result_Set,
	status: Eval_Status,
	detail: string,
) {
	td: Test_Dataset
	test_dataset_init(&td)
	defer test_dataset_destroy(&td)
	if loaded, why := load_entry_dataset(&td, suite, e); !loaded {
		return {}, .Failed, why
	}

	q: sparql_mem.Query
	defer sparql_mem.query_destroy(&q)
	if !sparql_mem.query_init(&q, algebra, &td.dictionary, &td.dataset) {
		return {}, .Unsupported, q.unsupported
	}

	rs.kind = .Bindings
	names := sparql_mem.query_var_names(&q)
	internal := sparql_mem.query_var_internal(&q)
	for {
		row, more := sparql_mem.query_next(&q)
		if !more {
			break
		}
		at := result_set_add_row(&rs)
		for id, slot in row {
			if id == store.UNBOUND || internal[slot] {
				continue
			}
			result_set_bind(&rs, at, names[slot], sparql_mem.query_term(&q, id))
		}
	}
	return rs, .Ok, ""
}

@(private = "file")
evaluate_kvstore :: proc(
	suite: Suite,
	e: Entry,
	algebra: sparql.Algebra,
) -> (
	rs: Result_Set,
	status: Eval_Status,
	detail: string,
) {
	path := kv_scratch_path(suite, e)
	defer delete(path)
	remove_store(path)

	s, open_err := kvstore.open(path)
	if open_err != nil {
		return {}, .Failed, "cannot open the kvstore"
	}
	defer {
		kvstore.close(s)
		remove_store(path)
	}
	if loaded, why := load_entry_into_kvstore(s, suite, e); !loaded {
		return {}, .Failed, why
	}

	q: sparql_kv.Query
	defer sparql_kv.query_destroy(&q)
	if !sparql_kv.query_init(&q, algebra, s) {
		if q.unsupported != "" {
			return {}, .Unsupported, q.unsupported
		}
		return {}, .Failed, "the store failed while resolving the query's terms"
	}

	rs.kind = .Bindings
	names := sparql_kv.query_var_names(&q)
	internal := sparql_kv.query_var_internal(&q)
	for {
		row, more := sparql_kv.query_next(&q)
		if !more {
			break
		}
		at := result_set_add_row(&rs)
		for id, slot in row {
			if id == store.UNBOUND || internal[slot] {
				continue
			}
			result_set_bind(&rs, at, names[slot], sparql_kv.query_term(&q, id))
		}
	}
	if sparql_kv.query_error(&q) != nil {
		result_set_destroy(&rs)
		return {}, .Failed, "the store failed during evaluation"
	}
	return rs, .Ok, ""
}

// load_entry_into_kvstore mirrors load_entry_dataset (dataset.odin) for
// the persistent backend: qt:data into the default graph, qt:graphData
// into a named graph whose name is the document's absolute IRI.
@(private = "file")
load_entry_into_kvstore :: proc(s: ^kvstore.Store, suite: Suite, e: Entry) -> (ok: bool, reason: string) {
	for name in e.data {
		if loaded, why := load_kv_document(s, suite, name, nil); !loaded {
			return false, why
		}
	}
	for name in e.graph_data {
		graph_iri := strings.concatenate({suite.base, name})
		defer delete(graph_iri)
		if loaded, why := load_kv_document(s, suite, name, rdf.IRI(graph_iri)); !loaded {
			return false, why
		}
	}
	return true, ""
}

@(private = "file")
load_kv_document :: proc(
	s: ^kvstore.Store,
	suite: Suite,
	name: string,
	graph: rdf.Graph_Label,
) -> (
	ok: bool,
	reason: string,
) {
	path, _ := filepath.join({SUITE_ROOT, suite.dir, name})
	defer delete(path)
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return false, "cannot read data document"
	}
	defer delete(content)

	base := strings.concatenate({suite.base, name})
	defer delete(base)

	parse_err: store.Load_Error
	err: kvstore.Error
	switch {
	case strings.has_suffix(name, ".ttl"):
		_, parse_err, err = kvstore.load_turtle(s, content, base, graph)
	case strings.has_suffix(name, ".nt"):
		_, parse_err, err = kvstore.load_triples(s, content, graph)
	case strings.has_suffix(name, ".rdf"):
		return false, "data document is RDF/XML, which the family's parser does not implement"
	case:
		return false, "data document is in an unrecognized format"
	}
	if err != nil {
		return false, "the store rejected the data document"
	}
	if parse_err.message != "" {
		return false, parse_err.message
	}
	return true, ""
}

// Each evaluated entry gets a fresh database directory: a persistent
// store carries state between opens by design, and a test that inherited
// the previous test's quads would pass or fail for reasons that have
// nothing to do with it.
@(private = "file")
kv_scratch_path :: proc(suite: Suite, e: Entry) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp/"
	}
	if !strings.has_suffix(tmp, "/") {
		tmp = strings.concatenate({tmp, "/"}, context.temp_allocator)
	}
	return fmt.aprintf("%sodin-sparql-eval-%d-%s-%s", tmp, os.get_pid(), suite.dir, e.id)
}

@(private = "file")
remove_store :: proc(path: string) {
	data := fmt.tprintf("%s/data.mdb", path)
	lock := fmt.tprintf("%s/lock.mdb", path)
	os.remove(data)
	os.remove(lock)
	os.remove(path)
}
