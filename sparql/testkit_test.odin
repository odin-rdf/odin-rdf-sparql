// The store harness this package's tests share (SPARQL-T-0032).
//
// Before the port these tests lived in `sparql/kvstore`, one file per
// subject, and each carried its own copy of "open a store, load a
// document, parse, translate, prepare, drain, render" — five copies of
// the same eighty lines, differing only in how a solution was spelled.
// The engine is one package now, so they are too, and the copies
// collapse into what is here: **one store type and one query driver,
// with the row renderer passed in**, because how a solution is spelled
// is the assertions' vocabulary and genuinely differs between files.
//
// `Test_DB` is the odin-rdf-shacl `Test_DB`/`Guard_DB` pattern: a store
// over record's memory seam, a snapshot pinned on first use, released
// before close. It is **declared in place and passed by pointer,
// never returned by value** — record's writer holds a pointer to the
// `Mem_FS` inside it, so a copy would leave the writer addressing a dead
// frame. That is the one rule of this file.
//
// The suites in `tests/w3c` are the verdict. What is asserted here is
// what a suite is a poor place to *learn*: that SUM is poisoned by an
// unbound value where COUNT is not, that a path's zero-length case is
// nodes(G) and not the empty set, that GRAPH scoping survives OPTIONAL.
package sparql

import "base:runtime"

import "core:fmt"
import "core:strings"
import "core:testing"

import rdf "rdf:rdf"
import record "record:record"
import "record:record/ingest"

// TEST_BASE is the base every fixture in this package resolves against
// and every query is parsed with. One constant so a document and the
// query over it cannot disagree.
@(private)
TEST_BASE :: "http://example/"

// Test_DB is a record store over the memory seam, plus the one snapshot
// the queries against it read.
//
// The snapshot is pinned by `test_db_snap` on first use rather than at
// open, because a fixture is usually loaded in two or three `apply`
// calls and a snapshot taken before the last of them would answer about
// a dataset the test did not write. Every later call returns the same
// one, so all the queries of one test see one dataset — which is what
// `sparql.query_init`'s contract is about.
@(private)
Test_DB :: struct {
	fs:     record.Mem_FS,
	db:     record.Store,
	snap:   record.Snapshot,
	pinned: bool,
	open:   bool,
	// How many documents have been loaded, which is what makes each
	// one's blank-node scope distinct. See test_db_load.
	loaded: int,
}

// test_db_open opens an empty store. `name` is only a label in record's
// log; it names no file, because the memory seam has none.
@(private)
test_db_open :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	name: string,
	validator := record.Validator{},
	loc := #caller_location,
) -> bool {
	// The validator is wired **at open**, which is record's contract for
	// it (RECORD-A-0006: the hook is bound once at store construction) —
	// not assigned onto the store afterwards, which would be a mutation
	// of a field `apply` reads.
	_, open_err, load_err, write_err := record.store_open(&d.db, name, record.mem_file_ops(&d.fs), validator)
	if !testing.expectf(t, open_err == .None, "cannot open the store: %v", open_err, loc = loc) {
		return false
	}
	if !testing.expectf(
		t,
		load_err == .None && write_err == .None,
		"the store did not boot: load %v, write %v",
		load_err,
		write_err,
		loc = loc,
	) {
		record.store_close(&d.db)
		return false
	}
	d.open = true
	return true
}

// test_db_load ingests a Turtle document into one graph — nil for the
// default graph — and commits it as one epoch.
//
// **`blank_prefix` is the load scope, and it is derived from the caller
// *and* from how many documents this store has already taken**, so two
// documents cannot collide by sharing a blank-node label unless a test
// asks them to — which several do, by loading one document. A caller
// that wants two documents to share a scope passes `scope` explicitly.
// record requires the prefix to be made of label characters, so the file
// and line are joined with underscores rather than written as a
// location: a `/` or a `.` would produce a scope that could not be
// written back out as Turtle.
@(private)
test_db_load :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	source: string,
	graph: rdf.Graph_Label = nil,
	scope := "",
	loc := #caller_location,
) -> bool {
	if source == "" {
		return true
	}
	prefix := scope_prefix(d, loc, scope)
	defer delete(prefix)
	ops, err := ingest.turtle(
		transmute([]byte)source,
		graph,
		context.allocator,
		blank_prefix = prefix,
		base = TEST_BASE,
	)
	return apply_ops(t, d, ops, err, loc)
}

// test_db_load_trig ingests a TriG document, which names its own graphs
// and therefore takes none.
@(private)
test_db_load_trig :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	source: string,
	scope := "",
	loc := #caller_location,
) -> bool {
	if source == "" {
		return true
	}
	prefix := scope_prefix(d, loc, scope)
	defer delete(prefix)
	ops, err := ingest.trig(transmute([]byte)source, context.allocator, blank_prefix = prefix, base = TEST_BASE)
	return apply_ops(t, d, ops, err, loc)
}

@(private = "file")
apply_ops :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	ops: []record.Op,
	err: ingest.Error,
	loc: runtime.Source_Code_Location,
) -> bool {
	if !testing.expectf(
		t,
		err.kind == .None,
		"fixture did not parse: %v at line %d, column %d",
		err.kind,
		err.syntax.line,
		err.syntax.column,
		loc = loc,
	) {
		return false
	}
	defer ingest.ops_destroy(ops, context.allocator)
	// **A changeset is the delta, not the world.** record refuses an
	// assert of a quad that is already live with `.Already_Live` at the
	// offending op, so a fixture written as "the whole document again"
	// fails where odin-rdf-store's idempotent insert quietly accepted it.
	// A document that states one triple twice is fine — `ingest` emits a
	// document's *set* (RECORD-T-0019, record v0.2.0).
	_, _, apply_err := record.apply(&d.db, {ops = ops})
	return testing.expectf(t, apply_err == record.Apply_Error{}, "fixture did not load: %v", apply_err, loc = loc)
}

// test_db_snap pins the store's head, once. See Test_DB.
@(private)
test_db_snap :: proc(t: ^testing.T, d: ^Test_DB, loc := #caller_location) -> (record.Snapshot, bool) {
	if d.pinned {
		return d.snap, true
	}
	snap, err := record.store_latest(&d.db)
	if !testing.expectf(t, err == .None, "cannot pin a snapshot: %v", err, loc = loc) {
		return {}, false
	}
	d.snap = snap
	d.pinned = true
	return d.snap, true
}

// test_db_close releases the snapshot and closes the store, in that
// order: `store_destroy` asserts that every snapshot has been released.
@(private)
test_db_close :: proc(d: ^Test_DB) {
	if d.pinned {
		record.snapshot_release(&d.snap)
		d.pinned = false
	}
	if d.open {
		record.store_close(&d.db)
		d.open = false
	}
	record.mem_fs_destroy(&d.fs)
}

// scope_prefix turns a call site and a document's ordinal into a
// blank-node label scope: `path_test.odin:212`, second document, becomes
// `path_test_odin_212_2_`. An explicit `scope` replaces the ordinal, for
// the tests that want two documents to share one.
@(private = "file")
scope_prefix :: proc(d: ^Test_DB, loc: runtime.Source_Code_Location, scope: string) -> string {
	b := strings.builder_make()
	file := loc.file_path
	if slash := strings.last_index_any(file, `/\`); slash >= 0 {
		file = file[slash + 1:]
	}
	write_label_chars(&b, file)
	fmt.sbprintf(&b, "_%d_", loc.line)
	if scope != "" {
		write_label_chars(&b, scope)
	} else {
		fmt.sbprintf(&b, "%d", d.loaded)
	}
	strings.write_byte(&b, '_')
	d.loaded += 1
	return strings.to_string(b)
}

@(private = "file")
write_label_chars :: proc(b: ^strings.Builder, text: string) {
	for r in text {
		strings.write_rune(b, r if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') else '_')
	}
}

// Row_Renderer spells one solution the way a file's assertions read it.
// It is a parameter rather than a fixed convention because the
// conventions genuinely differ — `?x=<http://example/a>` where the
// bindings are the subject, `x=a` where they are noise around the one
// value being asserted — and rewriting a file's expectations to match a
// house style would be a change to what it asserts.
@(private)
Row_Renderer :: #type proc(q: ^Query, row: []record.Term_ID, names: []string, internal: []bool) -> string

// test_solve parses, translates, prepares and drains a query, rendering
// each solution. The store is the caller's and outlives the call; the
// rows are the caller's and are freed with destroy_rows.
//
// The snapshot is pinned here and **not released**: it belongs to the
// Test_DB, which releases it at close. That is `query_init`'s contract —
// the snapshot is the caller's, so that a validator's candidate can be
// passed to a query without the query dropping a reference it never
// took.
@(private)
test_solve :: proc(
	t: ^testing.T,
	d: ^Test_DB,
	query: string,
	render: Row_Renderer,
	loc := #caller_location,
	scope := record.Graph_Scope.All,
	graphs: []record.Term_ID = nil,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	snap, pinned := test_db_snap(t, d, loc)
	if !pinned {
		return nil, false
	}

	p: Parser
	parser_init(&p, transmute([]byte)query, TEST_BASE)
	defer parser_destroy(&p)
	if _, parsed := parse(&p); !testing.expectf(t, parsed, "query did not parse: %v", p.err.kind, loc = loc) {
		return nil, false
	}
	algebra, translated := translate(&p)
	if !testing.expect(t, translated, "query did not translate", loc = loc) {
		return nil, false
	}

	q: Query
	if !query_init(&q, algebra, snap, parser_base(&p), scope, graphs) {
		testing.expectf(t, false, "query not supported: %s", q.unsupported, loc = loc)
		query_destroy(&q)
		return nil, false
	}
	defer query_destroy(&q)

	names := query_var_names(&q)
	internal := query_var_internal(&q)
	rows = make([dynamic]string)
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		append(&rows, render(&q, row, names, internal))
	}
	return rows, true
}

// test_solve_source is the common case in one call: a fresh store, one
// Turtle document, one query. An empty source is a query that needs no
// data, which the VALUES-driven cases are.
//
// It closes the store before returning, so **every term in the rendered
// rows has already outlived the store it came from** — which is the
// property worth having under test on every case rather than only where
// someone remembered to check it. A row that borrowed record's
// dictionary arena would be reading freed memory by the time it is
// compared.
@(private)
test_solve_source :: proc(
	t: ^testing.T,
	source: string,
	query: string,
	render: Row_Renderer,
	loc := #caller_location,
) -> (
	rows: [dynamic]string,
	ok: bool,
) {
	d: Test_DB
	defer test_db_close(&d)
	if !test_db_open(t, &d, "solve", loc = loc) {
		return nil, false
	}
	if !test_db_load(t, &d, source, nil, loc = loc) {
		return nil, false
	}
	return test_solve(t, &d, query, render, loc)
}

@(private)
expect_rows :: proc(t: ^testing.T, rows: [dynamic]string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(rows) == len(want), "got %d solutions, want %d: %v", len(rows), len(want), rows, loc = loc) {
		return
	}
	for expected, i in want {
		testing.expectf(t, rows[i] == expected, "solution %d: got %q, want %q", i, rows[i], expected, loc = loc)
	}
}

@(private)
expect_contains :: proc(t: ^testing.T, rows: [dynamic]string, want: string, loc := #caller_location) {
	for row in rows {
		if row == want {
			return
		}
	}
	testing.expectf(t, false, "no solution %q among %v", want, rows, loc = loc)
}

@(private)
destroy_rows :: proc(rows: ^[dynamic]string) {
	for row in rows {
		delete(row)
	}
	delete(rows^)
}
