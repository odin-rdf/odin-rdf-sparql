// A bridge test for the length of the port (SPARQL-T-0031), in the same
// spirit as `tests/smoke` and with the same expiry: **delete this
// package at SPARQL-T-0033**, when the W3C harness comes back and makes
// it redundant several hundred times over.
//
// It exists because SPARQL-T-0031 leaves this repository with no
// executing coverage of the engine at all. `tests/guards`, `tests/readme`
// and `tests/w3c/harness` all name the deleted instantiation package and
// are ported in the two tasks after this one, and `sparql`'s own tests
// cover the parser and the algebra and never open a store. `make check`
// proves the port compiles; nothing proved it *ran*, over two tasks.
//
// So: one query of each shape the executor has an operator for, against a
// tiny document, under the leak checker. It asserts almost nothing about
// the answers — the suites do that — and asserts two things the suites
// would only tell you about much later:
//
//   - every operator path executes without crashing, including the
//     triple-term path, where `unify_shape` now reads record's
//     `snapshot_triple_parts` instead of materializing a term; and
//   - **the ownership rework does not leak or double-free.** That is the
//     real reason it is here. `record.snapshot_term` borrows for most
//     kinds and owns for two (RECORD-A-0008), against a kvstore loader
//     that always owned, so every materialization site in the engine
//     changed: the expression scratch, its inline buffers, and the
//     prepared query's materialized-term table. Every column of every
//     solution is materialized below for exactly that reason.
//
package portcheck

import "core:testing"

import "rdf:rdf"
import "record:record"
import "record:record/ingest"

import sparql "../../sparql"

DOC :: `PREFIX : <http://example/>
:alice :knows :bob ; :name "Alice" ; :age 30 .
:bob   :knows :carol ; :name "Bob" ; :age 41 .
:carol :name "Carol"@EN ; :age 7 .
:carol :note "long-enough-to-not-inline-at-all" .
:survey :states <<( :alice :knows :bob )>> .
:census :states <<( :bob :age 41 )>> .
`

NAMED :: `PREFIX : <http://example/>
:g1 { :alice :likes :tea . :bob :likes :coffee . }
`

QUERIES := []string {
	`PREFIX : <http://example/> SELECT ?s ?o WHERE { ?s :knows ?o }`,
	`PREFIX : <http://example/> SELECT ?n WHERE { ?s :name ?n } ORDER BY ?n`,
	`PREFIX : <http://example/> SELECT ?s (SUM(?a) AS ?t) WHERE { ?s :age ?a } GROUP BY ?s`,
	`PREFIX : <http://example/> SELECT ?s WHERE { ?s :age ?a FILTER(?a > 20 && CONTAINS(STR(?s), "b")) }`,
	`PREFIX : <http://example/> SELECT ?x WHERE { ?x :knows+ ?y }`,
	`PREFIX : <http://example/> SELECT ?s WHERE { ?s :age ?a FILTER EXISTS { ?s :knows ?z } }`,
	`PREFIX : <http://example/> SELECT ?s ?c WHERE { ?s :age ?a BIND(?a + 1 AS ?c) }`,
	`PREFIX : <http://example/> SELECT ?s ?n WHERE { ?s :age ?a OPTIONAL { ?s :note ?n } }`,
	`PREFIX : <http://example/> CONSTRUCT { ?s :knew ?o } WHERE { ?s :knows ?o }`,
	`PREFIX : <http://example/> DESCRIBE :alice`,
	`PREFIX : <http://example/> SELECT ?s WHERE { GRAPH ?g { ?s ?p ?o } }`,
	`PREFIX : <http://example/> ASK { :alice :knows :bob }`,
	// The triple-term path: a non-ground shape, so unify_shape takes the
	// matched term apart through exec_triple_parts. SPARQL-T-0035 owns
	// the suite; this is here so the port does not ship it crashing.
	`PREFIX : <http://example/> SELECT ?w ?s ?p ?o WHERE { ?w :states <<( ?s ?p ?o )>> }`,
}

@(test)
run_every_query :: proc(t: ^testing.T) {
	fs: record.Mem_FS
	defer record.mem_fs_destroy(&fs)
	s: record.Store
	_, open_err, _, _ := record.store_open(&s, "pc", record.mem_file_ops(&fs))
	testing.expect_value(t, open_err, record.Open_Error.None)
	defer record.store_close(&s)

	ops, ing := ingest.turtle(transmute([]byte)string(DOC), nil, context.allocator, blank_prefix = "pc_")
	testing.expect_value(t, ing.kind, ingest.Error_Kind.None)
	defer ingest.ops_destroy(ops, context.allocator)
	_, _, ae := record.apply(&s, {ops = ops})
	testing.expect_value(t, ae, record.Apply_Error{})

	gops, ging := ingest.trig(transmute([]byte)string(NAMED), context.allocator, blank_prefix = "pcg_")
	testing.expect_value(t, ging.kind, ingest.Error_Kind.None)
	defer ingest.ops_destroy(gops, context.allocator)
	_, _, gae := record.apply(&s, {ops = gops})
	testing.expect_value(t, gae, record.Apply_Error{})

	for text, i in QUERIES {
		snap, serr := record.store_latest(&s)
		testing.expect_value(t, serr, record.Snapshot_Error.None)

		p: sparql.Parser
		sparql.parser_init(&p, transmute([]byte)text)
		parsed, pok := sparql.parse(&p)
		testing.expectf(t, pok, "query %d did not parse", i)
		algebra, tok := sparql.translate(&p)
		testing.expectf(t, tok, "query %d did not translate", i)

		q: sparql.Query
		ok := sparql.query_init(&q, algebra, snap, sparql.parser_base(&p))
		testing.expectf(t, ok, "query %d unsupported: %s", i, q.unsupported)

		if ok {
			switch parsed.form {
			case .Construct:
				tpl: sparql.Template
				sparql.template_build(&tpl, parsed.template, sparql.query_slots(&q))
				g := sparql.query_construct(&q, &tpl)
				testing.expect(t, len(g.triples) > 0)
				sparql.result_graph_destroy(&g)
				sparql.template_destroy(&tpl)
			case .Describe:
				d: sparql.Describe_Targets
				sparql.describe_build(&d, parsed, sparql.query_slots(&q), snap)
				g := sparql.query_describe(&q, &d)
				testing.expect(t, len(g.triples) > 0)
				sparql.result_graph_destroy(&g)
				sparql.describe_destroy(&d)
			case .Select, .Ask:
				n := 0
				for {
					row, more := sparql.query_next(&q)
					if !more {
						break
					}
					// Materialize every column, which is the path that
					// exercises snapshot_term's owning kinds.
					for id in row {
						if id != 0 {
							term := sparql.query_term(&q, id)
							_ = term
						}
					}
					n += 1
				}
				testing.expectf(t, n > 0, "query %d had no solutions", i)
			}
		}
		sparql.query_destroy(&q)
		sparql.parser_destroy(&p)
		record.snapshot_release(&snap)
	}
	_ = rdf.IRI("")
}
