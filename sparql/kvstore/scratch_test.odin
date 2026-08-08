package sparql_kvstore

// Scratch databases for this package's tests, shared by every test file
// rather than copied into each.
//
// Ported here when the in-memory backend was retired (odin-rdf-store
// STORE-A-0006): the suites in this package used to build a dictionary
// and a dataset in memory, which needed no path and no cleanup. Every one
// of them then needed a database directory, and this was the one place
// that knew how to make one.
//
// **Most of them no longer do.** odin-rdf-store v0.3.0's `open_ephemeral`
// needs no path to name, make unique, or clean up, and this package uses it
// almost everywhere. Three tests still need a real directory, and they are
// the reason this file survives:
//
//   - `test_kvstore_query_setup_does_not_write` closes a store and reopens
//     the same path read-only. There is no path to reopen otherwise, and
//     `open_ephemeral` ignores `read_only` by contract.
//   - every test in `snapshot_test.odin`, because an ephemeral store opens
//     with `NOLOCK` and those tests deliberately hold a reader open across
//     a writer — the one arrangement LMDB says `NOLOCK` callers must not
//     create. The comment at the head of that file has the detail.
//
// Reach for `open_ephemeral` unless the test needs one of those two things.
//
// Uniqueness matters more than it looks. The test runner uses ~10
// threads, so several tests hold scratch databases at the same moment
// within one process — a pid alone does not separate them, and two tests
// sharing a path would fail in a way that looks like a store bug and
// reproduces only under load. The counter is what actually separates
// them; the pid only separates concurrent runs.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

@(private)
scratch_counter: u64

// scratch_path returns a database directory path unique within this
// process and across concurrent processes. Callers pass it to
// remove_scratch, which also frees it.
@(private)
scratch_path :: proc(name: string) -> string {
	n := sync.atomic_add(&scratch_counter, 1)
	return fmt.aprintf("%s/odin-sparql-kv-%s-%d-%d", temp_dir(), name, os.get_pid(), n)
}

// temp_dir returns the OS temp directory with no trailing separator, so
// callers add their own. macOS exports TMPDIR with a trailing slash and
// Linux usually exports nothing, which makes concatenating onto the
// variable a coin flip; Windows names it TEMP or TMP and has no /tmp to
// fall back to, so the fallback alone is not enough.
@(private)
temp_dir :: proc() -> string {
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
	return strings.trim_right(tmp, `/\`)
}

// remove_scratch deletes the database and frees the path.
@(private)
remove_scratch :: proc(path: string) {
	os.remove(fmt.tprintf("%s/data.mdb", path))
	os.remove(fmt.tprintf("%s/lock.mdb", path))
	os.remove(path)
	delete(path)
}
