package sparql_kvstore

import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import rdf "rdf:rdf"
import store "store:store"
import kvstore "store:store/kvstore"

import sparql ".."

// As-of queries (SPARQL-T-0025), against odin-rdf-store's transaction
// time (STORE-A-0008, STORE-T-0052).
//
// **Nothing in this engine implements any of this, and that is what is
// being pinned.** The store puts the horizon on the transaction —
// `txn_begin_as_of` returns a read transaction through which *every*
// read is as-of — so a query that takes a `^Txn` inherits as-of without
// knowing the concept exists. `query_init_txn` has taken one since
// SPARQL-T-0024, for a caller holding its own write transaction; that an
// as-of read was not among the reasons it was added is exactly the point.
//
// So these tests contain no temporal SPARQL, no new constructor, and no
// call this engine did not already make. What they assert is that the
// answers move with the horizon.
//
// **The W3C suites cannot produce them.** No entry edits its dataset
// after loading it, so no entry has a second epoch to read at, and an
// engine that silently ignored the horizon would pass all 483 of them.
//
// **Every answer here differs from the answer at HEAD**, deliberately.
// A query returning the same thing either way demonstrates nothing —
// it is satisfied by an engine that ignores the transaction it was
// handed — so each assertion below names the HEAD answer it is not.
// For the same reason the fixture *retracts*: an answer that only ever
// grows can also be produced by a read that stopped early, where a
// solution that comes back from the past cannot.
//
// `open_ephemeral` is correct here (see `scratch_test.odin`): every
// write completes before any read transaction opens, so this is not the
// reader-across-writer arrangement `NOLOCK` forbids and
// `snapshot_test.odin` sets up on purpose.

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
// compares as text rather than as IDs — IDs are stable here, but an
// assertion that reads like the data is worth more when it fails.
@(private = "file")
row_text :: proc(q: ^Query, row: []store.Term_ID) -> string {
	sb := strings.builder_make()
	for id, slot in row {
		if slot > 0 {
			strings.write_byte(&sb, ' ')
		}
		if id == store.UNBOUND {
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

// drain runs a prepared query to exhaustion and renders its whole answer
// as one sorted, comma-joined string — "" for no solutions. The result
// is temp-allocated; the per-row strings are not, so they are released
// here.
@(private = "file")
drain :: proc(t: ^testing.T, q: ^Query) -> string {
	rows: [dynamic]string
	defer {
		for row in rows {
			delete(row)
		}
		delete(rows)
	}
	for {
		row, more := query_next(q)
		if !more {
			break
		}
		append(&rows, row_text(q, row))
	}
	testing.expectf(t, query_error(q) == nil, "the store reported an error: %v", query_error(q))
	slice.sort(rows[:])
	return strings.join(rows[:], ", ", context.temp_allocator)
}

// answer_at_head is the ordinary path: query_init opens its own read
// transaction, which reads at HEAD.
@(private = "file")
answer_at_head :: proc(t: ^testing.T, s: ^kvstore.Store, text: string) -> string {
	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)text)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	if !testing.expect(t, parsed, "the query should parse") {
		return ""
	}
	algebra, _ := sparql.translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init(&q, algebra, s, sparql.parser_base(&p)), "query not supported: %s", q.unsupported) {
		return ""
	}
	return drain(t, &q)
}

// answer_as_of is the same query through a transaction carrying a
// horizon — **the only difference between the two procedures**, and the
// whole of what this file exists to assert.
@(private = "file")
answer_as_of :: proc(t: ^testing.T, s: ^kvstore.Store, horizon: store.Epoch, text: string) -> string {
	tx, txn_err := kvstore.txn_begin_as_of(s, horizon)
	if !testing.expectf(t, txn_err == nil, "txn_begin_as_of(%d): %v", u64(horizon), txn_err) {
		return ""
	}
	defer kvstore.txn_abort(&tx)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)text)
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	if !testing.expect(t, parsed, "the query should parse") {
		return ""
	}
	algebra, _ := sparql.translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init_txn(&q, algebra, &tx, sparql.parser_base(&p)), "query not supported: %s", q.unsupported) {
		return ""
	}
	return drain(t, &q)
}

// head_epoch is "the newest epoch right now", read the way an
// application reaches one: a wall-clock time through epoch_at.
//
// Reading the clock *after* the commit returned is what makes this
// deterministic — the newest epoch's sort_time cannot be later than
// that, so epoch_at names it. **A timestamp captured between two
// commits would not be**, and that is worth knowing rather than
// discovering: clock resolution is coarse on some platforms, two
// commits in a test can share a reading, and epoch_at's bound is
// inclusive — so such an assertion would name the later epoch, and
// only on the platform with the coarse clock.
@(private = "file")
head_epoch :: proc(t: ^testing.T, s: ^kvstore.Store) -> store.Epoch {
	epoch, err := kvstore.epoch_at(s, time.now()._nsec)
	testing.expectf(t, err == nil, "epoch_at: %v", err)
	return epoch
}

@(private = "file")
id_of :: proc(t: ^testing.T, s: ^kvstore.Store, iri: string) -> store.Term_ID {
	id, found, err := kvstore.find_term(s, rdf.Term(rdf.IRI(iri)))
	testing.expectf(t, err == nil, "find_term(%s): %v", iri, err)
	testing.expectf(t, found, "%s should be interned by now", iri)
	return id
}

// three_epochs builds the fixture and reports the epoch each edit
// landed at:
//
//	epoch 1  alice -> bob, bob -> carol
//	epoch 2  carol -> dave
//	epoch 3  bob -> carol retracted
//
// The retraction is a `remove` by pattern, which is how the store
// spells "retract everything :bob :knows" — a tombstone append, not an
// erasure, which is why epochs 1 and 2 remain readable afterwards.
@(private = "file")
three_epochs :: proc(t: ^testing.T, s: ^kvstore.Store) -> (first, second, third: store.Epoch, ok: bool) {
	_, parse_err, load_err := kvstore.load_turtle(s, transmute([]byte)string(FIRST_EDIT), EX)
	if !testing.expectf(t, parse_err.message == "" && load_err == nil, "the first edit did not load: %s %v", parse_err.message, load_err) {
		return
	}
	first = head_epoch(t, s)

	_, parse_err2, load_err2 := kvstore.load_turtle(s, transmute([]byte)string(SECOND_EDIT), EX)
	if !testing.expectf(t, parse_err2.message == "" && load_err2 == nil, "the second edit did not load: %s %v", parse_err2.message, load_err2) {
		return
	}
	second = head_epoch(t, s)

	pattern := store.Match_Pattern {
		id_of(t, s, EX + "bob"),
		id_of(t, s, EX + "knows"),
		store.WILDCARD,
		store.DEFAULT_GRAPH,
	}
	removed, remove_err := kvstore.remove(s, pattern)
	if !testing.expectf(t, remove_err == nil, "remove failed: %v", remove_err) {
		return
	}
	if !testing.expectf(t, removed == 1, "the retraction should have taken one quad, took %d", removed) {
		return
	}
	third = head_epoch(t, s)

	// Three edits, three distinct epochs. Without this the tests below
	// could pass by reading one dataset three times.
	if !testing.expectf(t, first < second && second < third, "the edits did not land at distinct epochs: %d %d %d", u64(first), u64(second), u64(third)) {
		return
	}
	return first, second, third, true
}

// The task's own criterion: the same query, through the same
// constructor, at two epochs, giving two different correct answers —
// and neither of them the answer at HEAD.
@(test)
test_a_query_through_an_as_of_transaction_answers_about_that_epoch :: proc(t: ^testing.T) {
	s, open_err := kvstore.open_ephemeral()
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	first, second, _, built := three_epochs(t, s)
	if !built {
		return
	}

	// HEAD. The retraction took the middle edge, so the path is broken
	// and the join has no solutions at all — while both of its endpoints
	// are still in the graph, which is what makes this a fact about the
	// query rather than about an empty dataset.
	at_head := answer_at_head(t, s, JOIN)
	testing.expectf(t, at_head == "", "at HEAD the join should have no solutions, got `%s`", at_head)
	edges_at_head := answer_at_head(t, s, EDGES)
	testing.expectf(
		t,
		edges_at_head == "alice bob, carol dave",
		"HEAD should still hold both surviving edges, got `%s`",
		edges_at_head,
	)

	// As of epoch 2: the path the retraction later broke, plus the one
	// the second edit added.
	at_second := answer_as_of(t, s, second, JOIN)
	testing.expectf(
		t,
		at_second == "alice bob carol, bob carol dave",
		"as of epoch %d the join should have both paths, got `%s`",
		u64(second),
		at_second,
	)

	// As of epoch 1: only the first, because :dave did not exist yet.
	at_first := answer_as_of(t, s, first, JOIN)
	testing.expectf(
		t,
		at_first == "alice bob carol",
		"as of epoch %d the join should have one path, got `%s`",
		u64(first),
		at_first,
	)

	// Said once more as a difference rather than as two equalities: an
	// engine that ignored the horizon would satisfy neither of these.
	testing.expect(t, at_first != at_head, "the epoch-1 answer must differ from HEAD's")
	testing.expect(t, at_second != at_head, "the epoch-2 answer must differ from HEAD's")
	testing.expect(t, at_first != at_second, "the two epochs must answer differently")

	// The far end of the horizon, which the store defines rather than
	// refuses: epoch 0 is never assigned, so it means "before anything".
	// A query at it is a query against the empty dataset — and the
	// single-pattern query is the one to ask, since its HEAD answer is
	// not empty.
	before_anything := answer_as_of(t, s, store.EPOCH_NEVER, EDGES)
	testing.expectf(
		t,
		before_anything == "",
		"as of EPOCH_NEVER the dataset is empty, got `%s`",
		before_anything,
	)
	testing.expect(t, before_anything != edges_at_head, "the empty answer must differ from HEAD's")

	// And the near end: a horizon past the newest epoch is HEAD, not a
	// failure. Same query, same answer as query_init gave.
	past_the_end := answer_as_of(t, s, store.EPOCH_LATEST, EDGES)
	testing.expectf(
		t,
		past_the_end == edges_at_head,
		"a horizon past the newest epoch should read HEAD: got `%s`, HEAD is `%s`",
		past_the_end,
		edges_at_head,
	)
}

// The subtlety worth a test of its own: **the store's dictionary is not
// temporal.** A term interned at a later epoch stays nameable in a read
// of an earlier one (STORE-A-0008 §7 — a term is a name, not a claim),
// so this engine's term binding resolves :dave through an as-of
// transaction that predates it.
//
// That is correct and the answer is still right, because binding
// resolves an ID and the *quads* are what the horizon hides. Asserting
// both halves is what makes this a test rather than a coincidence: if
// binding had instead failed to resolve :dave, the query would return
// the same empty answer for an entirely different reason, and the day
// the dictionary became temporal nothing here would notice.
@(test)
test_a_term_interned_after_the_horizon_is_nameable_but_matches_nothing :: proc(t: ^testing.T) {
	s, open_err := kvstore.open_ephemeral()
	if !testing.expectf(t, open_err == nil, "cannot open the store: %v", open_err) {
		return
	}
	defer kvstore.close(s)

	first, _, _, built := three_epochs(t, s)
	if !built {
		return
	}

	at_head := answer_at_head(t, s, INTO_DAVE)
	testing.expectf(t, at_head == "carol", "at HEAD :dave should have one inbound edge, got `%s`", at_head)

	at_first := answer_as_of(t, s, first, INTO_DAVE)
	testing.expectf(t, at_first == "", "as of epoch %d nothing knows :dave, got `%s`", u64(first), at_first)

	// The other half: the term resolves through that same transaction.
	tx, txn_err := kvstore.txn_begin_as_of(s, first)
	if !testing.expectf(t, txn_err == nil, "txn_begin_as_of: %v", txn_err) {
		return
	}
	defer kvstore.txn_abort(&tx)

	p: sparql.Parser
	sparql.parser_init(&p, transmute([]byte)string(INTO_DAVE))
	defer sparql.parser_destroy(&p)
	_, parsed := sparql.parse(&p)
	if !testing.expect(t, parsed, "the query should parse") {
		return
	}
	algebra, _ := sparql.translate(&p)

	q: Query
	defer query_destroy(&q)
	if !testing.expectf(t, query_init_txn(&q, algebra, &tx, sparql.parser_base(&p)), "query not supported: %s", q.unsupported) {
		return
	}
	_, found := query_find(&q, rdf.Term(rdf.IRI(EX + "dave")))
	testing.expect(t, found, ":dave is a name and names are not dated: it must still resolve through an as-of query")
	testing.expectf(t, query_error(&q) == nil, "the store reported an error: %v", query_error(&q))
}
