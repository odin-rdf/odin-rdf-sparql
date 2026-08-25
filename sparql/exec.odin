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
// **How the store is bound (SPARQL-T-0031).** Directly. The executor
// holds one `record.Snapshot` and asks it; `match_open` and `match_next`
// below are the whole read seam, and they are ordinary procedures.
//
// Until the port this file was generic over a backend — `Exec($D, $It)`,
// with match, match_next and match_destroy threaded through every
// operator as compile-time procedure constants so that the engine core
// could name no backend and the instantiation packages could supply the
// adapters. odin-rdf-record is the one and only store (owner,
// 2026-08-24), which retires the reason rather than re-points it: the
// type parameters, the three constants and the six procedure types that
// carried calls back across the seam are gone, not renamed. What that
// bought is visible at every call site — an EXISTS or a path step is now
// a call to `exec_exists` or `exec_path_expand` where it used to be a
// procedure value routed through a concrete adapter in another package,
// because the compiler could not close a cycle of generic
// instantiations.
//
// **Why the tree walk is still a loop and not recursion.** It was
// written that way because a generic procedure taking compile-time
// procedure constants and calling itself sends the Odin compiler
// (dev-2026-07) into unbounded instantiation. That constraint is gone
// with the generics, and the shape is kept anyway: an operator here is
// already a resumable state machine, the driver hands a child's solution
// to its parent without a stack frame per level, and a plan's depth is
// the query's rather than the machine's. Rewriting it as recursion would
// be a large change that buys nothing.
package sparql

import "base:runtime"
import "core:strings"

import rdf "rdf:rdf"
import record "record:record"

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
	NPS,
	Path,
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
	Graph_Scan,
	Graph_Bind,
	Group,
	Order,
}

// Exec_Node is one operator, instantiated for a backend's iterator type.
// Op_Phase is where a two-input operator is in its own little state
// machine. The driver rebuilds its walk on every call, so an operator
// that is halfway through its right side has to remember that itself.
Op_Phase :: enum {
	Need_Left,
	Pull_Right,
}

// Exec_Node is one operator's state, instantiated for a backend's
// iterator type. Every operator shares the struct — see Exec_Kind for
// why — so most of its fields belong to one kind and are zero in the
// rest; the comments below say which.
Exec_Node :: struct {
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
	iters:       []record.Scan,
	iter_open:   []bool,
	// What each depth bound, so backtracking can release exactly that.
	// A depth binds at most the four quad positions — plus, when the
	// pattern has triple terms in it, the three components of each of
	// its shapes.
	bound_slots: [][]int,
	// The one array every row above is a slice of.
	bound_backing: []int,
	bound_count: []int,
	depth:       int,
	started:     bool,

	// Project: the slots kept, and the row handed out (the working row
	// must not be masked in place — a basic graph pattern below reads it
	// back when it backtracks).
	keep:   []bool,
	masked: []record.Term_ID,

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
	saved:   []record.Term_ID,

	// Table and Materialized: a stored solution sequence, merged into
	// the current bindings one row at a time. set_slots records what the
	// current row bound so the next one can release it.
	table:      ^Plan_Table,
	rows:       [dynamic][]record.Term_ID,
	row_at:     int,
	set_slots:  [dynamic]int,
	collected:  bool,
	// A Materialized node that collects per enclosing solution rather
	// than once, for a blocking operator under GRAPH ?g. See
	// Plan_Materialized.correlated.
	recollect:  bool,

	// Extend (BIND)
	bind_slots: []int,
	bind_exprs: []Expr,

	// Graph_Scan, and Graph_Bind's internal graph slot
	graph_slot: int,
	graph_seen: map[record.Term_ID]bool,

	// Graph_Bind: the query's ?g, and whatever it was bound to when the
	// operator was entered. The second is not the same as reading the slot
	// per solution — this operator writes that slot, so by the second
	// solution the row would be reporting the operator's own last answer.
	graph_var:  int,
	graph_outer: record.Term_ID,

	// Group and Order, the blocking operators. Both fill `rows` with the
	// answers they will hand out and then replay them, so they share the
	// stored-sequence machinery with Materialized — but they *replace*
	// the working row rather than merging into it, because their output
	// is a solution in its own right and not a row to be joined.
	group:       ^Plan_Group,
	groups:      [dynamic]Group_State,
	group_index: map[string]int,
	// Scratch reused per solution: the group key being built, and the
	// key expressions' values, which are needed twice — once to identify
	// the group and once, for a new group, to bind it.
	key_builder: strings.Builder,
	key_values:  []Value,
	key_direct:  []record.Term_ID,

	order:     ^Plan_Order,
	sort_keys: [dynamic][]Sort_Key,

	// NPS: a negated property set in one direction. It shares the basic
	// graph pattern's single-depth iterator machinery, so node_reset closes
	// its cursor and releases its bindings without a case of its own.
	nps:           ^Plan_NPS,

	// Path: §18.4's repeat forms, evaluated as a breadth-first traversal.
	//
	// starts is what the traversal begins from — one endpoint, or every
	// node of the active graph when neither end is fixed. result is the set
	// of nodes reached from the current start, in the order they were
	// found, and it is a list as well as a set because solutions are handed
	// out one at a time across calls. queue is the frontier; expanded keeps
	// a cycle from queueing a node twice, which is the whole of the
	// termination argument.
	path:          ^Plan_Path,
	path_starts:   [dynamic]record.Term_ID,
	path_result:   [dynamic]record.Term_ID,
	path_queue:    [dynamic]record.Term_ID,
	path_step_out: [dynamic]record.Term_ID,
	path_seen:     map[record.Term_ID]bool,
	path_expanded: map[record.Term_ID]bool,
	path_nodes:    map[record.Term_ID]bool,
	path_start:    record.Term_ID,
	path_at:       int,
	start_at:      int,
	queue_at:      int,
	// backward traverses the step from its object end, which is how a
	// pattern with a fixed object is answered without enumerating a graph.
	backward:      bool,
	// check_nodes is §18.4's nodes(G) restriction on the zero-length path,
	// which applies exactly when both endpoints are variables in the
	// pattern. Decided once per run, from the plan and not from the row.
	check_nodes:   bool,
}

// **Path_Expander, Triple_Reader and the rest of the backend-spanning
// procedure types are gone (SPARQL-T-0031).** Six of them existed so
// that this package could name no backend: three hot-path procedure
// constants threaded through every operator, and three procedure values
// for the calls that had to cross back into generic code. The owner's
// decision that odin-rdf-record is the one and only store retires the
// reason, so the executor is concrete and every one of them is an
// ordinary call — `record.snapshot_triple_parts` in place of
// Triple_Reader, `exec_path_expand` called directly in place of
// Path_Expander, `exec_exists` in place of Exists_Runner.
//
// The compiler hang that shaped the old design (dev-2026-07: a generic
// procedure taking compile-time procedure constants cannot be part of a
// call cycle) was a property of the *generic* procedures. Nothing here
// is generic now, so the cycles close: a path's step runs an operator
// tree by calling into the executor, and the executor calls back.

// match_open asks the snapshot for a pattern and returns the scan.
//
// This is the whole of the read seam that survives — record's
// `snapshot_match` narrows to a window over one permutation and
// `range_iter` binds the filters. Origin has no default in record
// (api.md par. 12.5): a query answers about what the dataset says,
// asserted and entailed alike, so `.Any` is stated here once.
//
// The `Range` is named rather than passed straight through so that the
// instrumented build can price it: `range_len` is the window the
// pattern's prefix could narrow to, and what the scan then filters
// residually is invisible from this side of the seam. The plain build
// compiles the two forms identically — see `counting.odin`.
@(private = "file")
match_open :: proc(e: ^Exec, pattern: Match_Pattern) -> record.Scan {
	p := record.Pattern {
		s = pattern[QUAD_S],
		p = pattern[QUAD_P],
		o = pattern[QUAD_O],
		g = pattern[QUAD_G],
	}
	r := record.snapshot_match(e.snapshot, p)
	when SPARQL_COUNT_READS {
		read_counts.match += 1
		read_counts.store_ops += 1
		read_counts.candidates += record.range_len(r)
	}
	return record.range_iter(r, record.Filter{origin = .Any})
}

// match_next yields the next matching fact as the engine's own quad.
//
// **The copy is the decided trade** (SPARQL-T-0031, owner 2026-08-24).
// record hands back a `^Fact` with named components; the executor
// indexes a quad by position, four of those sites dynamically. Copying
// the four ids here costs 16 bytes per matched fact and leaves the
// hottest loop in the package untouched. Reinterpreting record's layout
// would be free and is refused: a field reorder there would compile
// cleanly here and corrupt every result.
//
// A scan borrows its snapshot and carries it, so there is nothing to
// close and no error to report — a read on a resident projection cannot
// fail.
@(private = "file")
match_next :: proc(it: ^record.Scan) -> (quad: Encoded_Quad, ok: bool) {
	when SPARQL_COUNT_READS {
		read_counts.next += 1
		read_counts.store_ops += 1
	}
	id, more := record.scan_next(it)
	if !more {
		return {}, false
	}
	f := record.snapshot_fact(it.snap, id)
	return Encoded_Quad{f.s, f.p, f.o, f.g}, true
}

// exec_resolve is the term-binding bridge: the id a ground term has in
// this snapshot, without interning it. A query must never be a write,
// and record's read side has no way to be one.
@(private)
exec_resolve :: proc(snapshot: record.Snapshot, term: rdf.Term) -> (id: record.Term_ID, found: bool) {
	when SPARQL_COUNT_READS {
		read_counts.find += 1
		read_counts.store_ops += 1
	}
	return record.snapshot_resolve(snapshot, term)
}

// exec_triple_parts takes a stored triple term apart into its three
// component ids, for a triple-term pattern that is not ground.
//
// **This is what SPARQL-T-0019 asked the store for and got.** Against
// odin-rdf-store the engine had to materialize the whole term and look
// each component up again — two round trips through the database for
// something the dictionary already knew. record publishes
// `snapshot_triple_parts`, which reads the components straight out of
// the encoding: no allocation, no decode, no recursion, and one
// question rather than four.
@(private)
exec_triple_parts :: proc(
	snapshot: record.Snapshot,
	id: record.Term_ID,
) -> (
	parts: [3]record.Term_ID,
	ok: bool,
) {
	when SPARQL_COUNT_READS {
		read_counts.triple += 1
		read_counts.store_ops += 1
	}
	return record.snapshot_triple_parts(snapshot, id)
}

// Exec is a plan ready to run against one dataset. work is the solution
// row every operator reads and the basic graph patterns write; a row
// handed to a consumer is valid until the next call.
Exec :: struct {
	// The one snapshot every read goes through. A query is defined
	// against one dataset (SPARQL-T-0024), and on record a snapshot is
	// what a dataset *is* — epoch-pinned, refcounted, and unaffected by
	// whatever the writer does next.
	snapshot:  record.Snapshot,
	nodes:     [dynamic]Exec_Node,
	root:      int,
	// The path from the root to the node currently producing, as
	// (node, child) pairs — the child is what makes resuming a two-input
	// operator possible. Sized once at setup: the walk never grows it,
	// so no solution allocates.
	stack:     [dynamic][2]int,
	work:      []record.Term_ID,
	width:     int,
	// One expression context for the whole plan: only one operator
	// evaluates an expression at a time, because a node finishes with a
	// solution before the driver moves on.
	expr:      Expr_Context,
	// Terms the query computed, named by synthetic IDs. Owned here and
	// freed with the execution.
	//
	// computed_index is what keeps a synthetic ID a *name* rather than a
	// serial number: two solutions that compute the same term get the
	// same ID. Without it, `SELECT DISTINCT ?x { VALUES ?x { 1 1 } }`
	// over a store that has never seen 1 would answer twice, because
	// deduplication compares the row's IDs and the two 1s would not be
	// the same one.
	computed:       [dynamic]rdf.Term,
	computed_index: map[string]int,
	computed_key:   strings.Builder,
	// The root node of each EXISTS sub-plan, in the order plan building
	// registered them. They live in the same node array as the main plan
	// — a sub-plan is an ordinary operator tree, just one nothing pulls
	// from until an expression asks.
	exists_roots: [dynamic]int,
	allocator: runtime.Allocator,
}

// exec_init builds the operator tree for a plan. width is the number of
// variable slots the plan was built with (var_slots_count).
exec_init :: proc(
	e: ^Exec,
	plan: Plan,
	slots: ^Var_Slots,
	snapshot: record.Snapshot,
	exists_plans: []Plan,
	exists_nodes: []^Exists_Expr,
	allocator := context.allocator,
) {
	e.allocator = allocator
	e.snapshot = snapshot
	width := var_slots_count(slots)
	e.width = width
	e.computed = make([dynamic]rdf.Term, allocator)
	e.computed_index = make(map[string]int, allocator)
	e.computed_key = strings.builder_make(allocator)
	expr_context_init(&e.expr, slots, snapshot, &e.computed, allocator)
	e.work = make([]record.Term_ID, width, allocator)
	for &slot in e.work {
		slot = UNBOUND
	}
	e.nodes = make([dynamic]Exec_Node, allocator)
	e.root = build_node(e, plan)
	e.exists_roots = make([dynamic]int, allocator)
	for sub in exists_plans {
		append(&e.exists_roots, build_node(e, sub))
	}
	// The walk never needs more frames than there are nodes, and a
	// nested EXISTS walk shares the stack with the walk that asked for
	// it — hence the doubling rather than a fresh allocation per call.
	e.stack = make([dynamic][2]int, 0, 2 * len(e.nodes) + 2, allocator)
	// The self-pointer an expression's EXISTS runs back through. It is
	// why an Exec must not be copied after exec_init — already true (the
	// operators hold indices into its own arrays), and now stated once
	// more.
	e.expr.exec = e
	e.expr.exists_nodes = exists_nodes
}

// exec_set_base gives the execution the query's base IRI. IRI() is the
// only function that needs it, and it needs it at evaluation time
// rather than at translation — the reference it resolves is a value the
// query computed, not one the parser saw.
exec_set_base :: proc(e: ^Exec, base: string) {
	expr_context_set_base(&e.expr, base)
}

// exec_destroy frees the operator tree, closes every iterator a run left
// open, and releases the terms the query computed. It does not free the
// plan the tree was built from: the plan is the caller's, and outlives
// the execution by exactly the length of a plan_destroy call.
exec_destroy :: proc(e: ^Exec) {
	// The blocking operators own group tables and sort keys, which the
	// shared loop below cannot free without knowing which node kind they
	// belong to.
	for i in 0 ..< len(e.nodes) {
		blocking_reset(e, i)
	}
	for &node in e.nodes {
		delete(node.groups)
		delete(node.group_index)
		delete(node.sort_keys)
		delete(node.key_values, e.allocator)
		delete(node.key_direct, e.allocator)
		strings.builder_destroy(&node.key_builder)
	}
	for &node in e.nodes {
		// No iterator to close: a record.Scan is a view over a
		// permutation window and holds nothing — where a kvstore cursor
		// had to be closed before its transaction ended, this one is
		// released by forgetting it. `iter_open` survives because the
		// executor still needs to know whether a depth has been started.
		delete(node.iters, e.allocator)
		delete(node.iter_open, e.allocator)
		delete(node.bound_backing, e.allocator)
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
		delete(node.graph_seen)
		delete(node.path_starts)
		delete(node.path_result)
		delete(node.path_queue)
		delete(node.path_step_out)
		delete(node.path_seen)
		delete(node.path_expanded)
		delete(node.path_nodes)
	}
	delete(e.nodes)
	delete(e.exists_roots)
	delete(e.stack)
	delete(e.work, e.allocator)
	expr_context_destroy(&e.expr)
	for term in e.computed {
		rdf.destroy_term(term, e.allocator)
	}
	delete(e.computed)
	for key in e.computed_index {
		delete(key, e.allocator)
	}
	delete(e.computed_index)
	strings.builder_destroy(&e.computed_key)
	e^ = {}
}

// build_node appends the operator for a plan node and returns its index.
// Children are built first, so a node's input index is always lower than
// its own — the tree is stored bottom-up.
@(private = "file")
build_node :: proc(e: ^Exec, plan: Plan) -> int {
	start := len(e.nodes)
	node := Exec_Node {
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
		node.iters = make([]record.Scan, depth, e.allocator)
		node.iter_open = make([]bool, depth, e.allocator)
		node.bound_count = make([]int, depth, e.allocator)
		bind_bound_slots(e, &node, depth, 4 + 3 * len(v.shapes))
	case ^Plan_NPS:
		node.kind = .NPS
		node.nps = v
		node.iters = make([]record.Scan, 1, e.allocator)
		node.iter_open = make([]bool, 1, e.allocator)
		node.bound_count = make([]int, 1, e.allocator)
		bind_bound_slots(e, &node, 1, 4)
	case ^Plan_Path:
		node.kind = .Path
		node.path = v
		// The step is built as a child so that node_reset covers it and so
		// that its nodes are laid out below this one, but it is not an
		// input: start_child never descends into it, and the traversal runs
		// it itself, one frontier node at a time.
		node.input = build_node(e, v.step)
		node.set_slots = make([dynamic]int, e.allocator)
		node.path_starts = make([dynamic]record.Term_ID, e.allocator)
		node.path_result = make([dynamic]record.Term_ID, e.allocator)
		node.path_queue = make([dynamic]record.Term_ID, e.allocator)
		node.path_step_out = make([dynamic]record.Term_ID, e.allocator)
		node.path_seen = make(map[record.Term_ID]bool, e.allocator)
		node.path_expanded = make(map[record.Term_ID]bool, e.allocator)
		node.path_nodes = make(map[record.Term_ID]bool, e.allocator)
		// A ground endpoint the store does not hold is still an endpoint:
		// the zero-length path binds it to itself whether or not the data
		// has ever mentioned it. So it gets a name of the engine's own,
		// exactly as a VALUES cell naming an unknown term does — and, like
		// that name, it must never reach a match pattern, which is what the
		// synthetic check in the traversal is for.
		for end in ([2]^Plan_Path_End{&v.subject, &v.object}) {
			if !end.absent || end.term == nil {
				continue
			}
			end.id = computed_id(e, rdf.clone_term(end.term, e.allocator))
			end.absent = false
		}
	case ^Plan_Project:
		node.kind = .Project
		node.input = build_node(e, v.input)
		node.keep = make([]bool, e.width, e.allocator)
		for slot in v.slots {
			node.keep[slot] = true
		}
		node.masked = make([]record.Term_ID, e.width, e.allocator)
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
		// The bindings in force when the union starts, so the right branch
		// begins where the left one did. See start_child.
		node.saved = make([]record.Term_ID, e.width, e.allocator)
	case ^Plan_Left_Join:
		node.kind = .Left_Join
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
		node.conditions = v.conditions[:]
		node.saved = make([]record.Term_ID, e.width, e.allocator)
	case ^Plan_Minus:
		node.kind = .Minus
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
	case ^Plan_Join:
		node.kind = .Join
		node.input = build_node(e, v.left)
		node.right = build_node(e, v.right)
		node.saved = make([]record.Term_ID, e.width, e.allocator)
	case ^Plan_Extend:
		node.kind = .Extend
		node.input = build_node(e, v.input)
		node.bind_slots = v.slots[:]
		node.bind_exprs = v.exprs[:]
	case ^Plan_Table:
		node.kind = .Table
		node.table = v
		node.set_slots = make([dynamic]int, e.allocator)
		// A cell naming a term the store does not hold still binds it —
		// VALUES supplies bindings, and a binding to a term the data
		// lacks simply matches nothing later. So the term gets a name of
		// the engine's own, exactly as a computed BIND value does. The
		// plan is resolved in place, which is safe because a plan backs
		// one execution.
		for &row in v.rows {
			for &cell in row {
				if !cell.absent || cell.term == nil {
					continue
				}
				cell.id = computed_id(e, rdf.clone_term(cell.term, e.allocator))
				cell.bound = true
				cell.absent = false
			}
		}
	case ^Plan_Materialized:
		node.kind = .Materialized
		node.input = build_node(e, v.input)
		node.recollect = v.correlated
		node.rows = make([dynamic][]record.Term_ID, e.allocator)
		node.set_slots = make([dynamic]int, e.allocator)
	case ^Plan_Group:
		node.kind = .Group
		node.group = v
		node.input = build_node(e, v.input)
		node.groups = make([dynamic]Group_State, e.allocator)
		node.group_index = make(map[string]int, e.allocator)
		node.rows = make([dynamic][]record.Term_ID, e.allocator)
		node.key_builder = strings.builder_make(e.allocator)
		node.key_values = make([]Value, len(v.keys), e.allocator)
		node.key_direct = make([]record.Term_ID, len(v.keys), e.allocator)
		// The bindings in force when the group starts collecting. A
		// group's own solution is its keys and its aggregates; everything
		// else in the answer is whatever was already bound around it, and
		// snapshotting is how that survives an input that binds and
		// unbinds its way through a million solutions.
		node.saved = make([]record.Term_ID, e.width, e.allocator)
	case ^Plan_Order:
		node.kind = .Order
		node.order = v
		node.input = build_node(e, v.input)
		node.rows = make([dynamic][]record.Term_ID, e.allocator)
		node.sort_keys = make([dynamic][]Sort_Key, e.allocator)
	case ^Plan_Graph_Scan:
		node.kind = .Graph_Scan
		node.graph_slot = v.slot
		node.graph_seen = make(map[record.Term_ID]bool, e.allocator)
		node.iters = make([]record.Scan, 1, e.allocator)
		node.iter_open = make([]bool, 1, e.allocator)
		node.bound_count = make([]int, 1, e.allocator)
		bind_bound_slots(e, &node, 1, 4)
		node.set_slots = make([dynamic]int, e.allocator)
	case ^Plan_Graph_Bind:
		node.kind = .Graph_Bind
		node.graph_slot = v.graph
		node.graph_var = v.slot
		node.input = build_node(e, v.input)
		node.set_slots = make([dynamic]int, e.allocator)
	}
	node.subtree_start = start
	append(&e.nodes, node)
	return len(e.nodes) - 1
}

// bind_bound_slots allocates the per-depth record of what a matching
// operator bound: one row of `width` slot indices per depth, in one
// backing array so releasing a depth is a walk over contiguous memory.
@(private = "file")
bind_bound_slots :: proc(e: ^Exec, node: ^Exec_Node, depth: int, width: int) {
	node.bound_backing = make([]int, depth * width, e.allocator)
	node.bound_slots = make([][]int, depth, e.allocator)
	for d in 0 ..< depth {
		node.bound_slots[d] = node.bound_backing[d * width:][:width]
	}
}

// exec_next yields the next solution, or ok=false when the plan is
// exhausted. The returned row is indexed by variable slot, holds
// UNBOUND where a variable is unbound, and is valid only until the
// next call — a consumer that keeps a solution copies it.
exec_next :: proc(
	e: ^Exec,
) -> (
	row: []record.Term_ID,
	ok: bool,
) {
	collect_all(e)
	return run(e, e.root)
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
	e: ^Exec,
) {
	for i in 0 ..< len(e.nodes) {
		if e.nodes[i].kind != .Materialized || e.nodes[i].collected || e.nodes[i].recollect {
			continue
		}
		e.nodes[i].collected = true
		for &slot in e.work {
			slot = UNBOUND
		}
		for {
			produced, more := run(e, e.nodes[i].input)
			if !more {
				break
			}
			append(&e.nodes[i].rows, slice_clone(produced, e.allocator))
		}
		for &slot in e.work {
			slot = UNBOUND
		}
	}
}

@(private = "file")
slice_clone :: proc(source: []record.Term_ID, allocator: runtime.Allocator) -> []record.Term_ID {
	out := make([]record.Term_ID, len(source), allocator)
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
	e: ^Exec,
	root: int,
) -> (
	row: []record.Term_ID,
	ok: bool,
) {
	// The walk is re-entrant: an EXISTS evaluated mid-solution runs its
	// own sub-plan on this same stack, above whatever the outer walk has
	// pushed. So the base is where this walk started, not zero.
	base := len(e.stack)
	at := root
	pulling := true

	for {
		if pulling {
			child := start_child(e, at)
			if child < 0 {
				row, ok = source_next(e, at)
				pulling = false
				continue
			}
			append(&e.stack, [2]int{at, child})
			at = child
			continue
		}

		if len(e.stack) == base {
			return row, ok
		}
		frame := pop(&e.stack)
		parent, from := frame[0], frame[1]
		next_row, next_ok, want := consume(e, parent, from, row, ok)
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
start_child :: proc(e: ^Exec, at: int) -> int {
	node := &e.nodes[at]
	#partial switch node.kind {
	case .Path:
		// A path node has an input — its step sub-plan — but the driver
		// must never pull from it. The step is run inside the traversal,
		// once per frontier node, with the traversal's own bindings in
		// place; descending into it here would hand its raw solutions to
		// whatever asked for a path.
		return -1
	case .Union:
		if node.phase != .Need_Left {
			return node.right
		}
		// The bindings the union runs inside. Both branches have to see
		// them and only them, and the left branch may leave the working
		// row in any state at all: a blocking operator replays a whole row
		// over it, and a LIMIT can stop the branch without its operators
		// ever being asked to release what they bound. So the state is
		// snapshotted here and restored when the right branch starts.
		if !node.started {
			node.started = true
			copy(node.saved, e.work)
		}
		return node.input
	case .Left_Join, .Join:
		return node.input if node.phase == .Need_Left else node.right
	case .Materialized:
		// A materialized node has an input, but only so collect_all knows
		// what to run. During the query it is a source: descending into
		// it would evaluate the sub-plan again, correlated — the exact
		// thing materializing it was meant to prevent.
		//
		// The correlated one is the exception, and collects here instead:
		// its whole point is to be re-evaluated inside the enclosing
		// solution, which is only knowable once there is one.
		if !node.recollect || node.collected {
			return -1
		}
	case .Graph_Bind:
		// Entering the operator hands the enclosing ?g, if there is one,
		// down to the graph position the body matches in: §18.5's join
		// with Ω(?g→i) done before the scan instead of after it, which is
		// what keeps `?d :graph ?g . GRAPH ?g { … }` an index probe.
		// Nothing is pushed down when ?g is unbound, and then the body
		// enumerates and the join happens on the way out.
		if !node.started {
			node.started = true
			node.graph_outer = e.work[node.graph_var]
			e.work[node.graph_slot] = node.graph_outer
		}
		// Whatever the last solution bound ?g to is this operator's own
		// doing, and the body about to run must not see it.
		release_set_slots(e, node)
	case .Group, .Order:
		// A blocking operator is an input-driven node until its input runs
		// out and a source afterwards. Collecting lazily, here, rather
		// than up front in collect_all is what lets one be re-run: a GROUP
		// BY under GRAPH ?g has to answer once per graph, and a node whose
		// answers were computed before the query started could not.
		if node.collected {
			return -1
		}
		if !node.started {
			node.started = true
			if node.kind == .Group {
				copy(node.saved, e.work)
			}
		}
	}
	return node.input
}

// source_next produces from a node with no input of its own: a basic
// graph pattern, the unit table, the empty plan, or a stored solution
// sequence (VALUES, or a materialized sub-plan).
@(private = "file")
source_next :: proc(
	e: ^Exec,
	at: int,
) -> (
	row: []record.Term_ID,
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
		return bgp_next(e, at)
	case .NPS:
		return nps_next(e, at)
	case .Path:
		return path_next(e, at)
	case .Table:
		return table_next(e, at)
	case .Materialized:
		return stored_next(e, at)
	case .Graph_Scan:
		return graph_scan_next(e, at)
	case .Group, .Order:
		return replay_next(e, at)
	}
	return nil, false
}

// replay_next hands out one of a blocking operator's collected answers.
// Unlike stored_next it *replaces* the working row rather than merging
// into it: a group's or a sorted sequence's solution is complete in
// itself, and the row it was built from is gone.
@(private = "file")
replay_next :: proc(e: ^Exec, at: int) -> (row: []record.Term_ID, ok: bool) {
	node := &e.nodes[at]
	if node.row_at >= len(node.rows) {
		return nil, false
	}
	copy(e.work, node.rows[node.row_at])
	node.row_at += 1
	return e.work, true
}

// graph_scan_next yields each named graph once. It reads every quad to
// do it, which is the cost of the store having no way to be asked what
// graphs it holds; the seen-set keeps the answer a set.
@(private = "file")
graph_scan_next :: proc(
	e: ^Exec,
	at: int,
) -> (
	row: []record.Term_ID,
	ok: bool,
) {
	node := &e.nodes[at]
	if !node.iter_open[0] {
		node.iters[0] = match_open(e, MATCH_ALL)
		node.iter_open[0] = true
	}
	for {
		release_set_slots(e, node)
		quad, more := match_next(&node.iters[0])
		if !more {
			node.iter_open[0] = false
			return nil, false
		}
		graph := quad[QUAD_G]
		// **A fact's G, not a pattern's**, so the default graph is the
		// stored 0 and never DEFAULT_GRAPH (SPARQL-T-0031 par. 4). The
		// same bits are also UNBOUND, which is why this is a named
		// constant: skipping the default graph here is what keeps a row
		// slot from being "bound" to the value that means unbound, and
		// GRAPH ?g ranges over the named graphs alone in any case.
		if graph == STORED_DEFAULT_GRAPH || graph in node.graph_seen {
			continue
		}
		node.graph_seen[graph] = true
		// The slot may already be bound — by a VALUES row, or by an
		// enclosing solution — in which case this graph only counts if it
		// agrees.
		current := e.work[node.graph_slot]
		if current != UNBOUND {
			if current != graph {
				continue
			}
			return e.work, true
		}
		e.work[node.graph_slot] = graph
		append(&node.set_slots, node.graph_slot)
		return e.work, true
	}
}

// table_next and stored_next share a rule that is easy to miss: a stored
// row is *merged* into the current solution, not written over it. Where
// the row and the current bindings disagree the row does not apply at
// all — which is what makes a VALUES block or a materialized sub-plan
// join correctly with whatever is already bound rather than clobbering
// it.
@(private = "file")
table_next :: proc(e: ^Exec, at: int) -> (row: []record.Term_ID, ok: bool) {
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
merge_cells :: proc(e: ^Exec, node: ^Exec_Node, cells: []Plan_Table_Cell) -> bool {
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
		if current != UNBOUND {
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
stored_next :: proc(e: ^Exec, at: int) -> (row: []record.Term_ID, ok: bool) {
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
merge_row :: proc(e: ^Exec, node: ^Exec_Node, stored: []record.Term_ID) -> bool {
	for value, slot in stored {
		if value == UNBOUND {
			continue
		}
		current := e.work[slot]
		if current != UNBOUND {
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
release_set_slots :: proc(e: ^Exec, node: ^Exec_Node) {
	for slot in node.set_slots {
		e.work[slot] = UNBOUND
	}
	clear(&node.set_slots)
}

// consume gives one operator its turn on the solution a child produced.
// The returned child index is what the operator wants next: -1 to stop
// (emitting the returned row, or exhausted), otherwise the child to pull
// from again.
@(private = "file")
consume :: proc(
	e: ^Exec,
	at: int,
	from: int,
	row: []record.Term_ID,
	have: bool,
) -> (
	out: []record.Term_ID,
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
			node.masked[slot] = value if node.keep[slot] else UNBOUND
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
		expr_context_new_solution(&e.expr)
		for slot, i in node.bind_slots {
			// Release the previous solution's value first: the slot
			// belongs to this operator, so nothing below it will.
			e.work[slot] = UNBOUND
			value := expr_eval(&e.expr, node.bind_exprs[i])
			if id, bindable := bindable_id(e, value); bindable {
				e.work[slot] = id
			}
			// A projection below hands out a masked *copy* of the working
			// row, so a binding written only into the working row would
			// not be in the solution this operator returns — which is what
			// `{ SELECT ?v {…} } BIND(… AS ?i)` is: an Extend directly over
			// a subquery. Both have to carry it: the copy is what the
			// consumer reads, the working row is what an enclosing pattern
			// probes with and what the next binding here reads.
			if raw_data(row) != raw_data(e.work) && slot < len(row) {
				row[slot] = e.work[slot]
			}
			expr_context_release(&e.expr)
		}
		return row, true, -1

	case .Union:
		if have {
			return row, true, -1
		}
		if node.phase == .Need_Left {
			// The left side is spent; start the right, on the bindings the
			// union began with rather than on whatever the left branch
			// left behind (see start_child).
			node.phase = .Pull_Right
			node_reset(e, node.input)
			copy(e.work, node.saved)
			node_reset(e, node.right)
			return nil, false, node.right
		}
		return nil, false, -1

	case .Left_Join:
		return left_join_step(e, at, from, row, have)

	case .Join:
		return join_step(e, at, from, row, have)

	case .Materialized:
		// Only the correlated one reaches here; the ordinary one is a
		// source and never pulls from its input during the query.
		if have {
			append(&node.rows, slice_clone(row, e.allocator))
			return nil, false, node.input
		}
		node.collected = true
		out, ok = stored_next(e, at)
		return out, ok, -1

	case .Group:
		if have {
			group_accumulate(e, at, row)
			return nil, false, node.input
		}
		group_finish(e, at)
		node.collected = true
		out, ok = replay_next(e, at)
		return out, ok, -1

	case .Order:
		if have {
			order_collect(e, at, row)
			return nil, false, node.input
		}
		order_finish(e, at)
		node.collected = true
		out, ok = replay_next(e, at)
		return out, ok, -1

	case .Minus:
		if !have {
			return nil, false, -1
		}
		if minus_excluded(e, node.right, row) {
			return nil, false, node.input
		}
		return row, true, -1

	case .Graph_Bind:
		// §18.5's Join(eval(D(D[i]), P), Ω(?g→i)), one solution at a time.
		if !have {
			return nil, false, -1
		}
		if node.graph_outer != UNBOUND {
			// ?g came in bound, so the graph was pushed down and every
			// solution the body produced is already in it.
			return row, true, -1
		}
		graph := row[node.graph_slot]
		found := row[node.graph_var]
		if found == UNBOUND {
			// The body did not bind ?g, so the join binds it. A body that
			// bound no graph either — a solution reached without matching
			// a triple — leaves it unbound, which is what writing UNBOUND
			// says.
			row[node.graph_var] = graph
			if graph != UNBOUND {
				e.work[node.graph_var] = graph
				append(&node.set_slots, node.graph_var)
			}
			return row, true, -1
		}
		if graph != UNBOUND && found != graph {
			// The body bound ?g from a subject, predicate or object, and
			// it is not the graph the solution was found in. Ω(?g→i) and
			// the solution are incompatible, so there is no join.
			return nil, false, node.input
		}
		return row, true, -1
	}
	return row, have, -1
}

// group_accumulate folds one solution into its group, creating the group
// on first sight (§18.5.1's Group and Aggregation, run as one pass).
//
// The key is the concatenation of the grouping expressions' values,
// written as the RDF terms they would bind — see value_key for why term
// identity and not value equality decides the partition.
@(private = "file")
group_accumulate :: proc(e: ^Exec, at: int, row: []record.Term_ID) {
	node := &e.nodes[at]
	plan := node.group
	e.expr.row = row
	expr_context_new_solution(&e.expr)

	strings.builder_reset(&node.key_builder)
	for key, i in plan.keys {
		if key.source >= 0 {
			// A bare variable never leaves the ID space.
			node.key_direct[i] = row[key.source]
			id_key(&node.key_builder, node.key_direct[i])
			continue
		}
		node.key_values[i] = expr_eval(&e.expr, key.expr)
		value_key(&node.key_builder, node.key_values[i])
	}
	index, found := node.group_index[strings.to_string(node.key_builder)]
	if !found {
		index = len(node.groups)
		state := Group_State {
			key_ids = make([]record.Term_ID, len(plan.keys), e.allocator),
			accums  = make([]Agg_Accum, len(plan.aggregates), e.allocator),
		}
		for key, i in plan.keys {
			state.key_ids[i] = UNBOUND
			if key.source >= 0 {
				state.key_ids[i] = node.key_direct[i]
			} else if id, bindable := bindable_id(e, node.key_values[i]); bindable {
				state.key_ids[i] = id
			}
		}
		for aggregate, i in plan.aggregates {
			agg_accum_init(&state.accums[i], aggregate.agg, e.allocator)
		}
		append(&node.groups, state)
		node.group_index[strings.clone(strings.to_string(node.key_builder), e.allocator)] = index
	}

	state := &node.groups[index]
	for aggregate, i in plan.aggregates {
		if aggregate.agg.star {
			agg_accum_row(&state.accums[i], row)
			continue
		}
		agg_accum_value(&state.accums[i], expr_eval(&e.expr, aggregate.agg.expr))
	}
	expr_context_release(&e.expr)
}

// group_finish turns the accumulators into the solutions the operator
// will hand out, and then releases them.
@(private = "file")
group_finish :: proc(e: ^Exec, at: int) {
	node := &e.nodes[at]
	plan := node.group
	if len(plan.keys) == 0 && len(node.groups) == 0 {
		// §18.2.4.1's implicit grouping: an aggregate with no GROUP BY
		// puts every solution in one group, and that group is there even
		// when no solution was. COUNT over a pattern that matches nothing
		// is 0, not no answer at all.
		state := Group_State {
			key_ids = make([]record.Term_ID, 0, e.allocator),
			accums  = make([]Agg_Accum, len(plan.aggregates), e.allocator),
		}
		for aggregate, i in plan.aggregates {
			agg_accum_init(&state.accums[i], aggregate.agg, e.allocator)
		}
		append(&node.groups, state)
	}
	for &state in node.groups {
		out := slice_clone(node.saved, e.allocator)
		for key, i in plan.keys {
			if key.slot >= 0 {
				out[key.slot] = state.key_ids[i]
			}
		}
		for aggregate, i in plan.aggregates {
			value, owned := agg_accum_value_of(&state.accums[i], e.allocator)
			if id, bindable := bindable_id(e, value); bindable {
				out[aggregate.slot] = id
			}
			if owned != "" {
				delete(owned, e.allocator)
			}
		}
		append(&node.rows, out)
	}
	group_release(e, at)
}

// group_release frees the accumulators and the group table. The answers
// have already been rendered into rows, and an accumulator holds copies
// of terms that nothing needs once they have.
@(private = "file")
group_release :: proc(e: ^Exec, at: int) {
	node := &e.nodes[at]
	for &state in node.groups {
		for &accum in state.accums {
			agg_accum_destroy(&accum)
		}
		delete(state.key_ids, e.allocator)
		delete(state.accums, e.allocator)
	}
	clear(&node.groups)
	for key in node.group_index {
		delete(key, e.allocator)
	}
	clear(&node.group_index)
}

// order_collect keeps one solution and the sort keys it will be ordered
// by. The keys are materialized here, once per solution, rather than in
// the comparator — a sort asks about a row O(log n) times, and an
// expression evaluated that often would be the cost of the operator.
@(private = "file")
order_collect :: proc(e: ^Exec, at: int, row: []record.Term_ID) {
	node := &e.nodes[at]
	plan := node.order
	append(&node.rows, slice_clone(row, e.allocator))
	keys := make([]Sort_Key, len(plan.conditions), e.allocator)
	e.expr.row = row
	expr_context_new_solution(&e.expr)
	for condition, i in plan.conditions {
		keys[i] = sort_key_of(e, expr_eval(&e.expr, condition.expr))
	}
	expr_context_release(&e.expr)
	append(&node.sort_keys, keys)
}

// sort_key_of copies what a key needs to outlive the solution it came
// from: a backend's materialized term may only be valid until the next
// one, and the sort holds every row's keys at once. An expression that
// errored sorts with the unbound (see order.odin).
@(private = "file")
sort_key_of :: proc(e: ^Exec, value: Value) -> Sort_Key {
	if value.kind == .Error || value.kind == .Unbound {
		return Sort_Key{value = UNBOUND_VALUE}
	}
	term, rendered := value_to_term(value, e.allocator)
	if !rendered {
		return Sort_Key{value = UNBOUND_VALUE}
	}
	return Sort_Key{value = value_of(term), term = term}
}

@(private = "file")
order_finish :: proc(e: ^Exec, at: int) {
	node := &e.nodes[at]
	count := len(node.rows)
	if count > 1 {
		perm := make([]int, count, e.allocator)
		scratch := make([]int, count, e.allocator)
		sorted := make([][]record.Term_ID, count, e.allocator)
		defer delete(perm, e.allocator)
		defer delete(scratch, e.allocator)
		defer delete(sorted, e.allocator)
		for i in 0 ..< count {
			perm[i] = i
		}
		order_sort(perm, scratch, node.sort_keys[:], node.order.conditions[:])
		for index, i in perm {
			sorted[i] = node.rows[index]
		}
		for i in 0 ..< count {
			node.rows[i] = sorted[i]
		}
	}
	order_release_keys(e, at)
}

@(private = "file")
order_release_keys :: proc(e: ^Exec, at: int) {
	node := &e.nodes[at]
	for keys in node.sort_keys {
		for key in keys {
			if key.term != nil {
				rdf.destroy_term(key.term, e.allocator)
			}
		}
		delete(keys, e.allocator)
	}
	clear(&node.sort_keys)
}

// blocking_reset returns a Group or an Order to the state it was in
// before it collected anything, so a correlated re-run recomputes rather
// than replaying. It is the one thing node_reset does that Materialized
// and Distinct deliberately do not get.
@(private = "file")
blocking_reset :: proc(e: ^Exec, at: int) {
	node := &e.nodes[at]
	if node.kind != .Group && node.kind != .Order && !(node.kind == .Materialized && node.recollect) {
		return
	}
	group_release(e, at)
	order_release_keys(e, at)
	for stored in node.rows {
		delete(stored, e.allocator)
	}
	clear(&node.rows)
	node.collected = false
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
	e: ^Exec,
	at: int,
	from: int,
	row: []record.Term_ID,
	have: bool,
) -> (
	out: []record.Term_ID,
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
		node_reset(e, node.right)
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
	e: ^Exec,
	at: int,
	from: int,
	row: []record.Term_ID,
	have: bool,
) -> (
	out: []record.Term_ID,
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
		node_reset(e, node.right)
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
//
// Compatibility is over every slot; sharing is over the query's
// variables only. The distinction is not pedantry: a MINUS inside `GRAPH
// ?g { … }` has an internal slot bound on both sides naming the graph the
// two were evaluated in, and it must go on restricting the right side to
// that graph — that is the compatibility half — without ever *being* the
// shared variable that licenses the removal. `graph-minus` pins exactly
// that: `{ ?a :p :o MINUS { ?b :p :o } }` has disjoint domains and so
// removes nothing, and the enclosing GRAPH does not change that. The
// engine's other invented slots — path endpoints, triple-term shapes,
// pattern blank nodes — are none of them in a solution's domain either,
// and are excluded here for the same reason.
@(private = "file")
minus_excluded :: proc(e: ^Exec, right: int, row: []record.Term_ID) -> bool {
	internal := e.expr.slots.internal[:]
	for stored in e.nodes[right].rows {
		shared, compatible := false, true
		for value, slot in stored {
			if value == UNBOUND || row[slot] == UNBOUND {
				continue
			}
			if value != row[slot] {
				compatible = false
				break
			}
			if !internal[slot] {
				shared = true
			}
		}
		if shared && compatible {
			return true
		}
	}
	return false
}

@(private = "file")
conditions_hold :: proc(e: ^Exec, conditions: []Expr, row: []record.Term_ID) -> bool {
	if len(conditions) == 0 {
		return true
	}
	e.expr.row = row
	expr_context_new_solution(&e.expr)
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
bindable_id :: proc(e: ^Exec, value: Value) -> (id: record.Term_ID, ok: bool) {
	if value.kind == .Error || value.kind == .Unbound {
		return UNBOUND, false
	}
	if value.has_source {
		return value.source, true
	}
	term, rendered := value_to_term(value, e.allocator)
	if !rendered {
		return UNBOUND, false
	}
	// A blank node the query made is by definition not one the store
	// holds (§17.4.2.2), so it must not be looked up: a label collision
	// with a node in the data would bind BNODE's result to that node.
	// Only BNODE produces a blank-node value without a source.
	if value.kind == .Blank_Node {
		return computed_id(e, term), true
	}
	// A computed term the store already holds gets the store's own ID, so
	// a later pattern can match on it — `BIND(?o+1 AS ?z) . ?s ?p ?z` is
	// a real query shape, and a synthetic ID would match nothing. Only a
	// term the data does not contain needs a name of the engine's own.
	if stored, found := exec_resolve(e.snapshot, term); found {
		rdf.destroy_term(term, e.allocator)
		return stored, true
	}
	return computed_id(e, term), true
}

// computed_id names a term the store does not hold, taking ownership of
// it. The same term always gets the same name — see Exec.computed_index
// for why that is load-bearing rather than tidy.
@(private = "file")
computed_id :: proc(e: ^Exec, term: rdf.Term) -> record.Term_ID {
	strings.builder_reset(&e.computed_key)
	term_key(&e.computed_key, term)
	if index, found := e.computed_index[strings.to_string(e.computed_key)]; found {
		rdf.destroy_term(term, e.allocator)
		return synthetic_id(index)
	}
	index := len(e.computed)
	append(&e.computed, term)
	e.computed_index[strings.clone(strings.to_string(e.computed_key), e.allocator)] = index
	return synthetic_id(index)
}

// exec_exists answers an EXISTS: does the index-th sub-plan have a
// solution, given the bindings currently in the row?
//
// The sub-plan is reset before and after. Before, because it was last
// run against a different solution; after, because whatever it bound is
// its own business — EXISTS is a test, and a variable it happened to
// bind must not leak into the answer (§17.4.1.2's substitution
// semantics, read as "the pattern is evaluated, not joined").
exec_exists :: proc(
	e: ^Exec,
	index: int,
) -> bool {
	if index < 0 || index >= len(e.exists_roots) {
		return false
	}
	root := e.exists_roots[index]
	node_reset(e, root)
	_, found := run(e, root)
	node_reset(e, root)
	return found
}

// exec_describe writes the description of each resource into a graph:
// every triple of the default graph with that resource as its subject
// (see Describe_Targets for why that, and only that).
//
// It is here rather than in construct.odin because it is the one part of
// a result form that asks the store a question of its own — DESCRIBE
// answers about resources, not about solutions, so the pattern's answers
// name the subjects and the store supplies the triples.
exec_describe :: proc(
	e: ^Exec,
	targets: []record.Term_ID,
	graph: ^Result_Graph,
	q: ^Query,
) {
	for subject in targets {
		// A term the engine named itself is not in the data, and its ID is
		// in a space the store must never be shown.
		if is_synthetic(subject) {
			continue
		}
		// A pattern, so the default graph is the pattern-side constant.
		pattern := Match_Pattern{subject, WILDCARD, WILDCARD, DEFAULT_GRAPH}
		it := match_open(e, pattern)
		for {
			quad, more := match_next(&it)
			if !more {
				break
			}
			triple := rdf.Triple {
				subject   = query_term(q, quad[QUAD_S]),
				predicate = query_term(q, quad[QUAD_P]),
				object    = query_term(q, quad[QUAD_O]),
			}
			result_graph_add(graph, triple)
		}
	}
}

// exec_computed_term resolves a synthetic ID to the term it names. A
// consumer materializing a solution asks here before it asks the store,
// because the store has never heard of these terms.
exec_computed_term :: proc(e: ^Exec, id: record.Term_ID) -> (term: rdf.Term, ok: bool) {
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
node_reset :: proc(e: ^Exec, at: int) {
	for i in e.nodes[at].subtree_start ..= at {
		node := &e.nodes[i]
		for d in 0 ..< len(node.iter_open) {
			node.iter_open[d] = false
		}
		for d in 0 ..< len(node.bound_count) {
			for j in 0 ..< node.bound_count[d] {
				e.work[node.bound_slots[d][j]] = UNBOUND
			}
			node.bound_count[d] = 0
		}
		release_set_slots(e, node)
		blocking_reset(e, i)
		node.started = false
		node.produced_unit = false
		node.depth = 0
		node.phase = .Need_Left
		node.matched = false
		node.row_at = 0
		node.skipped = 0
		node.emitted = 0
		node.path_at = 0
		node.start_at = 0
		node.queue_at = 0
		clear(&node.path_starts)
		clear(&node.path_result)
		clear(&node.path_queue)
		clear(&node.path_seen)
		clear(&node.path_expanded)
		clear(&node.path_nodes)
		clear(&node.graph_seen)
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
	e: ^Exec,
	at: int,
) -> (
	row: []record.Term_ID,
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
			node.iters[depth] = match_open(e, probe_pattern(e, node, depth))
			node.iter_open[depth] = true
			node.bound_count[depth] = 0
		}
		// Release what this depth bound for its previous quad before
		// asking for the next one.
		unbind_depth(e, node, depth)
		quad, more := match_next(&node.iters[depth])
		if !more {
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

// --- Property paths -------------------------------------------------

// nps_next yields the next match of a negated property set: any triple in
// the active graph whose predicate is not one of the excluded IDs, read
// forwards or backwards.
//
// It is a basic graph pattern with the predicate left open and a rejection
// test on the way out, so it borrows the depth-0 iterator slot and the
// bound-slot bookkeeping and lets node_reset clean up after it.
@(private = "file")
nps_next :: proc(
	e: ^Exec,
	at: int,
) -> (
	row: []record.Term_ID,
	ok: bool,
) {
	node := &e.nodes[at]
	plan := node.nps
	subject_position := QUAD_O if plan.inverse else QUAD_S
	object_position := QUAD_S if plan.inverse else QUAD_O

	if !node.iter_open[0] {
		pattern: Match_Pattern
		pattern[QUAD_P] = WILDCARD
		pattern[subject_position] = probe_id(e, plan.subject)
		pattern[object_position] = probe_id(e, plan.object)
		pattern[QUAD_G] = probe_id(e, plan.graph)
		// The second copy of the assert probe_pattern used to carry, and
		// gone for the same reason: on record UNBOUND and WILDCARD are
		// one value, so this asserted 0 != 0 and fired on any negated
		// property set with an unbound endpoint. See probe_pattern.
		node.iters[0] = match_open(e, pattern)
		node.iter_open[0] = true
		node.bound_count[0] = 0
	}

	for {
		unbind_depth(e, node, 0)
		quad, more := match_next(&node.iters[0])
		if !more {
			node.iter_open[0] = false
			return nil, false
		}
		if id_excluded(plan.excluded[:], quad[QUAD_P]) {
			continue
		}
		if !nps_unify(e, node, quad, subject_position, object_position) {
			continue
		}
		return e.work, true
	}
}

@(private = "file")
id_excluded :: proc(excluded: []record.Term_ID, id: record.Term_ID) -> bool {
	for candidate in excluded {
		if candidate == id {
			return true
		}
	}
	return false
}

// probe_id is a plan reference as a match-pattern position: a ground ID,
// the value a bound slot holds, or a wildcard.
@(private = "file")
probe_id :: proc(e: ^Exec, ref: Plan_Ref) -> record.Term_ID {
	if !plan_ref_is_var(ref) {
		return ref.id
	}
	// An unbound slot is a wildcard, and on record that substitution is
	// the identity: both are 0. Written out rather than returned bare
	// because the two meanings are still two — see ids.odin.
	value := e.work[ref.slot]
	return WILDCARD if value == UNBOUND else value
}

@(private = "file")
nps_unify :: proc(
	e: ^Exec,
	node: ^Exec_Node,
	quad: Encoded_Quad,
	subject_position, object_position: int,
) -> bool {
	plan := node.nps
	count := 0
	pairs := [3][2]int {
		{subject_position, 0},
		{object_position, 1},
		{QUAD_G, 2},
	}
	refs := [3]Plan_Ref{plan.subject, plan.object, plan.graph}
	for pair in pairs {
		ref := refs[pair[1]]
		if !plan_ref_is_var(ref) {
			continue
		}
		value := quad[pair[0]]
		current := e.work[ref.slot]
		if current != UNBOUND {
			if current != value {
				for i in 0 ..< count {
					e.work[node.bound_slots[0][i]] = UNBOUND
				}
				node.bound_count[0] = 0
				return false
			}
			continue
		}
		e.work[ref.slot] = value
		node.bound_slots[0][count] = ref.slot
		count += 1
	}
	node.bound_count[0] = count
	return true
}

// path_next hands out the solutions of one repeat form (§18.4's `?`, `*`,
// and `+`), a start node at a time.
//
// Each start gets its reachable set computed in full — the set is what
// makes the three forms sets rather than bags, and it is per start, so two
// starts reaching the same node are two solutions — and the set is then
// handed out one solution per call.
@(private = "file")
path_next :: proc(
	e: ^Exec,
	at: int,
) -> (
	row: []record.Term_ID,
	ok: bool,
) {
	node := &e.nodes[at]
	if !node.started {
		node.started = true
		path_setup(e, at)
	}
	for {
		release_set_slots(e, node)
		if node.path_at >= len(node.path_result) {
			if node.start_at >= len(node.path_starts) {
				return nil, false
			}
			node.path_start = node.path_starts[node.start_at]
			node.start_at += 1
			path_closure(e, at)
			node.path_at = 0
			continue
		}
		reached := node.path_result[node.path_at]
		node.path_at += 1
		if path_emit(e, at, node.path_start, reached) {
			return e.work, true
		}
	}
}

// path_setup picks which of §18.4's cases this pattern is, and what the
// traversal starts from.
//
// The case comes from the *pattern*: a ground endpoint fixes an end
// whatever the row says, and two variable endpoints mean the zero-length
// pairs are restricted to nodes(G) even when an enclosing solution has
// already bound one of them. A binding is then only a filter, which is
// what makes the operator safe to evaluate correlated — and it is why
// `VALUES ?v { 1 } . ?v :p? ?v` over a graph without 1 answers nothing.
@(private = "file")
path_setup :: proc(
	e: ^Exec,
	at: int,
) {
	node := &e.nodes[at]
	plan := node.path
	clear(&node.path_starts)
	clear(&node.path_result)
	node.path_at = 0
	node.start_at = 0
	node.backward = false
	node.check_nodes = plan.subject.slot >= 0 && plan.object.slot >= 0

	if value, fixed := path_end_value(e, plan.subject); fixed {
		append(&node.path_starts, value)
		return
	}
	if value, fixed := path_end_value(e, plan.object); fixed {
		// Nothing fixes the subject, so the traversal runs the step from
		// its object end instead of enumerating a graph to find the
		// subjects that reach this one.
		node.backward = true
		append(&node.path_starts, value)
		return
	}
	// Both ends are unbound variables: §18.4 ranges over the active
	// graph's nodes. Every start is then in nodes(G) by construction, so
	// the zero-length restriction needs no test of its own.
	node.check_nodes = false
	path_collect_nodes(e, at)
}

// path_end_value is the term an endpoint is pinned to, if any: a ground
// term, or whatever an enclosing solution has already bound the variable
// to.
@(private = "file")
path_end_value :: proc(e: ^Exec, end: Plan_Path_End) -> (id: record.Term_ID, fixed: bool) {
	if end.slot < 0 {
		return end.id, true
	}
	value := e.work[end.slot]
	if value == UNBOUND {
		return UNBOUND, false
	}
	return value, true
}

// path_collect_nodes fills the start list with nodes(G): every subject and
// every object of the active graph, each once. Objects included — a
// literal is a node of the graph, and `?X foaf:knows* ?Y` over data with a
// literal object has to answer for it.
//
// It reads every quad of the graph to do it, which is the same gap
// Plan_Graph_Scan runs into from the other side: the match interface can
// stream quads but cannot be asked for the terms it holds. Recorded as
// store evidence for SPARQL-T-0019.
@(private = "file")
path_collect_nodes :: proc(
	e: ^Exec,
	at: int,
) {
	node := &e.nodes[at]
	clear(&node.path_nodes)
	pattern := Match_Pattern {
		WILDCARD,
		WILDCARD,
		WILDCARD,
		path_graph_id(e, node.path.graph),
	}
	it := match_open(e, pattern)
	for {
		quad, more := match_next(&it)
		if !more {
			return
		}
		for position in ([2]int{QUAD_S, QUAD_O}) {
			id := quad[position]
			if id in node.path_nodes {
				continue
			}
			node.path_nodes[id] = true
			append(&node.path_starts, id)
		}
	}
}

// path_in_nodes reports whether a term is a node of the active graph.
@(private = "file")
path_in_nodes :: proc(
	e: ^Exec,
	at: int,
	id: record.Term_ID,
) -> bool {
	// A term the engine named itself is by construction not in the data,
	// and its ID is in a space the store must never be shown.
	if is_synthetic(id) {
		return false
	}
	graph := path_graph_id(e, e.nodes[at].path.graph)
	for position in ([2]int{QUAD_S, QUAD_O}) {
		pattern := Match_Pattern{WILDCARD, WILDCARD, WILDCARD, graph}
		pattern[position] = id
		it := match_open(e, pattern)
		_, found := match_next(&it)
		if found {
			return true
		}
	}
	return false
}

// path_graph_id is the graph a path evaluates in. A variable here is
// always bound by the time a path runs: plan building puts a graph scan
// above any GRAPH ?g body that holds one (see plan_has_path).
@(private = "file")
path_graph_id :: proc(e: ^Exec, ref: Plan_Ref) -> record.Term_ID {
	if !plan_ref_is_var(ref) {
		return ref.id
	}
	value := e.work[ref.slot]
	// Still exact on record, where UNBOUND is 0 and so is a fact's
	// default graph: a graph *variable* is bound by graph_scan_next,
	// which skips the default graph precisely because it has no name to
	// bind. So 0 here means unbound and nothing else.
	assert(value != UNBOUND, "a property path ran with its graph variable unbound")
	return value
}

// path_closure fills the result list with the nodes the current start
// reaches, breadth first.
//
// The frontier is an explicit queue and the expanded set is what makes a
// cycle terminate: a node is expanded at most once, so the walk is bounded
// by the graph and a chain of any depth costs stack depth of zero.
@(private = "file")
path_closure :: proc(
	e: ^Exec,
	at: int,
) {
	node := &e.nodes[at]
	plan := node.path
	clear(&node.path_result)
	clear(&node.path_seen)
	clear(&node.path_expanded)
	clear(&node.path_queue)
	node.queue_at = 0
	start := node.path_start

	if plan.include_start {
		if !node.check_nodes || path_in_nodes(e, at, start) {
			node.path_seen[start] = true
			append(&node.path_result, start)
		}
	}
	// `+` does not put the start in the result, but it does expand it: a
	// start that a cycle leads back to *is* reached in one or more steps,
	// and arrives through the frontier like any other node.
	append(&node.path_queue, start)
	node.path_expanded[start] = true

	for node.queue_at < len(node.path_queue) {
		from := node.path_queue[node.queue_at]
		node.queue_at += 1
		// A term the store does not hold has no edges, and asking would
		// mean handing the store an ID it never issued.
		if is_synthetic(from) {
			continue
		}
		clear(&node.path_step_out)
		exec_path_expand(e, at, from, node.backward, &node.path_step_out)
		for reached in node.path_step_out {
			if !(reached in node.path_seen) {
				node.path_seen[reached] = true
				append(&node.path_result, reached)
			}
			if plan.closure && !(reached in node.path_expanded) {
				node.path_expanded[reached] = true
				append(&node.path_queue, reached)
			}
		}
	}
}

// path_emit binds one (start, reached) pair into the solution row, or
// reports that the row already says otherwise.
@(private = "file")
path_emit :: proc(e: ^Exec, at: int, start, reached: record.Term_ID) -> bool {
	node := &e.nodes[at]
	plan := node.path
	subject_value := reached if node.backward else start
	object_value := start if node.backward else reached
	// Subject first: a pattern whose two ends are the same variable —
	// `?v :p* ?v` — is answered by the object test seeing what the subject
	// just bound.
	if !path_bind(e, node, plan.subject, subject_value) {
		release_set_slots(e, node)
		return false
	}
	if !path_bind(e, node, plan.object, object_value) {
		release_set_slots(e, node)
		return false
	}
	return true
}

@(private = "file")
path_bind :: proc(
	e: ^Exec,
	node: ^Exec_Node,
	end: Plan_Path_End,
	value: record.Term_ID,
) -> bool {
	if end.slot < 0 {
		return end.id == value
	}
	current := e.work[end.slot]
	if current != UNBOUND {
		return current == value
	}
	e.work[end.slot] = value
	append(&node.set_slots, end.slot)
	return true
}

// exec_path_expand runs a property path's step sub-plan from one node and
// collects everything it reaches in one step.
//
// The step is an ordinary operator tree over two internal slots — bind the
// one end, read the other — which is what lets a step be any path at all:
// a sequence, an alternative, a negated set, or another repeat. It is
// reset before and after, and the two slots are restored, so a traversal
// leaves nothing of itself in the row.
exec_path_expand :: proc(
	e: ^Exec,
	at: int,
	from: record.Term_ID,
	backward: bool,
	out: ^[dynamic]record.Term_ID,
) {
	plan := e.nodes[at].path
	step := e.nodes[at].input
	entry := plan.out_slot if backward else plan.in_slot
	exit := plan.in_slot if backward else plan.out_slot

	saved_entry := e.work[entry]
	saved_exit := e.work[exit]
	node_reset(e, step)
	e.work[entry] = from
	e.work[exit] = UNBOUND
	for {
		_, more := run(e, step)
		if !more {
			break
		}
		reached := e.work[exit]
		if reached != UNBOUND {
			append(out, reached)
		}
	}
	node_reset(e, step)
	e.work[entry] = saved_entry
	e.work[exit] = saved_exit
}

// probe_pattern substitutes the row's current bindings into the pattern
// at a depth. An unbound variable becomes a wildcard; a bound one
// narrows the match to exactly its value, which is what makes this an
// index probe rather than a scan and a filter.
@(private = "file")
probe_pattern :: proc(e: ^Exec, node: ^Exec_Node, depth: int) -> Match_Pattern {
	triple := node.bgp.triples[node.bgp.order[depth]]
	pattern: Match_Pattern
	for position, i in triple {
		if !plan_ref_is_var(position) {
			pattern[i] = position.id
			continue
		}
		value := e.work[position.slot]
		pattern[i] = WILDCARD if value == UNBOUND else value
	}
	// **The assert that stood here is gone, not moved** (SPARQL-T-0031).
	// It read "UNBOUND leaked into a match pattern", and against
	// odin-rdf-store it was a real check: UNBOUND was its own sentinel,
	// distinct from WILDCARD, and one reaching a pattern would silently
	// widen a probe into a full scan. On record the two are the same
	// value by design — an unbound position *is* the wildcard — so the
	// same text would assert that 0 != 0 and fail every probe over an
	// unbound variable. There is nothing left to check here: the
	// substitution above is total, and a synthetic id (the one value that
	// must never reach the store) is caught where it is made rather than
	// where it is used.
	return pattern
}

// unify_quad binds a matched quad's terms into the row, and reports
// whether it is consistent with what the row already holds. A variable
// repeated within one pattern (`?a ?a ?b`) is checked here: the store
// matched a wildcard in both positions, and the second occurrence sees
// the value the first bound.
@(private = "file")
unify_quad :: proc(e: ^Exec, node: ^Exec_Node, depth: int, quad: Encoded_Quad) -> bool {
	pattern := node.bgp.order[depth]
	triple := node.bgp.triples[pattern]
	count := 0
	for position, i in triple {
		if !plan_ref_is_var(position) {
			continue
		}
		if i == QUAD_G && quad[i] == STORED_DEFAULT_GRAPH {
			// A variable in the graph position comes only from GRAPH ?g,
			// which ranges over the *named* graphs — the default graph is
			// not one of them and has no name to bind. record's pattern
			// cannot say "any named graph" either (an unbound G spans
			// both, and Filter.graphs takes a set of names rather than a
			// class), so the exclusion happens here, over-fetching and
			// filtering. That is the same gap SPARQL-T-0019 recorded
			// against odin-rdf-store, carried across the port unchanged.
			//
			// The test is on the *stored* default graph — 0 — and not on
			// DEFAULT_GRAPH, which is a pattern value record's facts never
			// carry.
			for j in 0 ..< count {
				e.work[node.bound_slots[depth][j]] = UNBOUND
			}
			node.bound_count[depth] = 0
			return false
		}
		current := e.work[position.slot]
		if current != UNBOUND {
			if current != quad[i] {
				for j in 0 ..< count {
					e.work[node.bound_slots[depth][j]] = UNBOUND
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
	if len(node.bgp.shapes) == 0 {
		return true
	}
	// The triple terms this pattern wrote out. A shape's own slot was
	// bound above (or by an earlier shape, for a nested one), so one
	// forward pass suffices: the list is in pre-order.
	range := node.bgp.shape_range[pattern]
	for at in range[0] ..< range[1] {
		if unify_shape(e, node, depth, at) {
			continue
		}
		unbind_depth(e, node, depth)
		return false
	}
	return true
}

// unify_shape checks one matched triple term against the components the
// pattern wrote, binding the variables among them. It is the same
// bind-or-compare unification unify_quad does for a quad's positions,
// over a term the store handed back whole.
@(private = "file")
unify_shape :: proc(e: ^Exec, node: ^Exec_Node, depth: int, at: int) -> bool {
	shape := node.bgp.shapes[at]
	id := e.work[shape.slot]
	// An unbound slot names no term, and record's snapshot_kind asserts
	// on an id that is not one of the snapshot's rather than answering.
	if id == UNBOUND {
		return false
	}
	if record.snapshot_kind(e.snapshot, id) != .Triple {
		// The position matched something that is not a triple term at
		// all — an IRI, a literal. Not an error: the pattern simply does
		// not hold here.
		return false
	}
	parts, read := exec_triple_parts(e.snapshot, id)
	if !read {
		return false
	}
	for part, i in shape.parts {
		if !plan_ref_is_var(part) {
			if part.id != parts[i] {
				return false
			}
			continue
		}
		current := e.work[part.slot]
		if current != UNBOUND {
			if current != parts[i] {
				return false
			}
			continue
		}
		e.work[part.slot] = parts[i]
		node.bound_slots[depth][node.bound_count[depth]] = part.slot
		node.bound_count[depth] += 1
	}
	return true
}

@(private = "file")
unbind_depth :: proc(e: ^Exec, node: ^Exec_Node, depth: int) {
	for i in 0 ..< node.bound_count[depth] {
		e.work[node.bound_slots[depth][i]] = UNBOUND
	}
	node.bound_count[depth] = 0
}

// row_key is a solution's identity for DISTINCT: the raw bytes of its
// term IDs. Deduplication is the one place the streaming path has to
// retain something, so it is the one place it allocates — and the key is
// the row's bytes rather than a rendering of its terms, because that is
// what evaluating over IDs buys.
@(private)
row_key :: proc(row: []record.Term_ID, allocator: runtime.Allocator) -> string {
	bytes := transmute([]u8)runtime.Raw_Slice{data = raw_data(row), len = len(row) * size_of(record.Term_ID)}
	return strings.clone(string(bytes), allocator)
}
