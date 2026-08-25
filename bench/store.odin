package main

// The store side of the benchmark, isolated in one file **because it is
// the file SPARQL-T-0036 rewrites.** Everything else here — the
// generator, the query mix, the reporting, the pinned counts — survives
// the port unchanged; this is `open_ephemeral` + `load_turtle` +
// `load_trig`, which become `Mem_FS` + `store_open` + `ingest` + `apply`
// against odin-rdf-record. Keeping the seam in one place is what makes
// that a rewrite of 80 lines rather than a search through 800.

import "core:fmt"
import "core:os"

import kvstore "store:store/kvstore"

// A scratch map far larger than `EPHEMERAL_OPTIONS`' 16 MiB, which is
// sized for the family's test suites — a few dozen triples per store.
// The largest configuration here loads six figures of them, and LMDB
// answers a full map with MDB_MAP_FULL rather than by growing.
BENCH_OPTIONS :: kvstore.Options {
	map_size    = 2 << 30,
	max_readers = 126,
	no_sync     = true,
}

// Bench_Store is the handle the rest of the benchmark holds. It is a
// struct rather than a bare `^kvstore.Store` so that the port has a
// place to put the record store's two-part handle (`Mem_FS` beside
// `Store`) without touching a call site.
Bench_Store :: struct {
	db: ^kvstore.Store,
}

// store_load opens a scratch store and loads one corpus into it. Fatal
// on failure: every failure here is a broken benchmark rather than a
// measurement, and continuing would report a number for an empty store.
store_load :: proc(c: Corpus) -> Bench_Store {
	db, open_err := kvstore.open_ephemeral(BENCH_OPTIONS)
	if open_err != nil {
		die("the scratch store did not open: %v", open_err)
	}

	added, parse_err, db_err := kvstore.load_turtle(db, transmute([]byte)c.default_ttl, NS)
	if parse_err.message != "" {
		die("the default graph did not parse: %s", parse_err.message)
	}
	if db_err != nil {
		die("the default graph did not load: %v", db_err)
	}
	if added != c.default_triples {
		// The generator counts what it emitted and the store counts what
		// it stored; a document that states a triple twice makes the two
		// disagree. That is a generator bug rather than a store one, and
		// it would quietly change every count below.
		die("default graph: generated %d triples, store took %d", c.default_triples, added)
	}

	if c.named_trig != "" {
		n_added, n_parse_err, n_db_err := kvstore.load_trig(db, transmute([]byte)c.named_trig, NS)
		if n_parse_err.message != "" {
			die("the named graph did not parse: %s", n_parse_err.message)
		}
		if n_db_err != nil {
			die("the named graph did not load: %v", n_db_err)
		}
		if n_added != c.named_triples {
			die("named graph: generated %d triples, store took %d", c.named_triples, n_added)
		}
	}

	return Bench_Store{db = db}
}

store_close :: proc(s: ^Bench_Store) {
	if s.db != nil {
		kvstore.close(s.db)
	}
	s^ = {}
}

@(private = "file")
die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("FATAL: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
