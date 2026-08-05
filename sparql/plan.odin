// The evaluation plan: the bridge from the §18 algebra to something a
// store can execute (SPARQL-T-0011).
//
// Two things happen here, once per query, before any matching does.
//
// **Variables become slots.** Every variable and every blank node in the
// pattern is assigned a dense integer slot, and a solution is a flat
// `[]store.Term_ID` indexed by slot — not a map. Joining and
// deduplicating solutions is then integer comparison, which is the whole
// point of evaluating over Term_IDs. Blank nodes get slots too: in a
// pattern a blank node *is* a variable, just one the query cannot name
// or project.
//
// **Ground terms become IDs.** Every IRI and literal written in the
// query is resolved against the target store's dictionary, once. This
// goes through the store's non-interning `find_term` (STORE-T-0014), so
// a query never assigns an ID and never turns a read into a write — on a
// persistent backend, asking about a term the store has never seen must
// not make it a term the store has seen. A ground term the store does
// not hold makes its triple pattern unsatisfiable, and the plan collapses
// to Plan_Nothing rather than scanning for something that cannot be
// there.
//
// The resolver is a procedure pointer. That is a deliberate exception to
// the no-dynamic-dispatch rule and a safe one: it is called a handful of
// times per query, at setup, never per solution. The hot path — matching
// — is bound at compile time instead; see exec.odin.
package sparql

import "base:runtime"
import "core:strings"

import rdf "rdf:rdf"
import store "store:store"

// Var_Slots is a query's variable-slot table: the mapping from the
// names in the query text to the columns of a solution row.
//
// A blank node in a pattern is a variable that cannot be named or
// projected, so it gets a slot marked internal. Keys are namespaced by a
// leading sigil because `?x` and `_:x` are different things that may
// both appear in one query.
Var_Slots :: struct {
	names:     [dynamic]string,
	internal:  [dynamic]bool,
	index:     map[string]int,
	allocator: runtime.Allocator,
}

var_slots_init :: proc(vs: ^Var_Slots, allocator := context.allocator) {
	vs.allocator = allocator
	vs.names = make([dynamic]string, allocator)
	vs.internal = make([dynamic]bool, allocator)
	vs.index = make(map[string]int, allocator)
}

var_slots_destroy :: proc(vs: ^Var_Slots) {
	for key in vs.index {
		delete(key, vs.allocator)
	}
	delete(vs.index)
	delete(vs.names)
	delete(vs.internal)
	vs^ = {}
}

// var_slot returns the slot of a query variable, assigning one on first
// sight. The returned slot is stable for the life of the query.
var_slot :: proc(vs: ^Var_Slots, name: string) -> int {
	return slot_for(vs, "?", name, false)
}

// blank_slot returns the slot of a pattern blank node. It behaves as a
// variable during matching and is never projected.
blank_slot :: proc(vs: ^Var_Slots, label: string) -> int {
	return slot_for(vs, "_", label, true)
}

// var_slot_lookup finds an existing query variable's slot without
// assigning one and without allocating — it is called per variable
// occurrence per solution during expression evaluation, where the
// key-building that var_slot does would be a per-solution allocation.
// Blank-node slots are skipped: `?x` and `_:x` are different things.
var_slot_lookup :: proc(vs: ^Var_Slots, name: string) -> (slot: int, found: bool) {
	for candidate, i in vs.names {
		if !vs.internal[i] && candidate == name {
			return i, true
		}
	}
	return -1, false
}

// var_slots_count is the width of a solution row.
var_slots_count :: proc(vs: ^Var_Slots) -> int {
	return len(vs.names)
}

@(private = "file")
slot_for :: proc(vs: ^Var_Slots, sigil: string, name: string, internal: bool) -> int {
	key := strings.concatenate({sigil, name}, vs.allocator)
	if slot, found := vs.index[key]; found {
		delete(key, vs.allocator)
		return slot
	}
	slot := len(vs.names)
	vs.index[key] = slot
	append(&vs.names, name)
	append(&vs.internal, internal)
	return slot
}

// Plan_Ref is one position of a triple pattern after binding: either a
// slot to unify against, or a term ID to match exactly.
Plan_Ref :: struct {
	slot: int, // >= 0: a variable slot; < 0: ground, use id
	id:   store.Term_ID,
}

plan_ref_is_var :: proc(r: Plan_Ref) -> bool {
	return r.slot >= 0
}

// Plan_Triple is a quad pattern over slots and IDs, indexed by
// store.QUAD_S/P/O/G. The graph position is filled from the plan's
// active graph — store.DEFAULT_GRAPH outside a GRAPH clause.
Plan_Triple :: distinct [4]Plan_Ref

// Plan_BGP is a basic graph pattern to be evaluated as a chain of
// index probes: for each pattern in join order, substitute what the
// row already binds and match.
//
// order is the join order — the one place a future planner replaces.
// Today it is the identity permutation (patterns in the order written),
// which is what "naive fixed join order" means; nothing else in the
// engine assumes anything about it.
Plan_BGP :: struct {
	triples: [dynamic]Plan_Triple,
	order:   [dynamic]int,
}

// Plan_Nothing yields no solutions. It is what a pattern collapses to
// when a ground term it needs is not in the store — the short-circuit
// that keeps an unsatisfiable query from scanning.
Plan_Nothing :: struct {}

// Plan_Unit yields exactly one solution, binding nothing: the identity
// of join, and the answer to a query with an empty pattern.
Plan_Unit :: struct {}

// Plan_Project restricts solutions to a set of slots.
Plan_Project :: struct {
	slots: [dynamic]int,
	input: Plan,
}

// Plan_Distinct removes duplicate solutions. REDUCED is permitted to
// remove any number of them, so it is implemented as DISTINCT — a legal
// choice the spec makes explicit, recorded here so the shared node is
// not mistaken for a conflation.
Plan_Distinct :: struct {
	input: Plan,
}

// Plan_Filter drops the solutions whose conditions are not true. The
// conditions are a conjunction, kept separate exactly as the algebra
// grouped them, and a condition that raises a type error drops the
// solution just as a false one does (§17.2.2).
Plan_Filter :: struct {
	conditions: [dynamic]Expr,
	input:      Plan,
}

// Plan_Slice is OFFSET/LIMIT; -1 means absent.
Plan_Slice :: struct {
	start:  int,
	length: int,
	input:  Plan,
}

// Plan_Union is the binary Union of §18.5: every solution of the left,
// then every solution of the right.
Plan_Union :: struct {
	left, right: Plan,
}

// Plan_Left_Join is OPTIONAL. The right side is evaluated once per left
// solution with the left's bindings already in the row, so it probes
// rather than scans; a left solution the right cannot extend is emitted
// as it stands. conditions are the filter the translation hoisted into
// the LeftJoin (§18.2.2.6) and belong to the *match*, not to the output:
// a right solution failing them is not a match, which is why the
// condition cannot simply be a Filter above the join.
Plan_Left_Join :: struct {
	left, right: Plan,
	conditions:  [dynamic]Expr,
}

// Plan_Minus removes left solutions that are compatible with some right
// solution *and* share a variable with it (§18.5's Minus).
//
// Unlike OPTIONAL, the right side is evaluated independently — MINUS's
// variables are not in scope on the left — so it cannot probe with the
// left's bindings and is materialized once instead.
Plan_Minus :: struct {
	left, right: Plan,
}

// Plan_Join is the general join, for the pairs plan building cannot
// merge into one basic graph pattern. Correlated: the right side runs
// once per left solution with the left's bindings in place.
Plan_Join :: struct {
	left, right: Plan,
}

// Plan_Extend is BIND and the SELECT expressions: bind an expression's
// value to a slot, in order, each able to see the ones before it.
Plan_Extend :: struct {
	slots:    [dynamic]int,
	exprs:    [dynamic]Expr,
	input:    Plan,
}

// Plan_Table_Cell is one cell of a VALUES row. Three states, and the
// difference between the last two matters: `bound` is a term to bind,
// not-bound-not-absent is UNDEF (bind nothing, which is a perfectly good
// solution), and `absent` is a term the store does not hold, which makes
// the whole row unmatchable.
Plan_Table_Cell :: struct {
	slot:   int,
	id:     store.Term_ID,
	bound:  bool,
	absent: bool,
	// The term the cell was written with, kept for the absent case: a
	// VALUES cell supplies a binding, and a value the store has never
	// seen is still a perfectly good binding. It borrows the query's
	// parse, which outlives the plan.
	term:   rdf.Term,
}

// Plan_Table is a VALUES block: an inline solution sequence. A ground
// term the store does not hold makes its cell unmatchable rather than
// its row absent — VALUES supplies bindings, and a binding to a term the
// data cannot contain simply joins with nothing.
Plan_Table :: struct {
	rows:  [dynamic][dynamic]Plan_Table_Cell,
	slots: [dynamic]int,
}

// Plan_Graph_Scan yields one solution per named graph, binding the slot
// to each.
//
// It exists for the case the ordinary mechanism cannot cover. `GRAPH ?g
// { P }` normally needs no operator of its own: the graph position of
// every triple pattern in P becomes ?g's slot, and matching binds it.
// But when P matches no triples at all — `GRAPH ?g {}`, or a GRAPH whose
// body is only a VALUES block — there is nothing to carry the binding,
// and the clause still ranges over the graphs. Then the graphs have to
// be enumerated.
//
// The store cannot be asked for its graphs, so this scans everything and
// keeps the distinct graph IDs. That is the third store-evidence item
// for SPARQL-T-0019: a dataset's list of named graphs is something a
// query engine asks for constantly and the match interface cannot
// answer.
Plan_Graph_Scan :: struct {
	slot: int,
}

// Plan_Materialized is a sub-plan whose solutions are collected once,
// before the query runs, because its consumer needs them independently
// of the enclosing bindings: MINUS's right side, and a subquery, whose
// variables are scoped to itself.
Plan_Materialized :: struct {
	input: Plan,
}

Plan :: union {
	^Plan_BGP,
	^Plan_Nothing,
	^Plan_Unit,
	^Plan_Project,
	^Plan_Distinct,
	^Plan_Slice,
	^Plan_Filter,
	^Plan_Union,
	^Plan_Left_Join,
	^Plan_Minus,
	^Plan_Join,
	^Plan_Extend,
	^Plan_Table,
	^Plan_Materialized,
	^Plan_Graph_Scan,
}

// Term_Finder resolves a ground term to its store ID without interning
// it. found=false means the store does not hold the term.
Term_Finder :: #type proc(data: rawptr, term: rdf.Term) -> (id: store.Term_ID, found: bool)

// Plan_Builder carries what plan construction needs: the slot table
// being filled, the store's non-interning lookup, and the graph that
// triple patterns match in.
//
// unsupported names the first algebra operator this task's evaluator
// does not implement. It is a string rather than a flag so a caller can
// say which operator, and it is reported rather than silently treated as
// an empty result — an operator the engine cannot evaluate must never
// look like a query with no answers.
Plan_Builder :: struct {
	slots:       ^Var_Slots,
	find:        Term_Finder,
	data:        rawptr,
	// The graph triple patterns match in. Outside a GRAPH clause it is
	// the default graph; inside one it is that clause's IRI or, for
	// GRAPH ?g, the variable's slot — which is how ?g comes back bound
	// to the graph each solution was found in.
	graph:       Plan_Ref,
	unsupported: string,
	// The EXISTS patterns met while walking the expressions, each with
	// the sub-plan built for it. They are collected rather than nested
	// because an expression is not part of the operator tree: EXISTS is
	// a pattern that appears inside a value, and the executor keeps its
	// sub-plans alongside the main one.
	exists_nodes: [dynamic]^Exists_Expr,
	exists_plans: [dynamic]Plan,
	allocator:   runtime.Allocator,
}

plan_builder_init :: proc(
	b: ^Plan_Builder,
	slots: ^Var_Slots,
	find: Term_Finder,
	data: rawptr,
	allocator := context.allocator,
) {
	b.slots = slots
	b.find = find
	b.data = data
	b.graph = Plan_Ref{slot = -1, id = store.DEFAULT_GRAPH}
	b.exists_nodes = make([dynamic]^Exists_Expr, allocator)
	b.exists_plans = make([dynamic]Plan, allocator)
	b.allocator = allocator
}

// plan_builder_destroy releases the builder's own bookkeeping. The plans
// it produced belong to the caller.
plan_builder_destroy :: proc(b: ^Plan_Builder) {
	delete(b.exists_nodes)
	delete(b.exists_plans)
}

// exists_register builds the sub-plan for an EXISTS pattern and returns
// its index, reusing the plan if the same node has been seen before.
exists_register :: proc(b: ^Plan_Builder, node: ^Exists_Expr) -> (index: int, ok: bool) {
	for existing, i in b.exists_nodes {
		if existing == node {
			return i, true
		}
	}
	// An EXISTS is evaluated inside whatever solution reaches it, so its
	// pattern is built exactly like a correlated join's right side — and
	// under the same restriction. A sub-pattern that cannot be probed is
	// materialized, which is also what makes its variables scoped.
	sub, built := plan_build(b, node.algebra)
	if !built {
		return -1, false
	}
	append(&b.exists_nodes, node)
	append(&b.exists_plans, scoped(b, sub))
	return len(b.exists_nodes) - 1, true
}

// exists_index returns the index registered for an EXISTS node.
exists_index :: proc(nodes: []^Exists_Expr, node: ^Exists_Expr) -> int {
	for existing, i in nodes {
		if existing == node {
			return i
		}
	}
	return -1
}

// plan_build turns an algebra tree into a plan. ok is false when the
// algebra uses an operator this evaluator does not implement yet, in
// which case b.unsupported names it.
plan_build :: proc(b: ^Plan_Builder, a: Algebra) -> (p: Plan, ok: bool) {
	switch v in a {
	case ^Alg_BGP:
		return build_bgp(b, v)
	case ^Alg_Table:
		if v.unit {
			return new(Plan_Unit, b.allocator), true
		}
		return build_table(b, v)
	case ^Alg_Join:
		left := plan_build(b, v.left) or_return
		right, right_ok := plan_build(b, v.right)
		if !right_ok {
			plan_destroy(left, b.allocator)
			return nil, false
		}
		return join_plans(b, left, right)
	case ^Alg_Project:
		input := plan_build(b, v.input) or_return
		project := new(Plan_Project, b.allocator)
		project.slots = make([dynamic]int, b.allocator)
		for variable in v.vars {
			append(&project.slots, var_slot(b.slots, variable.name))
		}
		project.input = input
		return project, true
	case ^Alg_Distinct:
		input := plan_build(b, v.input) or_return
		node := new(Plan_Distinct, b.allocator)
		node.input = input
		return node, true
	case ^Alg_Reduced:
		input := plan_build(b, v.input) or_return
		node := new(Plan_Distinct, b.allocator)
		node.input = input
		return node, true
	case ^Alg_Slice:
		input := plan_build(b, v.input) or_return
		node := new(Plan_Slice, b.allocator)
		node.start = v.start
		node.length = v.length
		node.input = input
		return node, true
	case ^Alg_Path:
		b.unsupported = "property path"
	case ^Alg_Left_Join:
		for condition in v.conditions {
			if !expr_check(b, condition) {
				return nil, false
			}
		}
		left := plan_build(b, v.left) or_return
		right, right_ok := plan_build(b, v.right)
		if !right_ok {
			// The left side is already built; a failure on the right
			// leaves it with no owner unless it is released here.
			plan_destroy(left, b.allocator)
			return nil, false
		}
		node := new(Plan_Left_Join, b.allocator)
		node.left = left
		// The right side of an OPTIONAL is correlated for the same
		// reason, and under the same restriction, as a join's.
		node.right = scoped(b, right)
		node.conditions = make([dynamic]Expr, b.allocator)
		for condition in v.conditions {
			append(&node.conditions, condition)
		}
		return node, true
	case ^Alg_Filter:
		for condition in v.conditions {
			if !expr_check(b, condition) {
				return nil, false
			}
		}
		input := plan_build(b, v.input) or_return
		filter := new(Plan_Filter, b.allocator)
		filter.conditions = make([dynamic]Expr, b.allocator)
		for condition in v.conditions {
			append(&filter.conditions, condition)
		}
		filter.input = input
		return filter, true
	case ^Alg_Union:
		left := plan_build(b, v.left) or_return
		right, right_ok := plan_build(b, v.right)
		if !right_ok {
			plan_destroy(left, b.allocator)
			return nil, false
		}
		node := new(Plan_Union, b.allocator)
		node.left = left
		node.right = right
		return node, true
	case ^Alg_Minus:
		left := plan_build(b, v.left) or_return
		right, right_ok := plan_build(b, v.right)
		if !right_ok {
			plan_destroy(left, b.allocator)
			return nil, false
		}
		materialized := new(Plan_Materialized, b.allocator)
		materialized.input = right
		node := new(Plan_Minus, b.allocator)
		node.left = left
		node.right = materialized
		return node, true
	case ^Alg_Graph:
		// GRAPH swaps the graph position every triple pattern below
		// matches in, and restores it afterwards: the clause is scoped,
		// and a pattern outside it still means the default graph.
		outer := b.graph
		defer b.graph = outer
		ref, ref_ok, present := graph_ref(b, v.graph)
		if !ref_ok {
			return nil, false
		}
		if !present {
			return new(Plan_Nothing, b.allocator), true
		}
		b.graph = ref
		inner := plan_build(b, v.input) or_return
		if plan_ref_is_var(ref) && !plan_matches_triples(inner) {
			scan := new(Plan_Graph_Scan, b.allocator)
			scan.slot = ref.slot
			node := new(Plan_Join, b.allocator)
			node.left = scan
			node.right = scoped(b, inner)
			return node, true
		}
		return inner, true
	case ^Alg_Extend:
		for binding in v.bindings {
			if !expr_check(b, binding.expr) {
				return nil, false
			}
		}
		input := plan_build(b, v.input) or_return
		node := new(Plan_Extend, b.allocator)
		node.slots = make([dynamic]int, b.allocator)
		node.exprs = make([dynamic]Expr, b.allocator)
		for binding in v.bindings {
			append(&node.slots, var_slot(b.slots, binding.v.name))
			append(&node.exprs, binding.expr)
		}
		node.input = input
		return node, true
	case ^Alg_Group:
		b.unsupported = "GROUP BY"
	case ^Alg_Order:
		b.unsupported = "ORDER BY"
	case nil:
		b.unsupported = "empty algebra"
	}
	return nil, false
}

// join_plans is the one plan simplification this task makes: the join
// of two basic graph patterns is a basic graph pattern. It matters more
// than it looks — the translation emits Join(BGP, BGP) for patterns
// written as separate triple blocks, and running those as a general
// join instead of one probe chain would turn an index lookup into a
// cross product.
//
// Any other join is a join of something that is not a BGP, which in
// this engine means a subquery — reported unsupported rather than
// approximated, and implemented with the rest of the operators in
// SPARQL-T-0013.
@(private = "file")
join_plans :: proc(b: ^Plan_Builder, left, right: Plan) -> (p: Plan, ok: bool) {
	// A join with the unit table is the other side, unchanged.
	// Each of these simplifications drops one side, which has to be
	// released — plan nodes are allocated as they are built, not at the
	// end, so a discarded sub-plan is a leak unless it is freed here.
	if _, is_unit := left.(^Plan_Unit); is_unit {
		plan_destroy(left, b.allocator)
		return right, true
	}
	if _, is_unit := right.(^Plan_Unit); is_unit {
		plan_destroy(right, b.allocator)
		return left, true
	}
	// A join with an unsatisfiable side is unsatisfiable.
	if _, is_nothing := left.(^Plan_Nothing); is_nothing {
		plan_destroy(right, b.allocator)
		return left, true
	}
	if _, is_nothing := right.(^Plan_Nothing); is_nothing {
		plan_destroy(left, b.allocator)
		return right, true
	}
	left_bgp, left_is_bgp := left.(^Plan_BGP)
	right_bgp, right_is_bgp := right.(^Plan_BGP)
	if left_is_bgp && right_is_bgp {
		for t in right_bgp.triples {
			append(&left_bgp.triples, t)
		}
		clear(&left_bgp.order)
		join_order(left_bgp)
		// The right pattern's node has been absorbed, not kept.
		discard_bgp(right_bgp, b.allocator)
		return left_bgp, true
	}
	node := new(Plan_Join, b.allocator)
	node.left = left
	// A side that establishes its own scope — a subquery, which shows up
	// as a projection — cannot be correlated: its variables are bound
	// inside it and the enclosing solution must not reach in. Such a side
	// is materialized once and joined against.
	node.right = scoped(b, right)
	return node, true
}

// scoped decides how a join's right side is evaluated, and it is the
// most consequential decision in plan building.
//
// Running the right side with the left's bindings already in the row —
// correlating it — is what turns a join into an index probe, and it is
// what makes this engine fast. It is also *wrong* in general. SPARQL
// evaluates a join's operands independently and then merges compatible
// solutions; pre-binding a variable changes what the right side computes
// unless the right side is a pure pattern, where restricting the search
// and filtering the results come to the same thing.
//
// Where it is not the same thing:
//
//   - `{ :x :p ?v } { FILTER(?v = 1) }` — inside the second group ?v is
//     not in scope, so the filter errors and the group has no solutions.
//     Correlated, the filter sees ?v bound and succeeds.
//   - `?X :name "paul" { ?Y :name "george" OPTIONAL { ?X :email ?Z } }` —
//     evaluated independently the OPTIONAL binds ?X to whoever has an
//     email, and the join then fails on the mismatch. Correlated, the
//     OPTIONAL is restricted to paul's email, finds none, and emits the
//     left row — a solution the spec does not have.
//
// So a right side is correlated only when it is built from patterns
// (basic graph patterns, unions and joins of them, inline tables), plus
// filters whose variables the subtree itself binds. Anything else —
// OPTIONAL, MINUS, BIND, a subquery's projection — is materialized and
// merged. See probe_safe.
@(private = "file")
scoped :: proc(b: ^Plan_Builder, p: Plan) -> Plan {
	if probe_safe(b, p) {
		return p
	}
	node := new(Plan_Materialized, b.allocator)
	node.input = p
	return node
}

// probe_safe reports whether pre-binding a variable can change what a
// sub-plan computes. A pure pattern is safe: matching with a binding
// already in place yields exactly the solutions that matching without it
// and then filtering would. A filter is safe only if every variable it
// mentions is one the sub-plan itself binds — otherwise the enclosing
// bindings are the difference between a type error and a value.
@(private = "file")
probe_safe :: proc(b: ^Plan_Builder, p: Plan) -> bool {
	bindable := make([]bool, var_slots_count(b.slots), context.temp_allocator)
	plan_bindable(p, bindable)
	return probe_safe_under(b, p, bindable)
}

@(private = "file")
probe_safe_under :: proc(b: ^Plan_Builder, p: Plan, bindable: []bool) -> bool {
	switch v in p {
	case ^Plan_BGP, ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan:
		return true
	case ^Plan_Filter:
		for condition in v.conditions {
			if !expr_within(b.slots, condition, bindable) {
				return false
			}
		}
		return probe_safe_under(b, v.input, bindable)
	case ^Plan_Project, ^Plan_Distinct, ^Plan_Slice, ^Plan_Extend, ^Plan_Left_Join, ^Plan_Minus, ^Plan_Materialized:
		return false
	case ^Plan_Union:
		return probe_safe_under(b, v.left, bindable) && probe_safe_under(b, v.right, bindable)
	case ^Plan_Join:
		return probe_safe_under(b, v.left, bindable) && probe_safe_under(b, v.right, bindable)
	}
	return false
}

// plan_matches_triples reports whether a sub-plan has a triple pattern
// anywhere in it — that is, whether anything in it carries the graph
// position and can bind a GRAPH variable by matching.
@(private = "file")
plan_matches_triples :: proc(p: Plan) -> bool {
	switch v in p {
	case ^Plan_BGP:
		return len(v.triples) > 0
	case ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan:
		return false
	case ^Plan_Filter:
		return plan_matches_triples(v.input)
	case ^Plan_Project:
		return plan_matches_triples(v.input)
	case ^Plan_Distinct:
		return plan_matches_triples(v.input)
	case ^Plan_Slice:
		return plan_matches_triples(v.input)
	case ^Plan_Extend:
		return plan_matches_triples(v.input)
	case ^Plan_Materialized:
		return plan_matches_triples(v.input)
	case ^Plan_Union:
		return plan_matches_triples(v.left) || plan_matches_triples(v.right)
	case ^Plan_Join:
		return plan_matches_triples(v.left) || plan_matches_triples(v.right)
	case ^Plan_Left_Join:
		return plan_matches_triples(v.left) || plan_matches_triples(v.right)
	case ^Plan_Minus:
		return plan_matches_triples(v.left)
	}
	return false
}

// plan_bindable marks the slots a sub-plan can bind on its own.
@(private = "file")
plan_bindable :: proc(p: Plan, out: []bool) {
	switch v in p {
	case ^Plan_BGP:
		for triple in v.triples {
			for position in triple {
				if plan_ref_is_var(position) && position.slot < len(out) {
					out[position.slot] = true
				}
			}
		}
	case ^Plan_Table:
		for slot in v.slots {
			if slot >= 0 && slot < len(out) {
				out[slot] = true
			}
		}
	case ^Plan_Nothing, ^Plan_Unit:
	case ^Plan_Graph_Scan:
		if v.slot >= 0 && v.slot < len(out) {
			out[v.slot] = true
		}
	case ^Plan_Filter:
		plan_bindable(v.input, out)
	case ^Plan_Distinct:
		plan_bindable(v.input, out)
	case ^Plan_Slice:
		plan_bindable(v.input, out)
	case ^Plan_Materialized:
		plan_bindable(v.input, out)
	case ^Plan_Project:
		for slot in v.slots {
			if slot >= 0 && slot < len(out) {
				out[slot] = true
			}
		}
	case ^Plan_Extend:
		plan_bindable(v.input, out)
		for slot in v.slots {
			if slot >= 0 && slot < len(out) {
				out[slot] = true
			}
		}
	case ^Plan_Union:
		plan_bindable(v.left, out)
		plan_bindable(v.right, out)
	case ^Plan_Join:
		plan_bindable(v.left, out)
		plan_bindable(v.right, out)
	case ^Plan_Left_Join:
		plan_bindable(v.left, out)
		plan_bindable(v.right, out)
	case ^Plan_Minus:
		plan_bindable(v.left, out)
	}
}

// graph_ref resolves a GRAPH clause's graph designator: a variable
// binds to whichever graph matched, an IRI names one.
@(private = "file")
graph_ref :: proc(b: ^Plan_Builder, node: Pattern_Node) -> (ref: Plan_Ref, ok: bool, present: bool) {
	#partial switch v in node {
	case Var:
		return Plan_Ref{slot = var_slot(b.slots, v.name)}, true, true
	case rdf.IRI:
		return ground_ref(b, v)
	}
	b.unsupported = "GRAPH designator"
	return {}, false, false
}

@(private = "file")
build_table :: proc(b: ^Plan_Builder, t: ^Alg_Table) -> (p: Plan, ok: bool) {
	table := new(Plan_Table, b.allocator)
	table.rows = make([dynamic][dynamic]Plan_Table_Cell, b.allocator)
	table.slots = make([dynamic]int, b.allocator)
	for variable in t.vars {
		append(&table.slots, var_slot(b.slots, variable.name))
	}
	for source_row in t.rows {
		row := make([dynamic]Plan_Table_Cell, b.allocator)
		for cell, i in source_row {
			if i >= len(table.slots) {
				break
			}
			out := Plan_Table_Cell {
				slot = table.slots[i],
			}
			#partial switch v in cell {
			case rdf.IRI:
				out.id, _, out.bound = ground_ref_id(b, v)
				out.absent = !out.bound
				out.term = v
			case rdf.Literal:
				out.id, _, out.bound = ground_ref_id(b, v)
				out.absent = !out.bound
				out.term = v
			case nil:
			// UNDEF: the cell binds nothing, and that is an answer.
			case:
				delete(row)
				for built in table.rows {
					delete(built)
				}
				delete(table.rows)
				delete(table.slots)
				free(table, b.allocator)
				b.unsupported = "VALUES cell"
				return nil, false
			}
			append(&row, out)
		}
		append(&table.rows, row)
	}
	return table, true
}

@(private = "file")
ground_ref_id :: proc(b: ^Plan_Builder, term: rdf.Term) -> (id: store.Term_ID, ok: bool, present: bool) {
	ref, ref_ok, ref_present := ground_ref(b, term)
	return ref.id, ref_ok, ref_present
}

@(private = "file")
build_bgp :: proc(b: ^Plan_Builder, bgp: ^Alg_BGP) -> (p: Plan, ok: bool) {
	plan := new(Plan_BGP, b.allocator)
	plan.triples = make([dynamic]Plan_Triple, b.allocator)
	plan.order = make([dynamic]int, b.allocator)

	for triple in bgp.triples {
		t: Plan_Triple
		positions := [3]Pattern_Node{triple.subject, triple.predicate, triple.object}
		for node, i in positions {
			ref, ref_ok, present := plan_ref(b, node)
			if !ref_ok {
				discard_bgp(plan, b.allocator)
				return nil, false
			}
			if !present {
				// A ground term the store does not hold: this pattern,
				// and therefore this BGP, matches nothing.
				discard_bgp(plan, b.allocator)
				return new(Plan_Nothing, b.allocator), true
			}
			t[i] = ref
		}
		t[store.QUAD_G] = b.graph
		append(&plan.triples, t)
	}
	join_order(plan)
	return plan, true
}

// plan_ref resolves one pattern position. present is false when the
// position is a ground term the store does not hold.
@(private = "file")
discard_bgp :: proc(plan: ^Plan_BGP, allocator: runtime.Allocator) {
	delete(plan.triples)
	delete(plan.order)
	free(plan, allocator)
}

@(private = "file")
plan_ref :: proc(b: ^Plan_Builder, node: Pattern_Node) -> (ref: Plan_Ref, ok: bool, present: bool) {
	switch v in node {
	case Var:
		return Plan_Ref{slot = var_slot(b.slots, v.name)}, true, true
	case rdf.Blank_Node:
		return Plan_Ref{slot = blank_slot(b.slots, string(v))}, true, true
	case rdf.IRI:
		return ground_ref(b, v)
	case rdf.Literal:
		return ground_ref(b, v)
	case ^Triple_Term:
		b.unsupported = "triple term pattern"
		return {}, false, false
	case ^Path_Expr:
		b.unsupported = "property path"
		return {}, false, false
	}
	b.unsupported = "empty pattern position"
	return {}, false, false
}

@(private = "file")
ground_ref :: proc(b: ^Plan_Builder, term: rdf.Term) -> (ref: Plan_Ref, ok: bool, present: bool) {
	id, found := b.find(b.data, term)
	if !found {
		return {}, true, false
	}
	// A dictionary never assigns a Sentinel-tagged ID, so a ground term
	// resolving to one would mean the sentinel space had leaked into the
	// dictionary — a bug worth failing on rather than matching against.
	assert(store.id_kind(id) != .Sentinel, "find_term returned a reserved sentinel ID")
	return Plan_Ref{slot = -1, id = id}, true, true
}

// join_order fills a BGP's evaluation order. This is the planner seam:
// the whole of the engine's join-ordering policy lives in this one
// procedure, and today it is the order the patterns were written in.
// Cost-based ordering waits for the store to be able to estimate
// cardinality (an initiative-level upstream proposal); nothing above
// here assumes the identity permutation.
@(private = "file")
join_order :: proc(plan: ^Plan_BGP) {
	for i in 0 ..< len(plan.triples) {
		append(&plan.order, i)
	}
}

// plan_destroy frees a plan tree.
plan_destroy :: proc(p: Plan, allocator := context.allocator) {
	switch v in p {
	case ^Plan_BGP:
		delete(v.triples)
		delete(v.order)
		free(v, allocator)
	case ^Plan_Nothing:
		free(v, allocator)
	case ^Plan_Unit:
		free(v, allocator)
	case ^Plan_Project:
		delete(v.slots)
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Distinct:
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Slice:
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Filter:
		delete(v.conditions)
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Union:
		plan_destroy(v.left, allocator)
		plan_destroy(v.right, allocator)
		free(v, allocator)
	case ^Plan_Left_Join:
		delete(v.conditions)
		plan_destroy(v.left, allocator)
		plan_destroy(v.right, allocator)
		free(v, allocator)
	case ^Plan_Minus:
		plan_destroy(v.left, allocator)
		plan_destroy(v.right, allocator)
		free(v, allocator)
	case ^Plan_Join:
		plan_destroy(v.left, allocator)
		plan_destroy(v.right, allocator)
		free(v, allocator)
	case ^Plan_Extend:
		delete(v.slots)
		delete(v.exprs)
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Table:
		for row in v.rows {
			delete(row)
		}
		delete(v.rows)
		delete(v.slots)
		free(v, allocator)
	case ^Plan_Materialized:
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Graph_Scan:
		free(v, allocator)
	}
}
