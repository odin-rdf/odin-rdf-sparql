package sparql_memstore

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

import "core:slice"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import store "store:store"
import memstore "store:store/memstore"

import sparql ".."

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
// the store it came from are gone. memstore's materialized terms borrow
// the dictionary, so a graph that had not copied them would be reading
// freed memory here.
@(test)
test_construct_graph_outlives_its_store :: proc(t: ^testing.T) {
	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	_, load_err := memstore.load_turtle(&d, &ds, transmute([]byte)string(DATA), "http://example/")
	if !testing.expectf(t, load_err.message == "", "fixture did not load: %s", load_err.message) {
		return
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(`PREFIX : <http://example/>
	     CONSTRUCT { ?s :copied ?o } WHERE { ?s :q ?o }`), "http://example/")
	_, parsed := sparql.parse(&p)
	testing.expect(t, parsed, "the query should parse")
	algebra, _ := sparql.translate(&p)

	q: Query
	prepared := query_init(&q, algebra, &d, &ds)
	testing.expectf(t, prepared, "the query should be supported: %s", q.unsupported)
	template: sparql.Template
	testing.expect(t, sparql.template_build(&template, p.query.template, query_slots(&q)), "the template should compile")
	graph := query_construct(&q, &template)

	// Everything the graph could have borrowed from, gone.
	sparql.template_destroy(&template)
	query_destroy(&q)
	sparql.parser_destroy(&p)
	memstore.dataset_destroy(&ds)
	memstore.dictionary_destroy(&d)

	lines := graph_lines(&graph)
	sparql.result_graph_destroy(&graph)
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
	return run_form(t, source, query, loc)
}

@(private = "file")
described :: proc(t: ^testing.T, source, query: string, loc := #caller_location) -> ([dynamic]string, bool) {
	lines, _, ok := run_form(t, source, query, loc)
	return lines, ok
}

// run_form evaluates a CONSTRUCT or a DESCRIBE and renders its graph.
@(private = "file")
run_form :: proc(
	t: ^testing.T,
	source, query: string,
	loc := #caller_location,
) -> (
	lines: [dynamic]string,
	blanks: int,
	ok: bool,
) {
	d: memstore.Dictionary
	memstore.dictionary_init(&d)
	defer memstore.dictionary_destroy(&d)
	ds: memstore.Dataset
	memstore.dataset_init(&ds)
	defer memstore.dataset_destroy(&ds)
	_, load_err := memstore.load_turtle(&d, &ds, transmute([]byte)source, "http://example/")
	if !testing.expectf(t, load_err.message == "", "fixture did not load: %s", load_err.message, loc = loc) {
		return nil, 0, false
	}

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)query, "http://example/")
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return nil, 0, false
	}
	algebra, translated := sparql.translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return nil, 0, false
	}

	q: Query
	if !query_init(&q, algebra, &d, &ds, sparql.parser_base(&p)) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		query_destroy(&q)
		return nil, 0, false
	}
	defer query_destroy(&q)

	graph: sparql.Result_Graph
	#partial switch p.query.form {
	case .Construct:
		template: sparql.Template
		defer sparql.template_destroy(&template)
		if !testing.expect(t, sparql.template_build(&template, p.query.template, query_slots(&q)), "template", loc = loc) {
			return nil, 0, false
		}
		graph = query_construct(&q, &template)
	case .Describe:
		targets: sparql.Describe_Targets
		defer sparql.describe_destroy(&targets)
		sparql.describe_build(&targets, p.query, query_slots(&q), find_for_test, &q)
		graph = query_describe(&q, &targets)
	case:
		testing.expectf(t, false, "not a graph-answering query form", loc = loc)
		return nil, 0, false
	}
	defer sparql.result_graph_destroy(&graph)

	return graph_lines(&graph), count_blanks(&graph), true
}

@(private = "file")
find_for_test :: proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool) {
	return query_find(cast(^Query)data, term)
}

// graph_lines renders a graph as sorted text so an assertion never
// depends on the order the store yielded quads in.
@(private = "file")
graph_lines :: proc(g: ^sparql.Result_Graph) -> [dynamic]string {
	out := make([dynamic]string)
	for triple in sparql.result_graph_triples(g) {
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
count_blanks :: proc(g: ^sparql.Result_Graph) -> int {
	seen := make(map[string]bool, context.temp_allocator)
	for triple in sparql.result_graph_triples(g) {
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
