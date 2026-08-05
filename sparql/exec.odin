// Execution: turning a plan into a stream of solutions (SPARQL-T-0011).
//
// The shape is pull-based. A consumer asks the root operator for the
// next solution; the root asks its input; a basic graph pattern at the
// bottom asks the store. Nothing materializes a result set, and the
// streaming operators allocate nothing per solution — the row buffer,
// the per-pattern iterators, and their bookkeeping are all allocated
// once when execution is set up.
//
// **How a basic graph pattern runs.** Its patterns are visited in join
// order as a chain of index probes. At each depth, whatever the row
// already binds is substituted into the pattern and the store is asked
// to match it; a variable still unbound becomes a wildcard. So
// `?x :p ?y . ?y :q ?z` does not scan `?y :q ?z` and filter — it asks
// the store for exactly the quads whose subject is the `?y` the previous
// depth produced. Backtracking undoes the bindings a depth made and asks
// its iterator for the next quad; when a depth runs out, its iterator is
// closed and the search moves back up.
//
// **How the backend is bound.** The three store operations on the hot
// path — match, match_next, match_destroy — arrive as compile-time
// procedure constants (`$MATCH`, `$NEXT`, `$DESTROY`), so every call is
// direct and inlinable and the executor is monomorphized per backend.
// The engine core therefore names no backend and imports none; the
// instantiation packages `sparql/memstore` and `sparql/kvstore` supply
// the three adapters. See SPARQL-T-0011's status log for why that beat
// the alternatives.
//
// **Why the tree walk is a loop and not recursion.** A generic procedure
// that takes compile-time procedure constants and calls itself sends the
// Odin compiler (dev-2026-07) into unbounded instantiation — it does not
// fail, it hangs. So the walk is explicit: a stack of node indices, and a
// two-phase driver that either asks a node to produce a solution or hands
// a child's solution to its parent. That is a constraint, but not a bad
// shape: an operator here is already a resumable state machine, and the
// driver generalizes to the operators with two inputs that arrive in
// SPARQL-T-0013 — a node says which child it wants next rather than
// calling into it.
package sparql

import "base:runtime"
import "core:strings"

import store "store:store"

// Exec_Kind tags an operator node. The nodes are one struct rather than
// a union of per-operator types because the executor is generic over the
// backend's iterator type: a union of parametric nodes buys nothing over
// a tag when every node already carries the same type parameter.
//
// The tree is held as a flat array with children named by index, not by
// pointer. That is not a micro-optimization — a parametric struct that
// points at itself sends the Odin compiler into unbounded instantiation,
// so an index is the representation that compiles at all.
Exec_Kind :: enum {
	Nothing,
	Unit,
	BGP,
	Project,
	Distinct,
	Slice,
}

// Exec_Node is one operator, instantiated for a backend's iterator type.
Exec_Node :: struct($It: typeid) {
	kind:  Exec_Kind,
	input: int, // index into Exec.nodes; -1 for a leaf

	// Nothing / Unit
	produced_unit: bool,

	// BGP
	bgp:         ^Plan_BGP,
	iters:       []It,
	iter_open:   []bool,
	bound_slots: [][4]int,
	bound_count: []int,
	depth:       int,
	started:     bool,

	// Project: the slots kept, and the row handed out (the working row
	// must not be masked in place — a basic graph pattern below reads it
	// back when it backtracks).
	keep:   []bool,
	masked: []store.Term_ID,

	// Distinct
	seen: map[string]bool,

	// Slice
	start:   int,
	length:  int,
	skipped: int,
	emitted: int,
}

// Exec is a plan ready to run against one dataset. work is the solution
// row every operator reads and the basic graph patterns write; a row
// handed to a consumer is valid until the next call.
Exec :: struct($D: typeid, $It: typeid) {
	dataset:   ^D,
	nodes:     [dynamic]Exec_Node(It),
	root:      int,
	// The path from the root to the node currently producing. Sized once
	// at setup: the walk never grows it, so no solution allocates.
	stack:     [dynamic]int,
	work:      []store.Term_ID,
	width:     int,
	allocator: runtime.Allocator,
}

// exec_init builds the operator tree for a plan. width is the number of
// variable slots the plan was built with (var_slots_count).
exec_init :: proc(
	e: ^Exec($D, $It),
	plan: Plan,
	width: int,
	dataset: ^D,
	allocator := context.allocator,
) {
	e.allocator = allocator
	e.dataset = dataset
	e.width = width
	e.work = make([]store.Term_ID, width, allocator)
	for &slot in e.work {
		slot = store.UNBOUND
	}
	e.nodes = make([dynamic]Exec_Node(It), allocator)
	e.root = build_node(e, plan)
	e.stack = make([dynamic]int, 0, len(e.nodes), allocator)
}

exec_destroy :: proc(e: ^Exec($D, $It), $DESTROY: proc(it: ^It)) {
	for &node in e.nodes {
		for open, i in node.iter_open {
			if open {
				DESTROY(&node.iters[i])
			}
		}
		delete(node.iters, e.allocator)
		delete(node.iter_open, e.allocator)
		delete(node.bound_slots, e.allocator)
		delete(node.bound_count, e.allocator)
		delete(node.keep, e.allocator)
		delete(node.masked, e.allocator)
		for key in node.seen {
			delete(key, e.allocator)
		}
		delete(node.seen)
	}
	delete(e.nodes)
	delete(e.stack)
	delete(e.work, e.allocator)
	e^ = {}
}

// build_node appends the operator for a plan node and returns its index.
// Children are built first, so a node's input index is always lower than
// its own — the tree is stored bottom-up.
@(private = "file")
build_node :: proc(e: ^Exec($D, $It), plan: Plan) -> int {
	node := Exec_Node(It) {
		input = -1,
	}
	switch v in plan {
	case ^Plan_Nothing:
		node.kind = .Nothing
	case ^Plan_Unit:
		node.kind = .Unit
	case ^Plan_BGP:
		node.kind = .BGP
		node.bgp = v
		depth := len(v.order)
		node.iters = make([]It, depth, e.allocator)
		node.iter_open = make([]bool, depth, e.allocator)
		node.bound_slots = make([][4]int, depth, e.allocator)
		node.bound_count = make([]int, depth, e.allocator)
	case ^Plan_Project:
		node.kind = .Project
		node.input = build_node(e, v.input)
		node.keep = make([]bool, e.width, e.allocator)
		for slot in v.slots {
			node.keep[slot] = true
		}
		node.masked = make([]store.Term_ID, e.width, e.allocator)
	case ^Plan_Distinct:
		node.kind = .Distinct
		node.input = build_node(e, v.input)
		node.seen = make(map[string]bool, e.allocator)
	case ^Plan_Slice:
		node.kind = .Slice
		node.input = build_node(e, v.input)
		node.start = v.start if v.start > 0 else 0
		node.length = v.length
	}
	append(&e.nodes, node)
	return len(e.nodes) - 1
}

// exec_next yields the next solution, or ok=false when the plan is
// exhausted. The returned row is indexed by variable slot, holds
// store.UNBOUND where a variable is unbound, and is valid only until the
// next call — a consumer that keeps a solution copies it.
exec_next :: proc(
	e: ^Exec($D, $It),
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) -> (
	row: []store.Term_ID,
	ok: bool,
) {
	clear(&e.stack)
	at := e.root
	// The walk has two phases. Descending, it is looking for the node
	// that actually produces the next solution — the source at the bottom
	// of the chain. Ascending, it carries a produced solution back up,
	// giving each operator on the path its turn to transform, reject, or
	// stop it.
	descending := true

	for {
		if descending {
			if e.nodes[at].input < 0 {
				row, ok = source_next(e, at, MATCH, NEXT, DESTROY)
				descending = false
				continue
			}
			append(&e.stack, at)
			at = e.nodes[at].input
			continue
		}

		if len(e.stack) == 0 {
			return row, ok
		}
		at = pop(&e.stack)
		next_row, next_ok, want_more := consume(e, at, row, ok)
		if want_more {
			append(&e.stack, at)
			at = e.nodes[at].input
			descending = true
			continue
		}
		row, ok = next_row, next_ok
	}
}

// source_next produces from a node with no input: a basic graph pattern,
// the unit table, or the empty plan.
@(private = "file")
source_next :: proc(
	e: ^Exec($D, $It),
	at: int,
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) -> (
	row: []store.Term_ID,
	ok: bool,
) {
	node := &e.nodes[at]
	#partial switch node.kind {
	case .Nothing:
		return nil, false
	case .Unit:
		if node.produced_unit {
			return nil, false
		}
		node.produced_unit = true
		return e.work, true
	case .BGP:
		return bgp_next(e, at, MATCH, NEXT, DESTROY)
	}
	return nil, false
}

// consume gives one operator its turn on the solution its input just
// produced. want_more asks the driver to pull another one — how an
// operator rejects a solution (a duplicate, a row inside the OFFSET)
// without calling back into its input itself.
@(private = "file")
consume :: proc(
	e: ^Exec($D, $It),
	at: int,
	row: []store.Term_ID,
	have: bool,
) -> (
	out: []store.Term_ID,
	ok: bool,
	want_more: bool,
) {
	node := &e.nodes[at]
	#partial switch node.kind {
	case .Project:
		if !have {
			return nil, false, false
		}
		for value, slot in row {
			node.masked[slot] = value if node.keep[slot] else store.UNBOUND
		}
		return node.masked, true, false

	case .Distinct:
		if !have {
			return nil, false, false
		}
		key := row_key(row, e.allocator)
		if key in node.seen {
			delete(key, e.allocator)
			return nil, false, true
		}
		node.seen[key] = true
		return row, true, false

	case .Slice:
		if !have {
			return nil, false, false
		}
		if node.skipped < node.start {
			node.skipped += 1
			return nil, false, true
		}
		if node.length >= 0 && node.emitted >= node.length {
			return nil, false, false
		}
		node.emitted += 1
		return row, true, false
	}
	return row, have, false
}

// bgp_next advances the index-probe chain to the next solution.
//
// The state that survives between calls is the per-depth iterators and
// the bindings they produced, so resuming means asking the deepest
// iterator for its next quad — not restarting the search.
@(private = "file")
bgp_next :: proc(
	e: ^Exec($D, $It),
	at: int,
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) -> (
	row: []store.Term_ID,
	ok: bool,
) {
	node := &e.nodes[at]
	last := len(node.bgp.order) - 1
	if last < 0 {
		// An empty basic graph pattern is the unit table: one solution
		// binding nothing (§18.5).
		if node.started {
			return nil, false
		}
		node.started = true
		return e.work, true
	}

	if !node.started {
		node.started = true
		node.depth = 0
	} else {
		node.depth = last
	}

	for node.depth >= 0 {
		depth := node.depth
		if !node.iter_open[depth] {
			node.iters[depth] = MATCH(e.dataset, probe_pattern(e, node, depth))
			node.iter_open[depth] = true
			node.bound_count[depth] = 0
		}
		// Release what this depth bound for its previous quad before
		// asking for the next one.
		unbind_depth(e, node, depth)
		quad, more := NEXT(&node.iters[depth])
		if !more {
			DESTROY(&node.iters[depth])
			node.iter_open[depth] = false
			node.depth -= 1
			continue
		}
		if !unify_quad(e, node, depth, quad) {
			continue
		}
		if depth == last {
			return e.work, true
		}
		node.depth += 1
	}
	return nil, false
}

// probe_pattern substitutes the row's current bindings into the pattern
// at a depth. An unbound variable becomes a wildcard; a bound one
// narrows the match to exactly its value, which is what makes this an
// index probe rather than a scan and a filter.
@(private = "file")
probe_pattern :: proc(e: ^Exec($D, $It), node: ^Exec_Node(It), depth: int) -> store.Match_Pattern {
	triple := node.bgp.triples[node.bgp.order[depth]]
	pattern: store.Match_Pattern
	for position, i in triple {
		if !plan_ref_is_var(position) {
			pattern[i] = position.id
			continue
		}
		value := e.work[position.slot]
		pattern[i] = store.WILDCARD if value == store.UNBOUND else value
	}
	// UNBOUND is valid in a solution row and in nothing else. One that
	// reached a match pattern would silently become a full scan, so it
	// is an assertion rather than a tolerated case.
	assert(
		pattern[0] != store.UNBOUND &&
		pattern[1] != store.UNBOUND &&
		pattern[2] != store.UNBOUND &&
		pattern[3] != store.UNBOUND,
		"UNBOUND leaked into a match pattern",
	)
	return pattern
}

// unify_quad binds a matched quad's terms into the row, and reports
// whether it is consistent with what the row already holds. A variable
// repeated within one pattern (`?a ?a ?b`) is checked here: the store
// matched a wildcard in both positions, and the second occurrence sees
// the value the first bound.
@(private = "file")
unify_quad :: proc(e: ^Exec($D, $It), node: ^Exec_Node(It), depth: int, quad: store.Encoded_Quad) -> bool {
	triple := node.bgp.triples[node.bgp.order[depth]]
	count := 0
	for position, i in triple {
		if !plan_ref_is_var(position) {
			continue
		}
		current := e.work[position.slot]
		if current != store.UNBOUND {
			if current != quad[i] {
				for j in 0 ..< count {
					e.work[node.bound_slots[depth][j]] = store.UNBOUND
				}
				node.bound_count[depth] = 0
				return false
			}
			continue
		}
		e.work[position.slot] = quad[i]
		node.bound_slots[depth][count] = position.slot
		count += 1
	}
	node.bound_count[depth] = count
	return true
}

@(private = "file")
unbind_depth :: proc(e: ^Exec($D, $It), node: ^Exec_Node(It), depth: int) {
	for i in 0 ..< node.bound_count[depth] {
		e.work[node.bound_slots[depth][i]] = store.UNBOUND
	}
	node.bound_count[depth] = 0
}

// row_key is a solution's identity for DISTINCT: the raw bytes of its
// term IDs. Deduplication is the one place the streaming path has to
// retain something, so it is the one place it allocates — and the key is
// the row's bytes rather than a rendering of its terms, because that is
// what evaluating over IDs buys.
@(private = "file")
row_key :: proc(row: []store.Term_ID, allocator: runtime.Allocator) -> string {
	bytes := transmute([]u8)runtime.Raw_Slice{data = raw_data(row), len = len(row) * size_of(store.Term_ID)}
	return strings.clone(string(bytes), allocator)
}
