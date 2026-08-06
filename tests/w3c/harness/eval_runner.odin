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

	// A query may name its own dataset. FROM documents merge into the
	// dataset's default graph and FROM NAMED documents become named
	// graphs — and once they are loaded that way, the engine needs to
	// know nothing about dataset clauses: the store's default graph *is*
	// the query's default graph, and the only named graphs present are
	// the ones the query asked for. A query with FROM NAMED and no FROM
	// therefore has an empty default graph, exactly as the spec says.
	declared := make([dynamic]Dataset_Document)
	defer {
		for d in declared {
			delete(d.name)
		}
		delete(declared)
	}
	for clause in p.query.datasets {
		name := strings.trim_prefix(string(clause.iri), suite.base)
		append(&declared, Dataset_Document{name = strings.clone(name), named = clause.named})
	}

	rs, status, detail = evaluate_algebra(suite, e, algebra, p.query, sparql.parser_base(&p), declared[:], backend)
	if status != .Ok || p.query.form != .Ask {
		return rs, status, detail
	}
	// An ASK answer is the existence of a solution, not the solutions.
	// It reads the bindings the evaluator produced rather than asking the
	// engine anything else — ASK is a SELECT nobody looks at.
	answered := len(rs.rows) > 0
	result_set_destroy(&rs)
	return Result_Set{kind = .Boolean, boolean = answered}, .Ok, ""
}

// Dataset_Document is one FROM or FROM NAMED document, resolved to the
// file name it lives under in the vendored suite.
Dataset_Document :: struct {
	name:  string,
	named: bool,
}

@(private = "file")
evaluate_algebra :: proc(
	suite: Suite,
	e: Entry,
	algebra: sparql.Algebra,
	query: ^sparql.Query,
	base: string,
	declared: []Dataset_Document,
	backend: Backend,
) -> (
	rs: Result_Set,
	status: Eval_Status,
	detail: string,
) {
	switch backend {
	case .Memstore:
		return evaluate_memstore(suite, e, algebra, query, base, declared)
	case .Kvstore:
		return evaluate_kvstore(suite, e, algebra, query, base, declared)
	}
	return {}, .Failed, "unknown backend"
}

// graph_result turns a constructed or described graph into the harness's
// result type. It copies again — the graph owns its terms against the
// store, the Result_Set owns its terms against the graph — which is what
// lets both be freed in the order their scopes end.
@(private = "file")
graph_result :: proc(graph: ^sparql.Result_Graph) -> Result_Set {
	rs: Result_Set
	rs.kind = .Graph
	for t in sparql.result_graph_triples(graph) {
		result_set_add_triple(&rs, t)
	}
	return rs
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
	query: ^sparql.Query,
	base: string,
	declared: []Dataset_Document,
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
	for document in declared {
		graph: rdf.Graph_Label
		graph_iri: string
		if document.named {
			graph_iri = strings.concatenate({suite.base, document.name})
			graph = rdf.IRI(graph_iri)
		}
		loaded, why := load_declared_document(&td, suite, document.name, graph)
		delete(graph_iri)
		if !loaded {
			return {}, .Failed, why
		}
	}

	q: sparql_mem.Query
	defer sparql_mem.query_destroy(&q)
	if !sparql_mem.query_init(&q, algebra, &td.dictionary, &td.dataset, base) {
		return {}, .Unsupported, q.unsupported
	}

	#partial switch query.form {
	case .Construct:
		template: sparql.Template
		defer sparql.template_destroy(&template)
		if !sparql.template_build(&template, query.template, sparql_mem.query_slots(&q)) {
			return {}, .Unsupported, "CONSTRUCT template"
		}
		graph := sparql_mem.query_construct(&q, &template)
		defer sparql.result_graph_destroy(&graph)
		return graph_result(&graph), .Ok, ""
	case .Describe:
		targets: sparql.Describe_Targets
		defer sparql.describe_destroy(&targets)
		sparql.describe_build(&targets, query, sparql_mem.query_slots(&q), find_memstore, &q)
		graph := sparql_mem.query_describe(&q, &targets)
		defer sparql.result_graph_destroy(&graph)
		return graph_result(&graph), .Ok, ""
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
	query: ^sparql.Query,
	base: string,
	declared: []Dataset_Document,
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
	for document in declared {
		graph: rdf.Graph_Label
		graph_iri: string
		if document.named {
			graph_iri = strings.concatenate({suite.base, document.name})
			graph = rdf.IRI(graph_iri)
		}
		loaded, why := load_kv_document(s, suite, document.name, graph)
		delete(graph_iri)
		if !loaded {
			return {}, .Failed, why
		}
	}

	q: sparql_kv.Query
	defer sparql_kv.query_destroy(&q)
	if !sparql_kv.query_init(&q, algebra, s, base) {
		if q.unsupported != "" {
			return {}, .Unsupported, q.unsupported
		}
		return {}, .Failed, "the store failed while resolving the query's terms"
	}

	#partial switch query.form {
	case .Construct:
		template: sparql.Template
		defer sparql.template_destroy(&template)
		if !sparql.template_build(&template, query.template, sparql_kv.query_slots(&q)) {
			return {}, .Unsupported, "CONSTRUCT template"
		}
		graph := sparql_kv.query_construct(&q, &template)
		defer sparql.result_graph_destroy(&graph)
		if sparql_kv.query_error(&q) != nil {
			return {}, .Failed, "the store failed during evaluation"
		}
		return graph_result(&graph), .Ok, ""
	case .Describe:
		targets: sparql.Describe_Targets
		defer sparql.describe_destroy(&targets)
		sparql.describe_build(&targets, query, sparql_kv.query_slots(&q), find_kvstore, &q)
		graph := sparql_kv.query_describe(&q, &targets)
		defer sparql.result_graph_destroy(&graph)
		if sparql_kv.query_error(&q) != nil {
			return {}, .Failed, "the store failed during evaluation"
		}
		return graph_result(&graph), .Ok, ""
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

// A DESCRIBE clause names IRIs, and resolving one to a store ID is the
// same non-interning lookup plan building uses. The two adapters are what
// carry it across the backend boundary this file dispatches on.
@(private = "file")
find_memstore :: proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	return sparql_mem.query_find(cast(^sparql_mem.Query)data, term)
}

@(private = "file")
find_kvstore :: proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	return sparql_kv.query_find(cast(^sparql_kv.Query)data, term)
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
	case strings.has_suffix(name, ".trig"):
		// See load_document (dataset.odin): a quad document names its
		// own graphs.
		_, parse_err, err = kvstore.load_trig(s, content, base)
	case strings.has_suffix(name, ".nq"):
		_, parse_err, err = kvstore.load_quads(s, content)
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
// Windows names the temp directory TEMP or TMP and has no /tmp to fall
// back to, so consulting TMPDIR alone leaves the path at a directory that
// cannot be created there.
@(private = "file")
kv_scratch_path :: proc(suite: Suite, e: Entry) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = os.get_env("TEMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = os.get_env("TMP", context.temp_allocator)
	}
	if tmp == "" {
		tmp = "/tmp"
	}
	tmp = strings.trim_right(tmp, `/\`)
	return fmt.aprintf("%s/odin-sparql-eval-%d-%s-%s", tmp, os.get_pid(), suite.dir, e.id)
}

@(private = "file")
remove_store :: proc(path: string) {
	data := fmt.tprintf("%s/data.mdb", path)
	lock := fmt.tprintf("%s/lock.mdb", path)
	os.remove(data)
	os.remove(lock)
	os.remove(path)
}
