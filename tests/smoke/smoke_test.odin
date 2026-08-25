// SPARQL-T-0030: proof that the `record:` collection is wired, and that
// this repository's own corpus is storable on the other side of it. Two
// tests, and they answer two different questions.
//
// `record_round_trip` is the plumbing: a store opened over the memory
// seam, a document ingested and applied, matched back through the
// snapshot read API, released and closed — the round trip every ported
// harness call site will make (SPARQL-I-0003 §8). It asserts nothing
// about SPARQL. It asserts that the collection resolves, that the
// library links on this runner, and that the lifetime discipline is
// understood.
//
// `triple_terms_from_the_corpus` is this repository's acceptance of
// RECORD-I-0004, the record-side prerequisite the initiative's §6
// gated on. It reads a data file out of `tests/w3c/`, not a fixture
// written for the occasion, because what was asked for was that *this*
// corpus become storable. It also stands in for the binding
// SPARQL-T-0031 will make: `Triple_Reader` against
// `snapshot_triple_parts`.
//
// This package does not import `sparql` and must not — a smoke test
// that needs the engine to compile is testing the engine rather than
// the collection. It is deleted when the ported suite makes it
// redundant (SPARQL-T-0032/T-0033).
package smoke

import "core:os"
import "core:testing"

import "rdf:rdf"
import "record:record"
import "record:record/ingest"

// The vendored suite, reached from this file rather than from the
// working directory, the way the W3C harness does it.
SUITE_ROOT :: #directory + "../w3c/"

DOC :: `PREFIX : <http://example/>

:alice :knows :bob .
:bob   :knows :carol .
:alice :knows :bob .
`

@(test)
record_round_trip :: proc(t: ^testing.T) {
	fs: record.Mem_FS
	defer record.mem_fs_destroy(&fs)

	// The store must not be copied or moved after store_open: the
	// writer inside it holds a pointer to the Mem_FS. Declared in
	// place, passed as ^Store, never returned by value.
	s: record.Store
	_, open_err, _, _ := record.store_open(&s, "smoke", record.mem_file_ops(&fs))
	testing.expect_value(t, open_err, record.Open_Error.None)
	if open_err != .None {
		return
	}
	defer record.store_close(&s)

	// blank_prefix is the load scope and must be made of blank-node
	// label characters -- `smoke_`, never `smoke/`.
	ops, ing_err := ingest.turtle(transmute([]byte)string(DOC), nil, context.allocator, blank_prefix = "smoke_")
	testing.expect_value(t, ing_err.kind, ingest.Error_Kind.None)
	defer ingest.ops_destroy(ops, context.allocator)

	// The document states `:alice :knows :bob` twice and ingest emits a
	// document's *set*, so two ops rather than three (RECORD-T-0019).
	// A second assert of a live quad would be .Already_Live, which is
	// why this matters to a harness and not only to a purist.
	testing.expect_value(t, len(ops), 2)

	epoch, _, apply_err := record.apply(&s, {ops = ops})
	testing.expect_value(t, apply_err, record.Apply_Error{})
	testing.expect_value(t, epoch, record.Epoch(1))

	snap, snap_err := record.store_latest(&s)
	testing.expect_value(t, snap_err, record.Snapshot_Error.None)
	if snap_err != .None {
		return
	}
	// Released before store_close -- store_destroy asserts it.
	defer record.snapshot_release(&snap)

	alice, a_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/alice"))
	knows, k_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/knows"))
	bob, b_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/bob"))
	testing.expect(t, a_ok && k_ok && b_ok, "the ingested terms resolve")
	testing.expect_value(t, record.snapshot_kind(snap, alice), record.Term_Kind.IRI)

	// One match, read the way the ported executor will read: a pattern
	// of ids, a range, a scan, a fact.
	rng := record.snapshot_match(snap, record.Pattern{s = alice})
	sc := record.range_iter(rng, record.Filter{origin = .Any})
	count := 0
	for {
		id, ok := record.scan_next(&sc)
		if !ok {
			break
		}
		f := record.snapshot_fact(snap, id)
		testing.expect_value(t, f.p, knows)
		testing.expect_value(t, f.o, bob)
		// The default graph is stored as G = 0, which is also
		// "unbound" in a Pattern. SPARQL-I-0003 §4 names that
		// collision as the port's one real sentinel hazard.
		testing.expect_value(t, f.g, record.Term_ID(0))
		count += 1
	}
	testing.expect_value(t, count, 1)
}

@(test)
triple_terms_from_the_corpus :: proc(t: ^testing.T) {
	// data-0-tripleterms.ttl is five lines of this repository's
	// vendored sparql12-eval-triple-terms suite, and it carries the
	// two shapes that matter: a plain triple term, and one nested
	// inside another whose innermost component is an inlineable
	// integer.
	src, read_err := os.read_entire_file(
		SUITE_ROOT + "sparql12-eval-triple-terms/data-0-tripleterms.ttl",
		context.allocator,
	)
	testing.expect_value(t, read_err, os.Error(nil))
	if read_err != nil {
		return
	}
	defer delete(src)

	fs: record.Mem_FS
	defer record.mem_fs_destroy(&fs)
	s: record.Store
	_, open_err, _, _ := record.store_open(&s, "smoke", record.mem_file_ops(&fs))
	testing.expect_value(t, open_err, record.Open_Error.None)
	if open_err != .None {
		return
	}
	defer record.store_close(&s)

	ops, ing_err := ingest.turtle(src, nil, context.allocator, blank_prefix = "tt_")
	testing.expect_value(t, ing_err.kind, ingest.Error_Kind.None)
	defer ingest.ops_destroy(ops, context.allocator)
	testing.expect_value(t, len(ops), 2)

	// Before RECORD-I-0004 this returned Apply_Error{.Unsupported_Term,
	// 0} and nothing was written. That was the whole gate.
	_, _, apply_err := record.apply(&s, {ops = ops})
	testing.expect_value(t, apply_err, record.Apply_Error{})

	snap, snap_err := record.store_latest(&s)
	testing.expect_value(t, snap_err, record.Snapshot_Error.None)
	if snap_err != .None {
		return
	}
	defer record.snapshot_release(&snap)

	f_id, f_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/f"))
	g_id, g_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/g"))
	testing.expect(t, f_ok && g_ok, ":f and :g resolve")

	// `:f :g <<( :s :p <<(:x2 :y3 123) >> )>>` -- find the one fact and
	// take its object apart without decoding anything, which is what
	// SPARQL-T-0031 binds Triple_Reader to.
	sc := record.range_iter(record.snapshot_match(snap, record.Pattern{s = f_id, p = g_id}), record.Filter{origin = .Any})
	fid, has := record.scan_next(&sc)
	testing.expect(t, has, "the nested statement is a fact")
	if !has {
		return
	}
	outer := record.snapshot_fact(snap, fid).o
	testing.expect_value(t, record.snapshot_kind(snap, outer), record.Term_Kind.Triple)

	parts, p_ok := record.snapshot_triple_parts(snap, outer)
	testing.expect(t, p_ok, "the outer triple term's three components read back")
	if !p_ok {
		return
	}
	sub, s_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/s"))
	testing.expect(t, s_ok && parts[0] == sub, "its subject is :s")
	testing.expect_value(t, record.snapshot_kind(snap, parts[2]), record.Term_Kind.Triple)

	inner, i_ok := record.snapshot_triple_parts(snap, parts[2])
	testing.expect(t, i_ok, "and the nested one recurses")
	if !i_ok {
		return
	}
	x2, x_ok := record.snapshot_resolve(snap, rdf.IRI("http://example/x2"))
	testing.expect(t, x_ok && inner[0] == x2, "the nested subject is :x2")

	// The innermost component is an inlined integer: no dictionary
	// entry, and the id carries the value. It is also the hazard
	// SPARQL-I-0003 §5 wrote down before it happened -- this id is
	// above CONSUMER_ID_FIRST and is an *ordinary term*, so the
	// engine's `is_synthetic` must be a bounded range test rather than
	// the `>=` threshold it is today. Asserted here rather than
	// argued, because the whole point of §5 is that the argument is
	// easy to get backwards.
	testing.expect(
		t,
		inner[2] >= record.CONSUMER_ID_FIRST,
		"an inlined literal's id lands above the consumer range's floor",
	)
	buf: [record.INLINE_LEXICAL_MAX]byte
	obj, obj_ok := record.snapshot_term(snap, inner[2], buf[:])
	testing.expect(t, obj_ok, "the innermost component decodes")
	testing.expect_value(t, obj, rdf.Term(rdf.Literal{lexical = "123", datatype = rdf.XSD_INTEGER}))
	// Total over every kind snapshot_term can return, so a caller
	// pairs it with every call rather than with some (RECORD-A-0008).
	record.snapshot_term_destroy(snap, inner[2], obj)

	// A pattern binding a triple term's id matches the fact carrying
	// it: layer 1 binds ids, and a triple term is an id.
	testing.expect(
		t,
		record.snapshot_exists(snap, record.Pattern{o = outer}, record.Filter{origin = .Any}),
		"a triple term is bindable in a pattern",
	)
}
