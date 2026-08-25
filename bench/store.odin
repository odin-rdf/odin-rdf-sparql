package main

// The store side of the benchmark, isolated in one file **because it is
// the file the port rewrites.** Everything else here — the generator,
// the query mix, the reporting, the pinned counts — survives unchanged.
//
// *(Rewritten by SPARQL-T-0031 rather than by SPARQL-T-0036, which is
// where the plan put it. T-0031 deletes `sparql/kvstore`, and `bench` is
// vetted by `make check`, so the two could not be separated: a task
// whose green boundary is "check vets every surviving package" has to
// leave this one compiling. What T-0036 does with it is what its title
// says — run it and compare against T-0040's numbers.)*
//
// `open_ephemeral` + `load_turtle` + `load_trig` became `Mem_FS` +
// `store_open` + `ingest` + `apply`. The memory seam rather than a file:
// a benchmark measuring a query engine should not be measuring a
// filesystem, and record's resident projection is what the queries read
// either way — the log is the durable form, not the queried one.

import "core:fmt"
import "core:os"

import "record:record"
import "record:record/ingest"

// Bench_Store is the handle the rest of the benchmark holds.
//
// **It is heap-allocated and passed by pointer, and that is a
// requirement rather than a style.** record's writer holds a pointer to
// the `Mem_FS` inside this struct, so the struct must not be copied or
// moved after `store_open` — returning one by value would leave the
// writer pointing at a dead stack frame.
Bench_Store :: struct {
	fs: record.Mem_FS,
	db: record.Store,
}

// store_load opens a scratch store and loads one corpus into it. Fatal
// on failure: every failure here is a broken benchmark rather than a
// measurement, and continuing would report a number for an empty store.
store_load :: proc(c: Corpus) -> ^Bench_Store {
	s := new(Bench_Store)
	_, open_err, load_err, write_err := record.store_open(&s.db, "bench", record.mem_file_ops(&s.fs))
	if open_err != .None {
		die("the scratch store did not open: %v", open_err)
	}
	if load_err != .None || write_err != .None {
		die("the scratch store did not boot: load %v, write %v", load_err, write_err)
	}

	// One epoch per graph. `blank_prefix` is the load scope and must be
	// blank-node label characters; the generator emits none, but the
	// scope is what keeps two documents' labels apart and costs nothing
	// to state.
	store_apply(s, ingest.turtle(transmute([]byte)c.default_ttl, nil, context.allocator, blank_prefix = "bench_d_"), c.default_triples, "default graph")
	if c.named_trig != "" {
		store_apply(s, ingest.trig(transmute([]byte)c.named_trig, context.allocator, blank_prefix = "bench_n_"), c.named_triples, "named graph")
	}
	return s
}

// store_apply commits one document's ops and checks that the store took
// what the generator says it emitted.
//
// The generator counts what it wrote and `ingest` emits a document's
// *set* of statements (RECORD-T-0019), so a document that states a
// triple twice makes the two disagree. That is a generator bug rather
// than a store one, and it would quietly change every count below.
@(private = "file")
store_apply :: proc(s: ^Bench_Store, ops: []record.Op, err: ingest.Error, want: int, what: string) {
	if err.kind != .None {
		die("the %s did not parse: %v (line %d, column %d)", what, err.kind, err.syntax.line, err.syntax.column)
	}
	defer ingest.ops_destroy(ops, context.allocator)
	if len(ops) != want {
		die("%s: generated %d triples, ingest emitted %d", what, want, len(ops))
	}
	if _, _, apply_err := record.apply(&s.db, {ops = ops}); apply_err != (record.Apply_Error{}) {
		die("the %s did not load: %v", what, apply_err)
	}
}

// store_snapshot pins the dataset one query answers about. The caller
// releases it — see sparql.query_init, which holds a snapshot but does
// not own it.
store_snapshot :: proc(s: ^Bench_Store) -> record.Snapshot {
	snap, err := record.store_latest(&s.db)
	if err != .None {
		die("the store has no snapshot: %v", err)
	}
	return snap
}

store_close :: proc(s: ^Bench_Store) {
	record.store_close(&s.db)
	record.mem_fs_destroy(&s.fs)
	free(s)
}

@(private = "file")
die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("FATAL: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
