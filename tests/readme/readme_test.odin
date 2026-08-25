// The README quick-start examples, compiled and asserted here so the
// documentation cannot drift from the real API (the family's
// README-as-contract pattern, SPARQL-T-0009 for the parser half,
// SPARQL-T-0019 for the evaluation half).
package readme

import "base:runtime"

import "core:fmt"
import "core:strings"
import "core:testing"

import "rdf:rdf"
import "record:record"
import "record:record/ingest"

import "../../sparql"

QUERY :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT ?name WHERE {
	?person a foaf:Person ; foaf:name ?name .
	FILTER(STRLEN(?name) > 0)
}
ORDER BY ?name LIMIT 10
`

@(test)
readme_quick_start :: proc(t: ^testing.T) {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(QUERY))
	defer sparql.parser_destroy(&p)

	query, ok := sparql.parse(&p)
	if !testing.expectf(
		t,
		ok,
		"parse error at line %d, column %d: %s",
		p.err.line,
		p.err.column,
		sparql.error_message(p.err.kind),
	) {
		return
	}
	testing.expect_value(t, query.form, sparql.Query_Form.Select)
	testing.expect_value(t, query.limit, 10)

	algebra, translate_ok := sparql.translate(&p)
	testing.expect(t, translate_ok)
	sse := sparql.algebra_to_string(algebra)
	defer delete(sse)

	// The README shows this operator stack (with IRIs elided there).
	testing.expect(t, strings.has_prefix(sse, "(slice _ 10\n  (project (?name)\n    (order (?name)\n      (filter (> (strlen ?name) 0)\n        (bgp"))
}

DATA :: `@prefix foaf: <http://xmlns.com/foaf/0.1/> .
<http://example/alice> a foaf:Person ; foaf:name "Alice" ; foaf:knows <http://example/bob> .
<http://example/bob>   a foaf:Person ; foaf:name "Bob" .
`

FRIENDS :: `
PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT ?name ?friend WHERE {
	?person a foaf:Person ; foaf:name ?name .
	OPTIONAL { ?person foaf:knows ?other . ?other foaf:name ?friend }
}
ORDER BY ?name
`

// The README opens the store with `record.posix_file_ops()` over a
// directory, which is what an application does. This substitutes
// `Mem_FS` + `mem_file_ops` — the same store with its log in memory —
// because a test should need no directory, no cleanup and no uniqueness,
// and because record has no Windows `File_Ops` and the CI matrix has a
// Windows runner. Those two lines are the only difference between this
// body and the README's, and the README says so.
@(test)
readme_evaluation :: proc(t: ^testing.T) {
	fs: record.Mem_FS
	defer record.mem_fs_destroy(&fs)

	db: record.Store
	_, open_err, load_err, write_err := record.store_open(&db, "readme", record.mem_file_ops(&fs))
	if !testing.expectf(
		t,
		open_err == .None && load_err == .None && write_err == .None,
		"cannot open the store: %v %v %v",
		open_err,
		load_err,
		write_err,
	) {
		return
	}
	defer record.store_close(&db)

	ops, ing_err := ingest.turtle(
		transmute([]byte)string(DATA),
		nil,
		context.allocator,
		blank_prefix = "people_",
		base = "http://example/",
	)
	if !testing.expectf(t, ing_err.kind == .None, "data did not parse: %v", ing_err.kind) {
		return
	}
	defer ingest.ops_destroy(ops, context.allocator)
	_, _, apply_err := record.apply(&db, {ops = ops})
	if !testing.expectf(t, apply_err == record.Apply_Error{}, "data did not load: %v", apply_err) {
		return
	}

	snap, snap_err := record.store_latest(&db)
	if !testing.expectf(t, snap_err == .None, "cannot pin a snapshot: %v", snap_err) {
		return
	}
	defer record.snapshot_release(&snap)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p) // the parser owns the algebra
	if _, parsed := sparql.parse(&p); !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, translated := sparql.translate(&p)
	if !testing.expect(t, translated, "the query should translate") {
		return
	}

	// A prepared query borrows the algebra and the snapshot, so both
	// outlive it. query_destroy releases neither.
	q: sparql.Query
	defer sparql.query_destroy(&q)
	if !sparql.query_init(&q, algebra, snap, sparql.parser_base(&p)) {
		testing.expectf(t, false, "unsupported: %s", q.unsupported)
		return
	}

	answer := strings.builder_make()
	defer strings.builder_destroy(&answer)
	names := sparql.query_var_names(&q)
	internal := sparql.query_var_internal(&q)
	for {
		// A row is Term_IDs indexed by variable slot, valid until the
		// next pull. Deep-copy it if you keep it.
		row, more := sparql.query_next(&q)
		if !more {
			break
		}
		for id, slot in row {
			if id == sparql.UNBOUND || internal[slot] {
				continue // unbound, or a pattern blank node
			}
			#partial switch term in sparql.query_term(&q, id) {
			case rdf.IRI:
				fmt.sbprintf(&answer, "?%s=<%s> ", names[slot], string(term))
			case rdf.Literal:
				fmt.sbprintf(&answer, "?%s=%q ", names[slot], term.lexical)
			}
		}
		strings.write_byte(&answer, '\n')
	}

	// The README shows this answer (as two `fmt.printf` lines).
	testing.expect_value(t, strings.to_string(answer), "?name=\"Alice\" ?friend=\"Bob\" \n?name=\"Bob\" \n")
}

// The README's third example: a query over a validator's *candidate* —
// the dataset a write would produce, handed to record's validation hook
// as an ordinary snapshot at the epoch it would commit at. That is what
// replaced `query_init_txn`, which took a caller's write transaction and
// which SPARQL-T-0031 deleted.
//
// The snippet in the README is the `check` procedure below plus the
// `store_open` that wires it. What is asserted here is the part that
// matters and that a reader cannot check by eye: that the candidate
// really carries the uncommitted write. The README's `return !found` is
// where a caller decides; this one always accepts, so that both commits
// land and the second can be counted against the first.
CANDIDATE :: `@prefix foaf: <http://xmlns.com/foaf/0.1/> .
<http://example/carol> a foaf:Person ; foaf:name "Carol" .
`

@(private = "file")
Judge :: struct {
	algebra:   sparql.Algebra,
	solutions: int,
	calls:     int,
}

@(private = "file")
check :: proc(
	data: rawptr,
	candidate: record.Snapshot,
	ops: []record.Resident_Op,
	allocator: runtime.Allocator,
) -> bool {
	j := cast(^Judge)data
	j.calls += 1
	_ = ops
	_ = allocator

	q: sparql.Query
	defer sparql.query_destroy(&q) // does not release the candidate
	if !sparql.query_init(&q, j.algebra, candidate) {
		return true
	}
	n := 0
	for {
		_, more := sparql.query_next(&q)
		if !more {
			break
		}
		n += 1
	}
	j.solutions = n
	return true
}

@(test)
readme_query_over_a_validator_candidate :: proc(t: ^testing.T) {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(FRIENDS))
	defer sparql.parser_destroy(&p)
	if _, parsed := sparql.parse(&p); !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, _ := sparql.translate(&p)

	j := Judge {
		algebra = algebra,
	}

	fs: record.Mem_FS
	defer record.mem_fs_destroy(&fs)
	db: record.Store
	_, open_err, _, _ := record.store_open(
		&db,
		"candidate",
		record.mem_file_ops(&fs),
		record.Validator{check = check, data = &j},
	)
	if !testing.expectf(t, open_err == .None, "cannot open the store: %v", open_err) {
		return
	}
	defer record.store_close(&db)

	load :: proc(t: ^testing.T, db: ^record.Store, source: string, scope: string) -> bool {
		ops, err := ingest.turtle(
			transmute([]byte)source,
			nil,
			context.allocator,
			blank_prefix = scope,
			base = "http://example/",
		)
		if !testing.expectf(t, err.kind == .None, "did not parse: %v", err.kind) {
			return false
		}
		defer ingest.ops_destroy(ops, context.allocator)
		_, _, apply_err := record.apply(db, {ops = ops})
		return testing.expectf(t, apply_err == record.Apply_Error{}, "did not load: %v", apply_err)
	}

	if !load(t, &db, DATA, "people_") {
		return
	}
	testing.expect_value(t, j.solutions, 2) // Alice and Bob

	if !load(t, &db, CANDIDATE, "carol_") {
		return
	}
	// Alice, Bob, and the uncommitted Carol — the candidate is the
	// dataset the write would produce, so the query sees it before a byte
	// is written.
	testing.expect_value(t, j.solutions, 3)
	testing.expect_value(t, j.calls, 2)
}
