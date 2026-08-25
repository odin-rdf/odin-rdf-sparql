// Running a W3C evaluation test end to end: load the entry's data,
// parse and translate its query, evaluate it, and turn the answer into
// the Result_Set that comparison understands.
//
// **The `Backend` enum and its dispatch are gone** (SPARQL-T-0033).
// There was one arm and it was kept anyway, as "the seam a second
// backend would use" — the same reason odin-rdf-store retained its
// conformance Backend adapter when it became a single-backend library.
// odin-rdf-record is the one and only store from here on (owner,
// 2026-08-24), which retires that reason: the enum, `backend_name`, the
// dispatch, and the `_kvstore` suffix on 37 test procedures all go, and
// this file's own loading path merges into `dataset.odin`'s.
package w3c

import "core:os"
import "core:path/filepath"
import "core:strings"

import rdf "rdf:rdf"

import "../../../sparql"

// Eval_Status separates the three outcomes a test run can have. They
// must stay separate: an operator the engine has not implemented is not
// a wrong answer, and neither is a store failure — collapsing either
// into "no solutions" would make an unfinished engine look correct.
Eval_Status :: enum {
	Ok,
	Unsupported, // the engine does not implement something the query uses
	Failed, // the data would not load, or the query would not parse
}

// evaluate_entry runs one manifest entry. detail is a static description
// when status is not Ok. The caller owns the result and frees it with
// result_set_destroy.
evaluate_entry :: proc(
	suite: Suite,
	e: Entry,
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

	rs, status, detail = evaluate_algebra(suite, e, algebra, p.query, sparql.parser_base(&p), declared[:])
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

// evaluate_algebra loads the entry's dataset and runs the query against
// it. The store is opened per entry and dies with it — the memory seam
// makes that cheap, and it is what keeps entries independent on a
// multi-threaded runner.
@(private = "file")
evaluate_algebra :: proc(
	suite: Suite,
	e: Entry,
	algebra: sparql.Algebra,
	query: ^sparql.Parsed_Query,
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

	// Every document is in; the dataset the query answers about is what
	// the store holds now.
	snap, pinned := test_dataset_snapshot(&td)
	if !pinned {
		return {}, .Failed, "cannot pin a snapshot of the entry's dataset"
	}

	q: sparql.Query
	defer sparql.query_destroy(&q)
	if !sparql.query_init(&q, algebra, snap, base) {
		// The only way preparation fails. Resolving the query's ground
		// terms cannot: a term the store has never seen is an ordinary
		// answer, not an error.
		return {}, .Unsupported, q.unsupported
	}

	#partial switch query.form {
	case .Construct:
		template: sparql.Template
		defer sparql.template_destroy(&template)
		if !sparql.template_build(&template, query.template, sparql.query_slots(&q)) {
			return {}, .Unsupported, "CONSTRUCT template"
		}
		graph := sparql.query_construct(&q, &template)
		defer sparql.result_graph_destroy(&graph)
		return graph_result(&graph), .Ok, ""
	case .Describe:
		targets: sparql.Describe_Targets
		defer sparql.describe_destroy(&targets)
		sparql.describe_build(&targets, query, sparql.query_slots(&q), snap)
		graph := sparql.query_describe(&q, &targets)
		defer sparql.result_graph_destroy(&graph)
		return graph_result(&graph), .Ok, ""
	}

	rs.kind = .Bindings
	names := sparql.query_var_names(&q)
	internal := sparql.query_var_internal(&q)
	for {
		row, more := sparql.query_next(&q)
		if !more {
			break
		}
		at := result_set_add_row(&rs)
		for id, slot in row {
			if id == sparql.UNBOUND || internal[slot] {
				continue
			}
			result_set_bind(&rs, at, names[slot], sparql.query_term(&q, id))
		}
	}
	return rs, .Ok, ""
}
