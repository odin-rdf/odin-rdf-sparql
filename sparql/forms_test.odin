package sparql

// The graph-answering result forms (SPARQL-T-0017): CONSTRUCT's template
// instantiation and DESCRIBE.
//
// CONSTRUCT has a suite and DESCRIBE has none — §16.4 leaves the shape of
// a description to the implementation, so the W3C suites pin nothing
// about it. That asymmetry is the reason this file exists: DESCRIBE's
// behaviour is only ever what these cases say it is, and the CONSTRUCT
// cases state the §16.2 rules one at a time rather than leaving them to
// be inferred from ten suite entries passing.
//
// Graphs are compared as sorted text with blank nodes shown by label, and
// blank-node *identity* is asserted by counting distinct labels rather
// than by naming them: which label a solution's fresh node gets is this
// engine's business, but how many distinct ones there are is §16.2's.
//
// *(Moved into this package by SPARQL-T-0032, from `sparql/kvstore`.
// `describe_build`'s `Term_Finder` argument became the snapshot itself —
// the seam it reached through is gone — and the store became a `Test_DB`
// over record's memory seam; not one assertion changed.)*

import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"

@(private = "file")
DATA :: `@prefix : <http://example/> .
:x :p :a .
:x :p :b .
:a :q "2" .
:b :q "2" .
:c :r "loose" .
`

// §16.2's first rule: the template is instantiated once per solution, and
// the result is a *graph* — so two solutions that instantiate the same
// triple contribute it once.
@(test)
test_construct_is_a_set :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { :x :p2 ?v } WHERE { ?x :p ?o . ?o :q ?v }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	// Two solutions, one triple.
	expect_lines(t, lines, {`<http://example/x> <http://example/p2> "2"^^xsd:string`})
}

// A template position whose variable the solution leaves unbound produces
// no triple — and that is not an error, so the other solutions still
// answer. This is the DAWG's construct-optional in miniature.
@(test)
test_construct_drops_unbound_positions :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { ?o :seen ?v } WHERE { ?x :p ?o OPTIONAL { ?o :missing ?v } }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(t, lines, {})
}

// A template variable the *pattern* never binds is unbound in every
// solution, so it produces nothing — and the triples beside it still do.
@(test)
test_construct_ignores_a_variable_the_pattern_never_binds :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { ?o :seen ?nowhere . ?o :kind :thing } WHERE { :x :p ?o }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/kind> <http://example/thing>`,
			`<http://example/b> <http://example/kind> <http://example/thing>`,
		},
	)
}

// §16.2's blank-node rule, the one the section spends most of its length
// on: a label in the template names a *different* node in every solution.
// Two solutions therefore give two triples, not one deduplicated one —
// which is what makes this the case that catches a template blank node
// treated as a constant.
@(test)
test_construct_blank_nodes_are_fresh_per_solution :: proc(t: ^testing.T) {
	lines, blanks, ok := constructed_with_blanks(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { _:r :about ?o } WHERE { :x :p ?o }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	testing.expectf(t, len(lines) == 2, "expected two triples, got %v", lines)
	testing.expectf(t, blanks == 2, "expected two distinct blank nodes, got %d", blanks)
}

// Two template blank nodes in one solution are two nodes, and a label
// used twice in one solution is one node. Both halves matter: the first
// is what makes a reification template work, the second is what makes a
// collection template — `(?s ?o)`, whose cells link to each other —
// come out as a list rather than as loose cells.
@(test)
test_construct_blank_nodes_are_shared_within_a_solution :: proc(t: ^testing.T) {
	lines, blanks, ok := constructed_with_blanks(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { _:head :next _:tail . _:tail :value ?o } WHERE { :x :p :a . BIND(:a AS ?o) }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	testing.expectf(t, len(lines) == 2, "expected two triples, got %v", lines)
	testing.expectf(t, blanks == 2, "expected two distinct blank nodes, got %d", blanks)
	// The tail of the first triple must be the subject of the second, or
	// the two blank nodes are not the ones the template named.
	joined := strings.concatenate(lines[:])
	defer delete(joined)
	testing.expectf(t, strings.count(joined, "_:b0_1") == 2, "the shared label named two nodes: %v", lines)
}

// A solution can bind a variable to a term that is not legal in the
// position the template puts it in — a literal as a subject, most often.
// §16.2 says such a triple "is not included"; it is not an error and it
// does not stop the rest of the template.
@(test)
test_construct_drops_triples_rdf_does_not_admit :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { ?v :from ?s . ?s :said ?v } WHERE { ?s :q ?v }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	// ?v is the literal "2": it cannot be a subject, so only the second
	// template triple survives — twice, once per solution.
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/said> "2"^^xsd:string`,
			`<http://example/b> <http://example/said> "2"^^xsd:string`,
		},
	)
}

// The ownership contract, asserted rather than described: a constructed
// graph owns every term in it, so it stays readable after the query and
// the store it came from are gone.
//
// **On record this is sharper than it was on kvstore, not softer.**
// kvstore built each term out of mapped pages, and closing the store
// unmapped them, so a graph that had not copied would read unmapped
// memory. record's `snapshot_term` *borrows the dictionary arena* for
// most kinds — the terms below are IRIs and a plain literal, all
// borrowing — and `store_close` frees that arena. The failure this
// catches is therefore a use-after-free rather than a page fault, which
// the leak checker sees and a segfault would not have been. The store is
// closed here **before the graph is read**, which is the whole assertion.
@(test)
test_construct_graph_outlives_its_store :: proc(t: ^testing.T) {
	d: Test_DB
	// Deliberately not deferred past the read: test_db_close is called
	// by hand below, before the graph is looked at.
	if !test_db_open(t, &d, "outlives") {
		return
	}
	if !test_db_load(t, &d, DATA) {
		test_db_close(&d)
		return
	}
	snap, pinned := test_db_snap(t, &d)
	if !pinned {
		test_db_close(&d)
		return
	}

	p: Parser
	parser_init(&p, transmute([]byte)string(`PREFIX : <http://example/>
	     CONSTRUCT { ?s :copied ?o } WHERE { ?s :q ?o }`), TEST_BASE)
	_, parsed := parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := translate(&p)

	q: Query
	prepared := query_init(&q, algebra, snap)
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)
	template: Template
	testing.expect(t, template_build(&template, p.query.template, query_slots(&q)), "the template should compile")
	graph := query_construct(&q, &template)

	// Everything the graph could have borrowed from, gone.
	template_destroy(&template)
	query_destroy(&q)
	parser_destroy(&p)
	test_db_close(&d)

	lines := graph_lines(&graph)
	result_graph_destroy(&graph)
	defer destroy_lines(&lines)
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/copied> "2"^^xsd:string`,
			`<http://example/b> <http://example/copied> "2"^^xsd:string`,
		},
	)
}

// DESCRIBE, whose shape §16.4 leaves to the implementation and which this
// engine answers as: every triple of the default graph whose subject is a
// described resource. A DESCRIBE with no WHERE describes what it names,
// with no pattern to evaluate at all.
@(test)
test_describe_a_named_resource :: proc(t: ^testing.T) {
	lines, ok := described(t, DATA, `PREFIX : <http://example/> DESCRIBE :x`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/x> <http://example/p> <http://example/a>`,
			`<http://example/x> <http://example/p> <http://example/b>`,
		},
	)
}

// A described resource the data says nothing about contributes nothing,
// and so does one the store has never heard of. Neither is an error.
@(test)
test_describe_an_unknown_resource_is_empty :: proc(t: ^testing.T) {
	lines, ok := described(t, DATA, `PREFIX : <http://example/> DESCRIBE :nobody`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(t, lines, {})
}

// With a WHERE clause the described resources come from the solutions,
// and a resource two solutions name is described once — the answer is a
// graph.
@(test)
test_describe_from_a_pattern :: proc(t: ^testing.T) {
	lines, ok := described(t, DATA, `PREFIX : <http://example/> DESCRIBE ?o WHERE { :x :p ?o }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/q> "2"^^xsd:string`,
			`<http://example/b> <http://example/q> "2"^^xsd:string`,
		},
	)
}

// `DESCRIBE *` names every variable in scope, which is every variable the
// pattern binds.
@(test)
test_describe_star :: proc(t: ^testing.T) {
	lines, ok := described(t, DATA, `PREFIX : <http://example/> DESCRIBE * WHERE { ?s :q ?v }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	// ?s is :a and :b; ?v is the literal "2", which is no triple's
	// subject and so describes nothing.
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/q> "2"^^xsd:string`,
			`<http://example/b> <http://example/q> "2"^^xsd:string`,
		},
	)
}

// --- DESCRIBE and the graph set (SPARQL-T-0054) ---------------------
//
// The four cases above put every triple in the default graph, which is
// the one dataset shape for which DESCRIBE's old answer and its answer
// now coincide — the reason they are still written exactly as they were.
// The cases below are the shapes that told them apart.
//
// **A dataset that keeps every fact in a named graph described nothing
// at all.** `exec_describe` named `DEFAULT_GRAPH` in the graph position
// of its pattern, so a store provisioned one document per graph answered
// every DESCRIBE with an empty graph — indistinguishable from the honest
// empty answer `test_describe_an_unknown_resource_is_empty` asserts, and
// therefore the one wrong conclusion the form made available. The fix is
// a wildcard there and nothing else: `query_init`'s `scope` and `graphs`
// reach the read as record's `Filter` already, so the ceiling
// SPARQL-T-0044 established is what decides, here as at every join.

@(private = "file")
GA :: "http://example/ga"
@(private = "file")
GB :: "http://example/gb"

// Two named graphs, no default graph at all, and one triple asserted in
// both so that the answer's set-ness is visible.
@(private = "file")
NAMED_ONLY := []Form_Doc {
	{GA, `@prefix : <http://example/> . :x :in "ga" . :x :both "yes" .`},
	{GB, `@prefix : <http://example/> . :x :in "gb" . :x :both "yes" .`},
}

// The same two graphs with a default graph beside them, which is what
// makes "the default graph included" an assertion rather than a wish.
@(private = "file")
THREE_GRAPHS := []Form_Doc {
	{GA, `@prefix : <http://example/> . :x :in "ga" . :x :both "yes" .`},
	{GB, `@prefix : <http://example/> . :x :in "gb" . :x :both "yes" .`},
	{"", `@prefix : <http://example/> . :x :in "default" .`},
}

@(private = "file")
DESCRIBE_X :: `PREFIX : <http://example/> DESCRIBE :x`

// Unscoped, a DESCRIBE reads every graph. `:both` is asserted twice and
// answered once: the result is a graph, so the graph a triple came from
// is not in the answer and `result_graph_add` is what makes it a set.
@(test)
test_describe_reads_every_graph_when_unscoped :: proc(t: ^testing.T) {
	lines, ok := described_in(t, NAMED_ONLY, DESCRIBE_X, .All, nil)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/x> <http://example/both> "yes"^^xsd:string`,
			`<http://example/x> <http://example/in> "ga"^^xsd:string`,
			`<http://example/x> <http://example/in> "gb"^^xsd:string`,
		},
	)
}

// **The ceiling, which is the criterion to be careful about**: a scoped
// DESCRIBE answers from the set and from no graph outside it. `:gb` and
// the default graph both hold triples of `:x` and neither contributes
// one — a describe that read past the set would be a worse defect than
// the empty answer it replaced.
@(test)
test_describe_is_confined_to_the_graph_set :: proc(t: ^testing.T) {
	lines, ok := described_in(t, THREE_GRAPHS, DESCRIBE_X, .Set, {GA})
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/x> <http://example/both> "yes"^^xsd:string`,
			`<http://example/x> <http://example/in> "ga"^^xsd:string`,
		},
	)
}

// The default graph is in the set when the set says so, and is not a
// graph the form reads on its own account any more. `:ga` is outside
// this set and contributes nothing.
@(test)
test_describe_reads_the_default_graph_when_the_set_names_it :: proc(t: ^testing.T) {
	lines, ok := described_in(t, THREE_GRAPHS, DESCRIBE_X, .Set, {"", GB})
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/x> <http://example/both> "yes"^^xsd:string`,
			`<http://example/x> <http://example/in> "default"^^xsd:string`,
			`<http://example/x> <http://example/in> "gb"^^xsd:string`,
		},
	)
}

// An empty set admits nothing, so it describes nothing — the ceiling at
// its tightest, and the case that fails loudest if the wildcard ever
// escapes the filter. The clause's IRI still resolves: a term is not a
// fact, and `describe_build` resolves unscoped for the same reason plan
// building does.
@(test)
test_describe_under_an_empty_set_describes_nothing :: proc(t: ^testing.T) {
	lines, ok := described_in(t, THREE_GRAPHS, DESCRIBE_X, .Set, nil)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(t, lines, {})
}

// A SPARQL 1.2 triple term in a template is built per solution out of
// positions of its own, so a variable inside one is read from the
// solution exactly as a variable beside one is (SPARQL-T-0018).
@(test)
test_construct_builds_a_triple_term :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { ?o :states <<( ?o :q ?v )>> } WHERE { ?o :q ?v }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/states> ` +
			`<<( <http://example/a> <http://example/q> "2"^^xsd:string )>>`,
			`<http://example/b> <http://example/states> ` +
			`<<( <http://example/b> <http://example/q> "2"^^xsd:string )>>`,
		},
	)
}

// RDF 1.2 admits a triple term as an object and nowhere else, so a
// template that writes one as a subject produces nothing — the same
// silent drop §16.2 gives a literal subject, and the reason the
// suite's CONSTRUCT entries all use the *reified* form, whose reifier
// is a blank node.
@(test)
test_construct_drops_a_triple_term_subject :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { <<( ?o :q ?v )>> :source :ABC } WHERE { ?o :q ?v }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(t, lines, {})
}

// The §16.2 rule that drops a template triple applies inside a triple
// term too: a term whose component this solution leaves unbound is not
// built, and neither is the triple that would have held it — while the
// triples beside it still are.
@(test)
test_construct_drops_a_triple_term_with_an_unbound_component :: proc(t: ^testing.T) {
	lines, ok := constructed(t, DATA, `PREFIX : <http://example/>
	     CONSTRUCT { ?o :states <<( ?o :q ?missing )>> . ?o :kind :thing }
	     WHERE { ?x :p ?o }`)
	defer destroy_lines(&lines)
	if !ok {
		return
	}
	expect_lines(
		t,
		lines,
		{
			`<http://example/a> <http://example/kind> <http://example/thing>`,
			`<http://example/b> <http://example/kind> <http://example/thing>`,
		},
	)
}

// --- helpers --------------------------------------------------------

// Form_Doc is one document of a fixture and the graph it is loaded into,
// "" for the default graph. Each document is its own blank-node scope,
// which is `test_db_load`'s rule and not this file's.
@(private = "file")
Form_Doc :: struct {
	graph:  string,
	source: string,
}

@(private = "file")
constructed :: proc(t: ^testing.T, source, query: string, loc := #caller_location) -> ([dynamic]string, bool) {
	lines, _, ok := constructed_with_blanks(t, source, query, loc)
	return lines, ok
}

@(private = "file")
constructed_with_blanks :: proc(
	t: ^testing.T,
	source, query: string,
	loc := #caller_location,
) -> (
	lines: [dynamic]string,
	blanks: int,
	ok: bool,
) {
	return run_form(t, {{"", source}}, query, .All, nil, loc)
}

@(private = "file")
described :: proc(t: ^testing.T, source, query: string, loc := #caller_location) -> ([dynamic]string, bool) {
	lines, _, ok := run_form(t, {{"", source}}, query, .All, nil, loc)
	return lines, ok
}

// described_in is `described` over a fixture that names its graphs, under
// a stated scope. It is the shape SPARQL-T-0054's cases need and the one
// the default-graph cases above deliberately do not use.
@(private = "file")
described_in :: proc(
	t: ^testing.T,
	docs: []Form_Doc,
	query: string,
	scope: record.Graph_Scope,
	labels: []string,
	loc := #caller_location,
) -> (
	[dynamic]string,
	bool,
) {
	lines, _, ok := run_form(t, docs, query, scope, labels, loc)
	return lines, ok
}

// run_form evaluates a CONSTRUCT or a DESCRIBE and renders its graph,
// under the graph set the query is given (`.All` and nothing for the
// cases that predate SPARQL-T-0054, which is `query_init`'s default).
@(private = "file")
run_form :: proc(
	t: ^testing.T,
	docs: []Form_Doc,
	query: string,
	scope: record.Graph_Scope,
	labels: []string,
	loc := #caller_location,
) -> (
	lines: [dynamic]string,
	blanks: int,
	ok: bool,
) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "forms", loc = loc) {
		return nil, 0, false
	}
	for doc in docs {
		graph: rdf.Graph_Label
		if doc.graph != "" {
			graph = rdf.IRI(doc.graph)
		}
		if !test_db_load(t, &d, doc.source, graph, loc = loc) {
			return nil, 0, false
		}
	}
	snap, pinned := test_db_snap(t, &d, loc)
	if !pinned {
		return nil, 0, false
	}
	// The labels resolved against this snapshot, as SPARQL-T-0044's own
	// cases do it: "" is the default graph, and a label the store has
	// never seen is dropped rather than becoming 0, which in a set means
	// the default graph.
	ids := make([dynamic]record.Term_ID, context.temp_allocator)
	for label in labels {
		if label == "" {
			append(&ids, record.MATCH_DEFAULT_GRAPH)
			continue
		}
		if id, found := record.snapshot_resolve(snap, rdf.IRI(label)); found {
			append(&ids, id)
		}
	}

	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return nil, 0, false
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return nil, 0, false
	}

	q: Query
	if !query_init(&q, algebra, snap, parser_base(&p), scope, ids[:]) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		query_destroy(&q)
		return nil, 0, false
	}
	defer query_destroy(&q)

	graph: Result_Graph
	#partial switch p.query.form {
	case .Construct:
		template: Template
		defer template_destroy(&template)
		if !testing.expect(t, template_build(&template, p.query.template, query_slots(&q)), "template", loc = loc) {
			return nil, 0, false
		}
		graph = query_construct(&q, &template)
	case .Describe:
		targets: Describe_Targets
		defer describe_destroy(&targets)
		// The snapshot, where this passed a `Term_Finder` adapter over
		// `query_find` before: describe_build resolves the clause's IRIs
		// itself now that there is no backend to be generic over.
		describe_build(&targets, p.query, query_slots(&q), snap)
		graph = query_describe(&q, &targets)
	case:
		testing.expectf(t, false, "not a graph-answering query form", loc = loc)
		return nil, 0, false
	}
	defer result_graph_destroy(&graph)

	return graph_lines(&graph), count_blanks(&graph), true
}

// graph_lines renders a graph as sorted text so an assertion never
// depends on the order the store yielded quads in.
@(private = "file")
graph_lines :: proc(g: ^Result_Graph) -> [dynamic]string {
	out := make([dynamic]string)
	for triple in result_graph_triples(g) {
		b := strings.builder_make()
		write_form_term(&b, triple.subject)
		strings.write_byte(&b, ' ')
		write_form_term(&b, triple.predicate)
		strings.write_byte(&b, ' ')
		write_form_term(&b, triple.object)
		append(&out, strings.to_string(b))
	}
	slice.sort(out[:])
	return out
}

// count_blanks is how many distinct blank nodes a graph names. Which
// labels they are is the engine's business; how many there are is
// §16.2's.
@(private = "file")
count_blanks :: proc(g: ^Result_Graph) -> int {
	seen := make(map[string]bool, context.temp_allocator)
	for triple in result_graph_triples(g) {
		for term in ([3]rdf.Term{triple.subject, triple.predicate, triple.object}) {
			if label, is_blank := term.(rdf.Blank_Node); is_blank {
				seen[string(label)] = true
			}
		}
	}
	return len(seen)
}

@(private = "file")
write_form_term :: proc(b: ^strings.Builder, term: rdf.Term) {
	switch v in term {
	case rdf.IRI:
		strings.write_byte(b, '<')
		strings.write_string(b, string(v))
		strings.write_byte(b, '>')
	case rdf.Blank_Node:
		strings.write_string(b, "_:")
		strings.write_string(b, string(v))
	case rdf.Literal:
		strings.write_byte(b, '"')
		strings.write_string(b, v.lexical)
		strings.write_byte(b, '"')
		if v.language != "" {
			strings.write_byte(b, '@')
			strings.write_string(b, v.language)
			return
		}
		strings.write_string(b, "^^")
		XSD :: "http://www.w3.org/2001/XMLSchema#"
		if strings.has_prefix(string(v.datatype), XSD) {
			strings.write_string(b, "xsd:")
			strings.write_string(b, string(v.datatype)[len(XSD):])
			return
		}
		strings.write_byte(b, '<')
		strings.write_string(b, string(v.datatype))
		strings.write_byte(b, '>')
	case ^rdf.Triple:
		strings.write_string(b, "<<( ")
		write_form_term(b, v.subject)
		strings.write_byte(b, ' ')
		write_form_term(b, v.predicate)
		strings.write_byte(b, ' ')
		write_form_term(b, v.object)
		strings.write_string(b, " )>>")
	case nil:
		strings.write_string(b, "UNBOUND")
	}
}

@(private = "file")
expect_lines :: proc(t: ^testing.T, lines: [dynamic]string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(lines) == len(want), "got %d triples, want %d: %v", len(lines), len(want), lines, loc = loc) {
		return
	}
	for expected, i in want {
		testing.expectf(t, lines[i] == expected, "triple %d: got %q, want %q", i, lines[i], expected, loc = loc)
	}
}

@(private = "file")
destroy_lines :: proc(lines: ^[dynamic]string) {
	for line in lines {
		delete(line)
	}
	delete(lines^)
}
