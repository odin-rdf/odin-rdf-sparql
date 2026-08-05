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

Plan :: union {
	^Plan_BGP,
	^Plan_Nothing,
	^Plan_Unit,
	^Plan_Project,
	^Plan_Distinct,
	^Plan_Slice,
	^Plan_Filter,
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
	graph:       store.Term_ID,
	unsupported: string,
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
	b.graph = store.DEFAULT_GRAPH
	b.allocator = allocator
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
		b.unsupported = "VALUES"
		return nil, false
	case ^Alg_Join:
		left := plan_build(b, v.left) or_return
		right := plan_build(b, v.right) or_return
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
		b.unsupported = "OPTIONAL"
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
		b.unsupported = "UNION"
	case ^Alg_Minus:
		b.unsupported = "MINUS"
	case ^Alg_Graph:
		b.unsupported = "GRAPH"
	case ^Alg_Extend:
		b.unsupported = "BIND"
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
	if _, is_unit := left.(^Plan_Unit); is_unit {
		return right, true
	}
	if _, is_unit := right.(^Plan_Unit); is_unit {
		return left, true
	}
	// A join with an unsatisfiable side is unsatisfiable.
	if _, is_nothing := left.(^Plan_Nothing); is_nothing {
		return left, true
	}
	if _, is_nothing := right.(^Plan_Nothing); is_nothing {
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
		return left_bgp, true
	}
	b.unsupported = "join of a non-basic pattern (subquery)"
	return nil, false
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
		t[store.QUAD_G] = Plan_Ref{slot = -1, id = b.graph}
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
	}
}
