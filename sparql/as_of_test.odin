// As-of queries (SPARQL-T-0034), against odin-rdf-record's epochs.
//
// **Nothing in this engine implements any of this, and that is what is
// being pinned.** record puts the coordinate on the snapshot —
// `store_at(s, epoch)` returns an ordinary `Snapshot` — so a query that
// takes one inherits as-of without knowing the concept exists.
// `query_init` has taken a snapshot since SPARQL-T-0031, for a caller
// that wants its query to answer about one dataset; that reading the
// past was not among the reasons it was shaped that way is exactly the
// point.
//
// So these tests contain no temporal SPARQL, no new constructor, and no
// call this engine did not already make. **No non-test source changed to
// make them pass**, which was this task's real criterion. What they
// assert is that the answers move with the epoch.
//
// **The W3C suites cannot produce them.** No entry edits its dataset
// after loading it, so no entry has a second epoch to read at, and an
// engine that silently ignored the snapshot would pass all 537 of them.
//
// **Every answer here differs from the answer at HEAD**, deliberately.
// A query returning the same thing either way demonstrates nothing — it
// is satisfied by an engine that ignores the snapshot it was handed — so
// each assertion below names the HEAD answer it is not. For the same
// reason the fixture *retracts*: an answer that only ever grows can also
// be produced by a read that stopped early, where a solution that comes
// back from the past cannot.
//
// *(Ported from `sparql/kvstore/as_of_test.odin`, which asserted the
// same property against odin-rdf-store's transaction time. Three things
// the port changed are pinned here as findings rather than smoothed
// over; each is marked below.)*
package sparql

import "core:slice"
import "core:strings"
import "core:testing"

import "rdf:rdf"
import "record:record"
import "record:record/ingest"

@(private = "file")
EX :: "http://example/"

// Epoch 1.
@(private = "file")
FIRST_EDIT :: `@prefix : <http://example/> .
:alice :knows :bob .
:bob :knows :carol .
`

// Epoch 2. It introduces :dave, a term the dictionary has never seen —
// which matters for the second test below.
@(private = "file")
SECOND_EDIT :: `@prefix : <http://example/> .
:carol :knows :dave .
`

// The join, and it has to be a join for the third epoch to be
// interesting: retracting the middle edge does not remove a triple from
// the single-pattern answer, it removes a *path*.
@(private = "file")
JOIN :: `PREFIX : <http://example/> SELECT ?a ?b ?c WHERE { ?a :knows ?b . ?b :knows ?c }`

@(private = "file")
EDGES :: `PREFIX : <http://example/> SELECT ?a ?b WHERE { ?a :knows ?b }`

@(private = "file")
INTO_DAVE :: `PREFIX : <http://example/> SELECT ?x WHERE { ?x :knows :dave }`

// row_text renders one solution as "alice bob carol", so an answer
// compares as text rather than as IDs.
@(private = "file")
row_text :: proc(q: ^Query, row: []record.Term_ID) -> string {
	sb := strings.builder_make()
	for id, slot in row {
		if slot > 0 {
			strings.write_byte(&sb, ' ')
		}
		if id == UNBOUND {
			strings.write_string(&sb, "?")
			continue
		}
		term := query_term(q, id)
		if iri, is_iri := term.(rdf.IRI); is_iri {
			strings.write_string(&sb, local_name(string(iri)))
		} else {
			strings.write_string(&sb, "<not an IRI>")
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
local_name :: proc(iri: string) -> string {
	if i := strings.last_index_any(iri, "#/"); i >= 0 {
		return iri[i + 1:]
	}
	return iri
}

// answer_at renders a query's whole answer at one snapshot as a sorted,
// comma-joined string — "" for no solutions.
//
// **There is one of these, not two.** The old file had `answer_at_head`
// and `answer_as_of`, which differed only in which constructor they
// called: `query_init` against the store, `query_init_txn` against a
// transaction carrying a horizon. On record there is one constructor and
// one kind of handle, so reading the past and reading the present are
// the same procedure called with a different snapshot — which is the
// whole of what this file exists to assert, now visible in its shape.
@(private = "file")
answer_at :: proc(t: ^testing.T, snap: record.Snapshot, text: string, loc := #caller_location) -> string {
	p: Parser
	parser_init(&p, transmute([]byte)text)
	defer parser_destroy(&p)
	_, parsed := parse(&p)
	if !testing.expect(t, parsed, "the query should parse", loc = loc) {
		return ""
	}
	algebra, _ := translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, snap, parser_base(&p)), "query not supported: %s", q.unsupported, loc = loc) {
		return ""
	}

	rows: [dynamic]string
	defer {
		for row in rows {
			delete(row)
		}
		delete(rows)
	}
	for {
		row, more := query_next(&q)
		if !more {
			break
		}
		append(&rows, row_text(&q, row))
	}
	slice.sort(rows[:])
	return strings.join(rows[:], ", ", context.temp_allocator)
}

// apply_turtle commits one document as one epoch and returns the epoch
// it landed at.
//
// **The epoch comes back from `apply` and is not looked up.** The old
// fixture read the clock after each commit and turned it into a horizon
// with `epoch_at(wall)`, carrying a paragraph about why that was
// deterministic — the newest epoch's sort time cannot be later than a
// reading taken after the commit returned, and a timestamp captured
// *between* two commits would name the wrong one on a platform with a
// coarse clock. None of that applies: record's as-of coordinate is the
// epoch, `apply` returns it, and `wall` in `snapshot_epoch_meta` is
// advisory evidence rather than an index.
//
// **That is a capability the port loses**, and it is small, real, and
// worth stating: there is no `epoch_at(wall)`. A caller holding a
// wall-clock time and wanting the epoch it belongs to must walk
// `snapshot_epoch_meta` itself. Recorded for SPARQL-T-0039.
@(private = "file")
apply_turtle :: proc(t: ^testing.T, td: ^Test_DB, source: string, scope: string) -> (record.Epoch, bool) {
	ops, err := ingest.turtle(
		transmute([]byte)source,
		nil,
		context.allocator,
		blank_prefix = scope,
		base = EX,
	)
	if !testing.expectf(t, err.kind == .None, "the edit did not parse: %v", err.kind) {
		return 0, false
	}
	defer ingest.ops_destroy(ops, context.allocator)
	epoch, _, apply_err := record.apply(&td.db, {ops = ops})
	if !testing.expectf(t, apply_err == record.Apply_Error{}, "the edit did not apply: %v", apply_err) {
		return 0, false
	}
	return epoch, true
}

// three_epochs builds the fixture and reports the epoch each edit
// landed at:
//
//	epoch 1  alice -> bob, bob -> carol
//	epoch 2  carol -> dave
//	epoch 3  bob -> carol retracted
//
// **The retraction names its quad.** odin-rdf-store spelled it
// `remove(ds, pattern)` — a `Match_Pattern`, so "retract everything
// :bob :knows" was one call. record retracts a *named quad*: an
// `Op{kind = .Retract}` carrying the whole triple, refused with
// `.Not_Live` if no live generation matches. A fixture that retracted by
// pattern has to say which quads it meant, which is more work and a
// narrower promise — and the narrower promise is why `.Not_Live` can
// exist at all.
//
// Either way it is a tombstone rather than an erasure, which is what
// keeps epochs 1 and 2 readable afterwards.
@(private = "file")
three_epochs :: proc(t: ^testing.T, td: ^Test_DB) -> (first, second, third: record.Epoch, ok: bool) {
	if !test_db_open(t, td, "as-of") {
		return
	}

	first = apply_turtle(t, td, FIRST_EDIT, "e1_") or_return
	second = apply_turtle(t, td, SECOND_EDIT, "e2_") or_return

	retract := []record.Op {
		{
			kind = .Retract,
			quad = rdf.Quad {
				triple = rdf.Triple {
					subject = rdf.IRI(EX + "bob"),
					predicate = rdf.IRI(EX + "knows"),
					object = rdf.IRI(EX + "carol"),
				},
			},
		},
	}
	epoch, _, apply_err := record.apply(&td.db, {ops = retract})
	if !testing.expectf(t, apply_err == record.Apply_Error{}, "the retraction did not apply: %v", apply_err) {
		return
	}
	third = epoch

	// Three edits, three distinct epochs. Without this the tests below
	// could pass by reading one dataset three times.
	if !testing.expectf(
		t,
		first < second && second < third,
		"the edits did not land at distinct epochs: %d %d %d",
		u32(first),
		u32(second),
		u32(third),
	) {
		return
	}
	return first, second, third, true
}

// The task's own criterion: the same query, through the same
// constructor, at two epochs, giving two different correct answers —
// and neither of them the answer at HEAD.
@(test)
test_a_query_at_a_past_epoch_answers_about_that_epoch :: proc(t: ^testing.T) {
	td: Test_DB
	defer test_db_close(&td)
	first, second, _, built := three_epochs(t, &td)
	if !built {
		return
	}

	head, head_ok := test_db_snap(t, &td)
	if !head_ok {
		return
	}

	// HEAD. The retraction took the middle edge, so the path is broken
	// and the join has no solutions at all — while both of its endpoints
	// are still in the graph, which is what makes this a fact about the
	// query rather than about an empty dataset.
	at_head := answer_at(t, head, JOIN)
	testing.expectf(t, at_head == "", "at HEAD the join should have no solutions, got `%s`", at_head)
	edges_at_head := answer_at(t, head, EDGES)
	testing.expectf(
		t,
		edges_at_head == "alice bob, carol dave",
		"HEAD should still hold both surviving edges, got `%s`",
		edges_at_head,
	)

	// As of epoch 2: the path the retraction later broke, plus the one
	// the second edit added.
	snap_second := snapshot_at(t, &td, second)
	defer record.snapshot_release(&snap_second)
	at_second := answer_at(t, snap_second, JOIN)
	testing.expectf(
		t,
		at_second == "alice bob carol, bob carol dave",
		"as of epoch %d the join should have both paths, got `%s`",
		u32(second),
		at_second,
	)

	// As of epoch 1: only the first, because :dave did not exist yet.
	snap_first := snapshot_at(t, &td, first)
	defer record.snapshot_release(&snap_first)
	at_first := answer_at(t, snap_first, JOIN)
	testing.expectf(
		t,
		at_first == "alice bob carol",
		"as of epoch %d the join should have one path, got `%s`",
		u32(first),
		at_first,
	)

	// Said once more as a difference rather than as two equalities: an
	// engine that ignored the snapshot would satisfy neither of these.
	testing.expect(t, at_first != at_head, "the epoch-1 answer must differ from HEAD's")
	testing.expect(t, at_second != at_head, "the epoch-2 answer must differ from HEAD's")
	testing.expect(t, at_first != at_second, "the two epochs must answer differently")
}

// The far end of the coordinate, and the near end. Two record behaviours
// that differ from odin-rdf-store's, each pinned.
@(test)
test_the_ends_of_the_epoch_range :: proc(t: ^testing.T) {
	td: Test_DB
	defer test_db_close(&td)
	_, _, third, built := three_epochs(t, &td)
	if !built {
		return
	}
	head, head_ok := test_db_snap(t, &td)
	if !head_ok {
		return
	}
	edges_at_head := answer_at(t, head, EDGES)

	// **Epoch 0 is the empty world before the first commit**, and it
	// answers a query rather than failing. The store spelled this
	// `EPOCH_NEVER`, a reserved value meaning "before anything"; record
	// spells it 0, which is simply one below the first epoch it ever
	// issues. A query at it is a query against the empty dataset — and
	// the single-pattern query is the one to ask, since its HEAD answer
	// is not empty.
	snap_zero := snapshot_at(t, &td, 0)
	defer record.snapshot_release(&snap_zero)
	before_anything := answer_at(t, snap_zero, EDGES)
	testing.expectf(t, before_anything == "", "as of epoch 0 the dataset is empty, got `%s`", before_anything)
	testing.expect(t, before_anything != edges_at_head, "the empty answer must differ from HEAD's")

	// **An epoch past head is refused, not clamped** — the difference
	// from odin-rdf-store worth pinning. The store's `EPOCH_LATEST` read
	// HEAD, so a caller that computed a horizon wrongly got an answer;
	// record returns `.Future_Epoch` and no snapshot, so the same mistake
	// is a diagnostic. Nothing in this engine chose either behaviour,
	// which is the point: the coordinate belongs to the store.
	_, future_err := record.store_at(&td.db, third + 1)
	testing.expect_value(t, future_err, record.Snapshot_Error.Future_Epoch)

	// And head itself is not past head.
	at_third := snapshot_at(t, &td, third)
	defer record.snapshot_release(&at_third)
	testing.expectf(
		t,
		answer_at(t, at_third, EDGES) == edges_at_head,
		"the newest epoch should read the same as the published head",
	)
}

// The subtlety worth a test of its own: **terms are not epoch-scoped;
// facts are.** A term interned by a later commit stays nameable in a
// read of an earlier one, so this engine's term binding resolves :dave
// through a snapshot that predates it.
//
// That is correct and the answer is still right, because binding
// resolves an ID and the *quads* are what the epoch hides. Asserting
// both halves is what makes this a test rather than a coincidence: if
// binding had instead failed to resolve :dave, the query would return
// the same empty answer for an entirely different reason, and the day
// the dictionary became temporal nothing here would notice.
//
// **This is the same correct division reached by a different
// mechanism.** odin-rdf-store's dictionary was deliberately
// non-temporal — a term is a name, not a claim (STORE-A-0008 §7).
// record's index set carries a term count and a fact table with
// lifetimes: a snapshot bounds which *facts* are visible by epoch and
// which *terms* exist by the count published with the set. Reading at an
// earlier epoch through the current set therefore sees every term.
@(test)
test_a_term_interned_after_the_epoch_is_nameable_but_matches_nothing :: proc(t: ^testing.T) {
	td: Test_DB
	defer test_db_close(&td)
	first, _, _, built := three_epochs(t, &td)
	if !built {
		return
	}
	head, head_ok := test_db_snap(t, &td)
	if !head_ok {
		return
	}

	at_head := answer_at(t, head, INTO_DAVE)
	testing.expectf(t, at_head == "carol", "at HEAD :dave should have one inbound edge, got `%s`", at_head)

	snap_first := snapshot_at(t, &td, first)
	defer record.snapshot_release(&snap_first)
	at_first := answer_at(t, snap_first, INTO_DAVE)
	testing.expectf(t, at_first == "", "as of epoch %d nothing knows :dave, got `%s`", u32(first), at_first)

	// The other half: the term resolves through that same snapshot.
	p: Parser
	parser_init(&p, transmute([]byte)string(INTO_DAVE))
	defer parser_destroy(&p)
	_, parsed := parse(&p)
	if !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, _ := translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, snap_first, parser_base(&p)), "query not supported: %s", q.unsupported) {
		return
	}
	_, found := query_find(&q, rdf.Term(rdf.IRI(EX + "dave")))
	testing.expect(t, found, ":dave is a name and names are not dated: it must still resolve through an as-of query")
}

@(private = "file")
snapshot_at :: proc(t: ^testing.T, td: ^Test_DB, epoch: record.Epoch, loc := #caller_location) -> record.Snapshot {
	snap, err := record.store_at(&td.db, epoch)
	testing.expectf(t, err == .None, "store_at(%d): %v", u32(epoch), err, loc = loc)
	return snap
}
