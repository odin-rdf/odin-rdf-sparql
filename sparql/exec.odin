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

import rdf "rdf:rdf"
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
	Filter,
	Union,
	Left_Join,
	Minus,
	Join,
	Extend,
	Table,
	Materialized,
}

// Exec_Node is one operator, instantiated for a backend's iterator type.
// Op_Phase is where a two-input operator is in its own little state
// machine. The driver rebuilds its walk on every call, so an operator
// that is halfway through its right side has to remember that itself.
Op_Phase :: enum {
	Need_Left,
	Pull_Right,
}

Exec_Node :: struct($It: typeid) {
	kind:  Exec_Kind,
	input: int, // the (left) input: an index into Exec.nodes; -1 for a leaf
	right: int, // the second input, for the binary operators; -1 otherwise

	// The lowest node index belonging to this node's subtree. Children
	// are built before their parent, so a subtree is a contiguous range
	// — which is how it is reset without recursing (see node_reset).
	subtree_start: int,

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

	// Filter, and the LeftJoin conditions
	conditions: []Expr,

	// Two-input operators
	phase:   Op_Phase,
	matched: bool,
	saved:   []store.Term_ID,

	// Table and Materialized: a stored solution sequence, merged into
	// the current bindings one row at a time. set_slots records what the
	// current row bound so the next one can release it.
	table:      ^Plan_Table,
	rows:       [dynamic][]store.Term_ID,
	row_at:     int,
	set_slots:  [dynamic]int,
	collected:  bool,

	// Extend (BIND)
	bind_slots: []int,
	bind_exprs: []Expr,
}

// Exec is a plan ready to run against one dataset. work is the solution
// row every operator reads and the basic graph patterns write; a row
// handed to a consumer is valid until the next call.
Exec :: struct($D: typeid, $It: typeid) {
	dataset:   ^D,
	nodes:     [dynamic]Exec_Node(It),
	root:      int,
	// The path from the root to the node currently producing, as
	// (node, child) pairs — the child is what makes resuming a two-input
	// operator possible. Sized once at setup: the walk never grows it,
	// so no solution allocates.
	stack:     [dynamic][2]int,
	work:      []store.Term_ID,
	width:     int,
	// One expression context for the whole plan: only one operator
	// evaluates an expression at a time, because a node finishes with a
	// solution before the driver moves on.
	expr:      Expr_Context,
	// Terms the query computed, named by synthetic IDs. Owned here and
	// freed with the execution.
	computed:  [dynamic]rdf.Term,
	// The store's non-interning lookup, used when a computed term turns
	// out to be one the store already holds.
	find:      Term_Finder,
	find_data: rawptr,
	allocator: runtime.Allocator,
}

// exec_init builds the operator tree for a plan. width is the number of
// variable slots the plan was built with (var_slots_count).
exec_init :: proc(
	e: ^Exec($D, $It),
	plan: Plan,
	slots: ^Var_Slots,
	dataset: ^D,
	load: Term_Loader,
	load_data: rawptr,
	find: Term_Finder,
	find_data: rawptr,
	allocator := context.allocator,
) {
	e.allocator = allocator
	e.dataset = dataset
	e.find = find
	e.find_data = find_data
	width := var_slots_count(slots)
	e.width = width
	e.computed = make([dynamic]rdf.Term, allocator)
	expr_context_init(&e.expr, slots, load, load_data, &e.computed, allocator)
	e.work = make([]store.Term_ID, width, allocator)
	for &slot in e.work {
		slot = store.UNBOUND
	}
	e.nodes = make([dynamic]Exec_Node(It), allocator)
	e.root = build_node(e, plan)
	e.stack = make([dynamic][2]int, 0, len(e.nodes) + 1, allocator)
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
		delete(node.saved, e.allocator)
		for stored in node.rows {
			delete(stored, e.allocator)
		}
		delete(node.rows)
		delete(node.set_slots)
		for key in node.seen {
			delete(key, e.allocator)
		}
		delete(node.seen)
	}
	delete(e.nodes)
	delete(e.stack)
	delete(e.work, e.allocator)
	expr_context_destroy(&e.expr)
	for term in e.computed {
		rdf.destroy_term(term, e.allocator)
	}
	delete(e.computed)
	e^ = {}
}

// build_node appends the operator for a plan node and returns its index.
// Children are built first, so a node's input index is always lower than
// its own — the tree is stored bottom-up.
@(private = "file")
build_node :: proc(e: ^Exec($D, $It), plan: Plan) -> int {
	start := len(e.nodes)
	node := Exec_Node(It) {
		input = -1,
		right = -1,
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
	case ^Plan_Filter:
		node.kind = .Filter
		node.input = build_node(e, v.input)
		node.conditions = v.conditions[:]
	case ^Plan_Union:
		node.kind = .Union
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
	case ^Plan_Left_Join:
		node.kind = .Left_Join
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
		node.conditions = v.conditions[:]
		node.saved = make([]store.Term_ID, e.width, e.allocator)
	case ^Plan_Minus:
		node.kind = .Minus
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
	case ^Plan_Join:
		node.kind = .Join
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
		node.saved = make([]store.Term_ID, e.width, e.allocator)
	case ^Plan_Extend:
		node.kind = .Extend
		node.input = build_node(e, v.input)
		node.bind_slots = v.slots[:]
		node.bind_exprs = v.exprs[:]
	case ^Plan_Table:
		node.kind = .Table
		node.table = v
		node.set_slots = make([dynamic]int, e.allocator)
	case ^Plan_Materialized:
		node.kind = .Materialized
		node.input = build_node(e, v.input)
		node.rows = make([dynamic][]store.Term_ID, e.allocator)
		node.set_slots = make([dynamic]int, e.allocator)
	}
	node.subtree_start = start
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
	collect_all(e, MATCH, NEXT, DESTROY)
	return run(e, e.root, MATCH, NEXT, DESTROY)
}

// collect_all runs the sub-plans whose solutions must be gathered before
// the query does — MINUS's right side and a subquery, both of which are
// evaluated independently of the enclosing solution and so cannot be
// probed with its bindings.
//
// It happens once, before any run, and in node order. Nodes are stored
// bottom-up, so a materialized plan nested inside another is collected
// first, and nothing here ever re-enters the driver it is called from.
@(private = "file")
collect_all :: proc(
	e: ^Exec($D, $It),
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) {
	for i in 0 ..< len(e.nodes) {
		if e.nodes[i].kind != .Materialized || e.nodes[i].collected {
			continue
		}
		e.nodes[i].collected = true
		for &slot in e.work {
			slot = store.UNBOUND
		}
		for {
			produced, more := run(e, e.nodes[i].input, MATCH, NEXT, DESTROY)
			if !more {
				break
			}
			append(&e.nodes[i].rows, slice_clone(produced, e.allocator))
		}
		for &slot in e.work {
			slot = store.UNBOUND
		}
	}
}

@(private = "file")
slice_clone :: proc(source: []store.Term_ID, allocator: runtime.Allocator) -> []store.Term_ID {
	out := make([]store.Term_ID, len(source), allocator)
	copy(out, source)
	return out
}

// run is the tree walk: a stack of (node, child) pairs and two phases.
// Pulling, it descends to whichever child the node wants next until it
// reaches something that produces on its own. Delivering, it hands the
// produced solution back up, giving each operator on the path its turn
// to transform it, reject it, or ask its child for another.
//
// It is a loop rather than recursion because a generic procedure taking
// compile-time procedure constants cannot call itself without hanging
// the compiler (SPARQL-T-0011). The shape it forces — an operator says
// which child it wants next instead of calling into one — is what makes
// the two-input operators expressible at all.
@(private = "file")
run :: proc(
	e: ^Exec($D, $It),
	root: int,
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) -> (
	row: []store.Term_ID,
	ok: bool,
) {
	clear(&e.stack)
	at := root
	pulling := true

	for {
		if pulling {
			child := start_child(e, at)
			if child < 0 {
				row, ok = source_next(e, at, MATCH, NEXT, DESTROY)
				pulling = false
				continue
			}
			append(&e.stack, [2]int{at, child})
			at = child
			continue
		}

		if len(e.stack) == 0 {
			return row, ok
		}
		frame := pop(&e.stack)
		parent, from := frame[0], frame[1]
		next_row, next_ok, want := consume(e, parent, from, row, ok, MATCH, NEXT, DESTROY)
		if want >= 0 {
			append(&e.stack, [2]int{parent, want})
			at = want
			pulling = true
			continue
		}
		at = parent
		row, ok = next_row, next_ok
	}
}

// start_child says which input a node wants a solution from, or -1 when
// it produces one itself.
@(private = "file")
start_child :: proc(e: ^Exec($D, $It), at: int) -> int {
	node := &e.nodes[at]
	#partial switch node.kind {
	case .Union, .Left_Join, .Join:
		return node.input if node.phase == .Need_Left else node.right
	case .Materialized:
		// A materialized node has an input, but only so collect_all knows
		// what to run. During the query it is a source: descending into
		// it would evaluate the sub-plan again, correlated — the exact
		// thing materializing it was meant to prevent.
		return -1
	}
	return node.input
}

// source_next produces from a node with no input of its own: a basic
// graph pattern, the unit table, the empty plan, or a stored solution
// sequence (VALUES, or a materialized sub-plan).
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
	case .Table:
		return table_next(e, at)
	case .Materialized:
		return stored_next(e, at)
	}
	return nil, false
}

// table_next and stored_next share a rule that is easy to miss: a stored
// row is *merged* into the current solution, not written over it. Where
// the row and the current bindings disagree the row does not apply at
// all — which is what makes a VALUES block or a materialized sub-plan
// join correctly with whatever is already bound rather than clobbering
// it.
@(private = "file")
table_next :: proc(e: ^Exec($D, $It), at: int) -> (row: []store.Term_ID, ok: bool) {
	node := &e.nodes[at]
	for node.row_at < len(node.table.rows) {
		release_set_slots(e, node)
		source := node.table.rows[node.row_at]
		node.row_at += 1
		if merge_cells(e, node, source[:]) {
			return e.work, true
		}
	}
	release_set_slots(e, node)
	return nil, false
}

@(private = "file")
merge_cells :: proc(e: ^Exec($D, $It), node: ^Exec_Node($It2), cells: []Plan_Table_Cell) -> bool {
	for cell in cells {
		if cell.absent {
			// The cell names a term the store does not hold, so nothing
			// can match it and the row contributes nothing. This is not
			// UNDEF, which contributes a solution that simply leaves the
			// variable unbound.
			release_set_slots(e, node)
			return false
		}
		if !cell.bound || cell.slot < 0 {
			continue
		}
		current := e.work[cell.slot]
		if current != store.UNBOUND {
			if current != cell.id {
				release_set_slots(e, node)
				return false
			}
			continue
		}
		e.work[cell.slot] = cell.id
		append(&node.set_slots, cell.slot)
	}
	return true
}

@(private = "file")
stored_next :: proc(e: ^Exec($D, $It), at: int) -> (row: []store.Term_ID, ok: bool) {
	node := &e.nodes[at]
	for node.row_at < len(node.rows) {
		release_set_slots(e, node)
		stored := node.rows[node.row_at]
		node.row_at += 1
		if merge_row(e, node, stored) {
			return e.work, true
		}
	}
	release_set_slots(e, node)
	return nil, false
}

@(private = "file")
merge_row :: proc(e: ^Exec($D, $It), node: ^Exec_Node($It2), stored: []store.Term_ID) -> bool {
	for value, slot in stored {
		if value == store.UNBOUND {
			continue
		}
		current := e.work[slot]
		if current != store.UNBOUND {
			if current != value {
				release_set_slots(e, node)
				return false
			}
			continue
		}
		e.work[slot] = value
		append(&node.set_slots, slot)
	}
	return true
}

@(private = "file")
release_set_slots :: proc(e: ^Exec($D, $It), node: ^Exec_Node($It2)) {
	for slot in node.set_slots {
		e.work[slot] = store.UNBOUND
	}
	clear(&node.set_slots)
}

// consume gives one operator its turn on the solution a child produced.
// The returned child index is what the operator wants next: -1 to stop
// (emitting the returned row, or exhausted), otherwise the child to pull
// from again.
@(private = "file")
consume :: proc(
	e: ^Exec($D, $It),
	at: int,
	from: int,
	row: []store.Term_ID,
	have: bool,
	$MATCH: proc(dataset: ^D, pattern: store.Match_Pattern) -> It,
	$NEXT: proc(it: ^It) -> (store.Encoded_Quad, bool),
	$DESTROY: proc(it: ^It),
) -> (
	out: []store.Term_ID,
	ok: bool,
	want: int,
) {
	node := &e.nodes[at]
	#partial switch node.kind {
	case .Project:
		if !have {
			return nil, false, -1
		}
		for value, slot in row {
			node.masked[slot] = value if node.keep[slot] else store.UNBOUND
		}
		return node.masked, true, -1

	case .Distinct:
		if !have {
			return nil, false, -1
		}
		key := row_key(row, e.allocator)
		if key in node.seen {
			delete(key, e.allocator)
			return nil, false, node.input
		}
		node.seen[key] = true
		return row, true, -1

	case .Slice:
		if !have {
			return nil, false, -1
		}
		if node.skipped < node.start {
			node.skipped += 1
			return nil, false, node.input
		}
		if node.length >= 0 && node.emitted >= node.length {
			return nil, false, -1
		}
		node.emitted += 1
		return row, true, -1

	case .Filter:
		if !have {
			return nil, false, -1
		}
		if !conditions_hold(e, node.conditions, row) {
			// A condition that errors drops the solution exactly as a
			// false one does — FILTER's error-as-false rule.
			return nil, false, node.input
		}
		return row, true, -1

	case .Extend:
		if !have {
			return nil, false, -1
		}
		e.expr.row = row
		for slot, i in node.bind_slots {
			// Release the previous solution's value first: the slot
			// belongs to this operator, so nothing below it will.
			e.work[slot] = store.UNBOUND
			value := expr_eval(&e.expr, node.bind_exprs[i])
			if id, bindable := bindable_id(e, value); bindable {
				e.work[slot] = id
			}
			expr_context_release(&e.expr)
		}
		return row, true, -1

	case .Union:
		if have {
			return row, true, -1
		}
		if node.phase == .Need_Left {
			// The left side is spent; start the right. Its slots are
			// clean because an exhausted operator releases what it bound.
			node.phase = .Pull_Right
			node_reset(e, node.right, DESTROY)
			return nil, false, node.right
		}
		return nil, false, -1

	case .Left_Join:
		return left_join_step(e, at, from, row, have, DESTROY)

	case .Join:
		return join_step(e, at, from, row, have, DESTROY)

	case .Minus:
		if !have {
			return nil, false, -1
		}
		if minus_excluded(e, node.right, row) {
			return nil, false, node.input
		}
		return row, true, -1
	}
	return row, have, -1
}

// left_join_step is OPTIONAL. For each left solution the right side is
// re-run with the left's bindings already in the row — so it probes
// rather than scans — and a left solution the right cannot extend is
// emitted unextended.
//
// The hoisted conditions belong to the *match*, not to the output: a
// right solution that fails them is not a match at all, so the left
// solution still comes back alone. Putting them in a Filter above the
// join would instead drop the left solution, which is the classic way to
// get OPTIONAL wrong.
@(private = "file")
left_join_step :: proc(
	e: ^Exec($D, $It),
	at: int,
	from: int,
	row: []store.Term_ID,
	have: bool,
	$DESTROY: proc(it: ^It),
) -> (
	out: []store.Term_ID,
	ok: bool,
	want: int,
) {
	node := &e.nodes[at]
	if from == node.input {
		if !have {
			return nil, false, -1
		}
		copy(node.saved, e.work)
		node.matched = false
		node.phase = .Pull_Right
		node_reset(e, node.right, DESTROY)
		return nil, false, node.right
	}
	// from the right side
	if have {
		if !conditions_hold(e, node.conditions, row) {
			return nil, false, node.right
		}
		node.matched = true
		return row, true, -1
	}
	copy(e.work, node.saved)
	node.phase = .Need_Left
	if !node.matched {
		return e.work, true, -1
	}
	return nil, false, node.input
}

// join_step is the general join: the right side re-run per left
// solution, with the left's bindings in place.
@(private = "file")
join_step :: proc(
	e: ^Exec($D, $It),
	at: int,
	from: int,
	row: []store.Term_ID,
	have: bool,
	$DESTROY: proc(it: ^It),
) -> (
	out: []store.Term_ID,
	ok: bool,
	want: int,
) {
	node := &e.nodes[at]
	if from == node.input {
		if !have {
			return nil, false, -1
		}
		copy(node.saved, e.work)
		node.phase = .Pull_Right
		node_reset(e, node.right, DESTROY)
		return nil, false, node.right
	}
	if have {
		return row, true, -1
	}
	copy(e.work, node.saved)
	node.phase = .Need_Left
	return nil, false, node.input
}

// minus_excluded reports whether a solution is removed by MINUS: some
// solution of the right side is compatible with it *and* shares a
// variable. The shared-variable requirement is what makes MINUS differ
// from NOT EXISTS — with disjoint domains every solution is compatible
// with every other, and MINUS would remove everything.
@(private = "file")
minus_excluded :: proc(e: ^Exec($D, $It), right: int, row: []store.Term_ID) -> bool {
	for stored in e.nodes[right].rows {
		shared, compatible := false, true
		for value, slot in stored {
			if value == store.UNBOUND || row[slot] == store.UNBOUND {
				continue
			}
			shared = true
			if value != row[slot] {
				compatible = false
				break
			}
		}
		if shared && compatible {
			return true
		}
	}
	return false
}

@(private = "file")
conditions_hold :: proc(e: ^Exec($D, $It), conditions: []Expr, row: []store.Term_ID) -> bool {
	if len(conditions) == 0 {
		return true
	}
	e.expr.row = row
	for condition in conditions {
		value := expr_eval(&e.expr, condition)
		keep, defined := effective_boolean_value(value)
		expr_context_release(&e.expr)
		if !defined || !keep {
			return false
		}
	}
	return true
}

// bindable_id turns an expression result into something a solution row
// can hold. A value read from the store keeps its ID; a computed one is
// rendered back to a term and named with a synthetic ID (see
// expr_eval.odin). An error or an unbound result binds nothing, which is
// what §18.5's Extend asks for.
@(private = "file")
bindable_id :: proc(e: ^Exec($D, $It), value: Value) -> (id: store.Term_ID, ok: bool) {
	if value.kind == .Error || value.kind == .Unbound {
		return store.UNBOUND, false
	}
	if value.has_source {
		return value.source, true
	}
	term, rendered := value_to_term(value, e.allocator)
	if !rendered {
		return store.UNBOUND, false
	}
	// A computed term the store already holds gets the store's own ID, so
	// a later pattern can match on it — `BIND(?o+1 AS ?z) . ?s ?p ?z` is
	// a real query shape, and a synthetic ID would match nothing. Only a
	// term the data does not contain needs a name of the engine's own.
	if stored, found := e.find(e.find_data, term); found {
		rdf.destroy_term(term, e.allocator)
		return stored, true
	}
	append(&e.computed, term)
	return synthetic_id(len(e.computed) - 1), true
}

// exec_computed_term resolves a synthetic ID to the term it names. A
// consumer materializing a solution asks here before it asks the store,
// because the store has never heard of these terms.
exec_computed_term :: proc(e: ^Exec($D, $It), id: store.Term_ID) -> (term: rdf.Term, ok: bool) {
	if !is_synthetic(id) {
		return nil, false
	}
	index := synthetic_index(id)
	if index < 0 || index >= len(e.computed) {
		return nil, false
	}
	return e.computed[index], true
}

// node_reset returns a subtree to its starting state so it can be run
// again — what a correlated join needs for every left solution. The
// subtree is a contiguous index range because children are built before
// their parents, so this is a loop and not a recursion.
@(private = "file")
node_reset :: proc(e: ^Exec($D, $It), at: int, $DESTROY: proc(it: ^It)) {
	for i in e.nodes[at].subtree_start ..= at {
		node := &e.nodes[i]
		for open, d in node.iter_open {
			if open {
				DESTROY(&node.iters[d])
			}
			node.iter_open[d] = false
		}
		for d in 0 ..< len(node.bound_count) {
			for j in 0 ..< node.bound_count[d] {
				e.work[node.bound_slots[d][j]] = store.UNBOUND
			}
			node.bound_count[d] = 0
		}
		release_set_slots(e, node)
		node.started = false
		node.produced_unit = false
		node.depth = 0
		node.phase = .Need_Left
		node.matched = false
		node.row_at = 0
		node.skipped = 0
		node.emitted = 0
		// Deliberately not reset: a Distinct's seen-set and a
		// Materialized node's collected rows. Both are properties of the
		// whole sub-plan rather than of one run of it, and re-running a
		// correlated side must not forget them.
	}
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
		if i == store.QUAD_G && quad[i] == store.DEFAULT_GRAPH {
			// A variable in the graph position comes only from GRAPH ?g,
			// which ranges over the *named* graphs — the default graph is
			// not one of them and has no name to bind. The match interface
			// cannot say "any named graph" (its wildcard spans both), so
			// the exclusion happens here. Recorded as store evidence for
			// SPARQL-T-0019: an engine that wants named-graph-only
			// matching currently has to over-fetch and filter.
			for j in 0 ..< count {
				e.work[node.bound_slots[depth][j]] = store.UNBOUND
			}
			node.bound_count[depth] = 0
			return false
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
