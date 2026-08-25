package guards

// The store a guard measures against (SPARQL-T-0032).
//
// A guard is a claim about *this engine's* memory, so the store has to be
// separable from it in two different ways depending on the guard:
//
//   - the streaming and boundedness guards want the store **outside** the
//     tracked allocator, because a store's memory does scale with the
//     data and that is its business; and
//   - the leak guards want it **inside**, so that anything the engine
//     failed to free is visible — and then torn down before the
//     assertion, since a store's own live allocations would otherwise
//     read as the engine's leaks.
//
// So `guard_open` takes the allocator explicitly and every guard says
// which of the two it is doing.
//
// **A Guard_DB is declared in place and passed by pointer, never returned
// by value**: record's writer holds a pointer to the `Mem_FS` inside it.
//
// *(Ported from `kvstore.open_ephemeral` + `load_triples` + `close` by
// SPARQL-T-0032. The fixtures are unchanged, including the triple-term
// ones — record refused those outright before `v0.4.0` and stores them
// now, which is what the pin bump bought.)*

import "base:runtime"

import "core:testing"

import "record:record"
import "record:record/ingest"

Guard_DB :: struct {
	fs:        record.Mem_FS,
	db:        record.Store,
	snap:      record.Snapshot,
	pinned:    bool,
	open:      bool,
	loaded:    int,
	allocator: runtime.Allocator,
}

guard_open :: proc(t: ^testing.T, g: ^Guard_DB, name: string, allocator := context.allocator) -> bool {
	g.allocator = allocator
	_, open_err, load_err, write_err := record.store_open(
		&g.db,
		name,
		record.mem_file_ops(&g.fs),
		{},
		0,
		allocator,
	)
	if !testing.expectf(t, open_err == .None, "the store should open: %v", open_err) {
		return false
	}
	if !testing.expectf(t, load_err == .None && write_err == .None, "the store should boot: %v %v", load_err, write_err) {
		record.store_close(&g.db)
		return false
	}
	g.open = true
	return true
}

// guard_load_ntriples ingests an N-Triples fixture into the default graph
// and commits it as one epoch. N-Triples because these fixtures are
// generated line by line and have no prefixes to declare.
guard_load_ntriples :: proc(t: ^testing.T, g: ^Guard_DB, source: string) -> bool {
	prefix := guard_scope(g)
	defer delete(prefix, g.allocator)
	ops, err := ingest.ntriples(transmute([]byte)source, nil, g.allocator, blank_prefix = prefix)
	if !testing.expectf(t, err.kind == .None, "fixture did not parse: %v at line %d", err.kind, err.syntax.line) {
		return false
	}
	defer ingest.ops_destroy(ops, g.allocator)
	_, _, apply_err := record.apply(&g.db, {ops = ops}, g.allocator)
	return testing.expectf(t, apply_err == record.Apply_Error{}, "fixture did not load: %v", apply_err)
}

// guard_snap pins the store's head, once — the dataset every query in one
// guard answers about.
guard_snap :: proc(t: ^testing.T, g: ^Guard_DB) -> (record.Snapshot, bool) {
	if g.pinned {
		return g.snap, true
	}
	snap, err := record.store_latest(&g.db)
	if !testing.expectf(t, err == .None, "cannot pin a snapshot: %v", err) {
		return {}, false
	}
	g.snap = snap
	g.pinned = true
	return g.snap, true
}

// guard_close releases the snapshot and closes the store, in that order:
// `store_destroy` asserts that every snapshot has been released.
//
// The leak guards call this **by hand before their assertion** rather
// than deferring it, because a deferred teardown runs after the check and
// would leave the store's own live allocations looking like the engine's.
guard_close :: proc(g: ^Guard_DB) {
	if g.pinned {
		record.snapshot_release(&g.snap)
		g.pinned = false
	}
	if g.open {
		record.store_close(&g.db)
		g.open = false
	}
	record.mem_fs_destroy(&g.fs)
}

// guard_scope is the blank-node load scope: label characters, distinct
// per document, so two fixtures in one store cannot share a label.
@(private = "file")
guard_scope :: proc(g: ^Guard_DB) -> string {
	digits := "0123456789"
	n := g.loaded
	g.loaded += 1
	out := make([]byte, 8, g.allocator)
	copy(out, "guard_")
	out[6] = digits[(n / 10) %% 10]
	out[7] = digits[n %% 10]
	return string(out)
}
