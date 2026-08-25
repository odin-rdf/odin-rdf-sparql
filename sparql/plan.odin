// The evaluation plan: the bridge from the §18 algebra to something a
// store can execute (SPARQL-T-0011).
//
// Two things happen here, once per query, before any matching does.
//
// **Variables become slots.** Every variable and every blank node in the
// pattern is assigned a dense integer slot, and a solution is a flat
// `[]record.Term_ID` indexed by slot — not a map. Joining and
// deduplicating solutions is then integer comparison, which is the whole
// point of evaluating over Term_IDs. Blank nodes get slots too: in a
// pattern a blank node *is* a variable, just one the query cannot name
// or project.
//
// **Ground terms become IDs.** Every IRI and literal written in the
// query is resolved against the target store's dictionary, once. This
// goes through record's non-interning `snapshot_resolve`, so a query
// never assigns an ID and never turns a read into a write — on a
// persistent backend, asking about a term the store has never seen must
// not make it a term the store has seen. A ground term the store does
// not hold makes its triple pattern unsatisfiable, and the plan collapses
// to Plan_Nothing rather than scanning for something that cannot be
// there.
//
// ~~The resolver is a procedure pointer. That is a deliberate exception
// to the no-dynamic-dispatch rule and a safe one: it is called a handful
// of times per query, at setup, never per solution. The hot path —
// matching — is bound at compile time instead; see exec.odin.~~
// **`Term_Finder` is gone** (`SPARQL-T-0031`): the builder holds the
// snapshot the evaluation will read and calls record directly. There is
// no procedure pointer left here to make an exception for.
//
// **And a third thing happens, since `SPARQL-T-0037`: patterns are
// priced.** `join_order` asks the same snapshot how many candidates each
// of a BGP's patterns can have — exactly, in O(1) — and orders them
// cheapest-first among those connected to what is already bound. That is
// the only place the planner reads data rather than the query.
package sparql

import "base:runtime"
import "core:strings"

import rdf "rdf:rdf"
import record "record:record"

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

// var_slots_init prepares an empty slot table; everything it owns comes
// from the given allocator. A prepared query holds one for its lifetime.
var_slots_init :: proc(vs: ^Var_Slots, allocator := context.allocator) {
	vs.allocator = allocator
	vs.names = make([dynamic]string, allocator)
	vs.internal = make([dynamic]bool, allocator)
	vs.index = make(map[string]int, allocator)
}

// var_slots_destroy frees the table. Every slice it handed out — the
// names an answer is labelled with — becomes invalid, so it is destroyed
// after the answer has been read, not before.
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
//
// A variable the path translation invented gets an internal slot: it is
// fresh, which is to say not in scope, so it behaves like a pattern blank
// node and never reaches an answer. See PATH_VAR_PREFIX.
var_slot :: proc(vs: ^Var_Slots, name: string) -> int {
	return slot_for(vs, "?", name, strings.has_prefix(name, PATH_VAR_PREFIX))
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

// PATH_SLOT_NAME is the name every slot the path compiler invents carries.
// The name is shared and the slots are not: a fresh slot bypasses the index
// map entirely, so two of them can be called the same thing without becoming
// the same thing. Nothing looks these up by name — they are marked internal,
// which is what keeps them out of `SELECT *` and out of var_slot_lookup —
// so the name exists only to make a plan dump readable.
PATH_SLOT_NAME :: "!path"

// fresh_internal_slot returns a slot for a variable the engine invented
// rather than the query. It is never findable by name and never projected.
fresh_internal_slot :: proc(vs: ^Var_Slots) -> int {
	slot := len(vs.names)
	append(&vs.names, PATH_SLOT_NAME)
	append(&vs.internal, true)
	return slot
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
	id:   record.Term_ID,
}

// plan_ref_is_var distinguishes the two: a slot to unify against, or a
// ground ID to match exactly.
plan_ref_is_var :: proc(r: Plan_Ref) -> bool {
	return r.slot >= 0
}

// Plan_Triple is a quad pattern over slots and IDs, indexed by
// QUAD_S/P/O/G. The graph position is filled from the plan's
// active graph — DEFAULT_GRAPH outside a GRAPH clause.
Plan_Triple :: distinct [4]Plan_Ref

// Plan_Term_Shape is a triple-term pattern that is not ground: what a
// matched triple term's components have to be for the pattern to hold.
//
// slot is a fresh internal slot the matched term's ID lands in — the
// position in the enclosing triple pattern *is* that slot, so the
// ordinary unification binds it and the shape reads it back. parts are
// the components, each a slot to unify or a ground ID to equal; a
// component that is itself a non-ground triple term is the slot of its
// own shape, which is listed after this one and reads it the same way.
Plan_Term_Shape :: struct {
	slot:  int,
	parts: [3]Plan_Ref,
}

// Plan_BGP is a basic graph pattern to be evaluated as a chain of
// index probes: for each pattern in join order, substitute what the
// row already binds and match.
//
// order is the join order — the one place a future planner replaces.
// Today it is the identity permutation (patterns in the order written),
// which is what "naive fixed join order" means; nothing else in the
// engine assumes anything about it.
//
// shapes holds the triple-term decompositions the patterns need, with
// shape_range naming each pattern's slice of them (parallel to triples,
// indexed the same way — by pattern, not by depth). Within a slice a
// parent precedes its children, so one forward pass fills every nested
// slot before the shape that reads it is reached. Both are empty for a
// pattern with no non-ground triple term, which is every SPARQL 1.1
// query.
Plan_BGP :: struct {
	triples:     [dynamic]Plan_Triple,
	order:       [dynamic]int,
	shapes:      [dynamic]Plan_Term_Shape,
	shape_range: [dynamic][2]int,
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
	id:     record.Term_ID,
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

// Plan_Graph_Bind is the second half of §18.5's Graph(var, P):
//
//     for each IRI i in D:  R := Union(R, Join(eval(D(D[i]), P), Ω(?var→i)))
//
// The engine evaluates the `for each` by putting `graph` — a slot of its
// own, never the query's ?g — in the graph position of every triple
// pattern of P and letting the index enumerate. This node is the `Join`
// with Ω(?var→i) that follows: it binds ?g to the graph the solution was
// found in, or drops the solution when P bound ?g to something else.
//
// The two slots are the whole point, and the reason is one line of the
// specification: **?g is not in scope inside the clause.** Inside P the
// triple patterns match a plain graph, so an occurrence of ?g there is an
// ordinary variable bound by a subject, predicate or object position, and
// the graph it was found in reaches it only through the join above. The
// suite says the same thing three times — `graph-variable-scope` ("the
// variable bound by the GRAPH operator is not in-scope inside it"),
// `graph-optional` ("…is not used when evaluating a nested OPTIONAL") and
// `graph-minus` ("outer GRAPH operator does not affect MINUS
// disjointness") — and the last two are what this node was built for.
//
// Binding ?g in the graph position directly, which is what this engine
// did before, is the same computation only while P is a pure pattern.
// Where it is not:
//
//   - `GRAPH ?g { ?s ?p ?o OPTIONAL { ?s ?p ?g } }` — pushed down, the
//     OPTIONAL demands that a triple's object equal its own graph, which
//     almost never holds, so it never matches and every left solution
//     survives with ?g bound. Correctly, the OPTIONAL binds ?g from the
//     *object* and the join above then drops every solution whose object
//     is not the graph IRI. `graph-optional` pins it: four solutions
//     become the one whose object is `<>`.
//   - `GRAPH ?g { ?a :p :o MINUS { ?b :p :o } }` — pushed down, ?g is in
//     both sides' domains, so they are no longer disjoint and MINUS
//     removes what it should have left alone. `graph-minus` pins it.
//
// The internal slot is still in both sides' rows, and is still what
// confines MINUS's right side to one graph, but it is not a variable: see
// minus_excluded, which counts only query variables as shared.
//
// slot is pre-bound rather than post-checked when the enclosing solution
// already bound ?g — `?d :graph ?g . GRAPH ?g { … }`. That is the same
// join done early, and it is what keeps the graph position an index probe
// instead of a scan of every graph followed by a filter.
Plan_Graph_Bind :: struct {
	slot:  int, // the query's ?g
	graph: int, // the internal slot P's triple patterns match in
	input: Plan,
}

// Plan_Group_Key is one GROUP BY condition: the expression that
// computes the key, and the slot its value binds in the group's output
// solution.
//
// slot is -1 for a condition that binds nothing — `GROUP BY (?x + 1)`
// without an AS, which partitions the solutions and then has no name to
// hand the key back under. A bare `GROUP BY ?x` binds ?x, and
// `GROUP BY (expr AS ?y)` binds ?y.
//
// source is the slot to read the key straight out of the solution row,
// for the common case where the condition *is* a variable. Then the key
// is a Term_ID and grouping is integer comparison — a term is never
// materialized, which is the whole reason the engine evaluates over IDs.
// It is -1 when the condition is an expression, whose value has to be
// computed and compared as the term it would bind.
Plan_Group_Key :: struct {
	slot:   int,
	source: int,
	expr:   Expr,
}

// Plan_Aggregate is one set function and the slot it binds. The slot
// carries the ".N" variable the translation invented (§18.2.4.1's
// aggregate substitution), which the SELECT expressions, HAVING, and
// ORDER BY were rewritten to read.
Plan_Aggregate :: struct {
	slot: int,
	agg:  ^Aggregate,
}

// Plan_Group is GROUP BY and the aggregates over it (§18.5.1).
//
// It is a blocking operator: no group's answer exists until the last
// solution has been seen. What it does *not* do is buffer the
// solutions — one accumulator per aggregate per group, fed one solution
// at a time, so the memory is the number of groups and not the size of
// the input (see aggregate.odin).
//
// An empty key list is the implicit grouping of §18.2.4.1: an aggregate
// used without GROUP BY puts every solution in one group, and that group
// exists even when there are no solutions at all. `SELECT (COUNT(*) AS
// ?c) WHERE { … }` over data that matches nothing answers 0, not
// nothing.
Plan_Group :: struct {
	keys:       [dynamic]Plan_Group_Key,
	aggregates: [dynamic]Plan_Aggregate,
	input:      Plan,
}

// Plan_Order is ORDER BY (§15.1). Also blocking, and unavoidably so:
// unlike a group it has to hold every solution, because the last one may
// sort first.
//
// The slice above it is a separate operator, exactly as §18.2.5 layers
// them. A LIMIT does not shorten the sort — correctness first; the
// evidence log records that an ordered store iterator would let a
// top-N query stream (SPARQL-T-0019).
Plan_Order :: struct {
	conditions: [dynamic]Order_Condition,
	input:      Plan,
}

// Plan_Materialized is a sub-plan whose solutions are collected once,
// before the query runs, because its consumer needs them independently
// of the enclosing bindings: MINUS's right side, and a subquery, whose
// variables are scoped to itself.
// correlated inverts the "once" for the one case that needs it: a
// blocking operator under GRAPH ?g, which has to be evaluated afresh for
// each graph. Then the sub-plan is still collected — its solutions are
// still merged into the enclosing row rather than replacing it, which is
// what keeps ?g bound through a subquery's projection — but the
// collection happens per enclosing solution instead of once.
Plan_Materialized :: struct {
	input:      Plan,
	correlated: bool,
}

// Plan_Path_End is one endpoint of a property-path pattern: a variable
// slot, or a ground term.
//
// It exists because a path endpoint cannot use Plan_Ref's rule that a
// ground term the store does not hold makes the pattern unsatisfiable. A
// zero-length path binds its endpoint to itself whether or not the data
// has ever mentioned it — `:s :p* ?o` over the empty graph answers
// `?o = :s`, which the suite pins as `zero_or_more_set_end`. So an absent
// term is carried as the term it is and named with a synthetic ID when
// the execution is built, exactly as a VALUES cell naming an unknown term
// is.
Plan_Path_End :: struct {
	slot:   int, // >= 0: a variable slot; < 0: ground, use id
	id:     record.Term_ID,
	// A ground term the store does not hold. id is filled in at exec
	// setup; term borrows the query's parse, which outlives the plan.
	absent: bool,
	term:   rdf.Term,
}

// Plan_NPS is a negated property set in one direction: every triple whose
// predicate is *not* one of the excluded IDs.
//
// One direction, because §18.4's negated set with both forward and
// inverse members is the union of two of them — `!(:a|^:b)` is
// "everything but :a forwards" union "everything but :b backwards", and
// not "everything but both in both directions". Plan building emits the
// union; this node is one side of it.
//
// A member the store does not hold is dropped rather than kept: it cannot
// equal any predicate in the data, so excluding it excludes nothing.
Plan_NPS :: struct {
	subject:  Plan_Ref,
	object:   Plan_Ref,
	graph:    Plan_Ref,
	excluded: [dynamic]record.Term_ID,
	// inverse swaps which quad position each end matches: the subject end
	// against the object position and back.
	inverse:  bool,
}

// Plan_Path is §18.4's three repeat forms — `?`, `*`, `+` — as one
// operator over two flags: whether the zero-length path counts
// (`include_start`, for `?` and `*`) and whether the step is followed
// transitively (`closure`, for `*` and `+`).
//
// The operand is compiled as an ordinary sub-plan over two dedicated
// internal slots: `Path(?in, P, ?out)`. Reachability then never has to
// know what a step *is* — binding ?in and reading ?out drives an inner
// path, a sequence, an alternative, or another repeat with no extra case.
// The step is not an input: nothing pulls from it, and the executor runs
// it once per frontier node (see exec.odin).
//
// The whole node is decided by the *pattern*, never by what happens to be
// bound when it runs. When both endpoints are variables the zero-length
// pairs range over the active graph's nodes (§18.4's nodes(G)), and that
// stays true when an enclosing solution has already bound one of them —
// a binding filters the answer, it does not change which definition
// applies. That is what makes the operator safe to correlate, and it is
// what `values_and_path` in the suite is testing.
Plan_Path :: struct {
	subject:       Plan_Path_End,
	object:        Plan_Path_End,
	graph:         Plan_Ref,
	step:          Plan,
	in_slot:       int,
	out_slot:      int,
	include_start: bool,
	closure:       bool,
}

// Plan is one operator of the evaluation plan — the algebra after the
// two things plan building does: variables become slots and ground terms
// become IDs. The tree is owned by whoever built it and freed with
// plan_destroy.
Plan :: union {
	^Plan_BGP,
	^Plan_NPS,
	^Plan_Path,
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
	^Plan_Graph_Bind,
	^Plan_Group,
	^Plan_Order,
}

// Plan_Builder carries what plan construction needs: the slot table
// being filled, the snapshot ground terms resolve against, and the graph
// that triple patterns match in.
//
// unsupported names the first algebra operator this task's evaluator
// does not implement. It is a string rather than a flag so a caller can
// say which operator, and it is reported rather than silently treated as
// an empty result — an operator the engine cannot evaluate must never
// look like a query with no answers.
Plan_Builder :: struct {
	slots:       ^Var_Slots,
	// The dataset a ground term is resolved against — the same snapshot
	// the execution will read, so a term the plan resolved is a term the
	// run can find. Resolving never interns: a query is not a write.
	snapshot:    record.Snapshot,
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
	// Triple terms the builder materialized and a plan node kept: a
	// ground `<<( … )>>` written where the plan holds the term itself
	// rather than only its ID — a VALUES cell, a path endpoint. Only the
	// nodes are owned; the strings inside are the query's.
	terms:        [dynamic]rdf.Term,
	allocator:   runtime.Allocator,
}

// plan_builder_init prepares a builder against a slot table and a
// snapshot. The snapshot must outlive the plans the builder produces,
// and the builder itself must outlive them too — a plan can borrow a
// triple term the builder materialized — so destroy it after
// plan_destroy.
plan_builder_init :: proc(
	b: ^Plan_Builder,
	slots: ^Var_Slots,
	snapshot: record.Snapshot,
	allocator := context.allocator,
) {
	b.slots = slots
	b.snapshot = snapshot
	// A pattern's graph position, so this is the pattern-side constant
	// (record.MATCH_DEFAULT_GRAPH) and never the 0 a fact carries.
	b.graph = Plan_Ref{slot = -1, id = DEFAULT_GRAPH}
	b.exists_nodes = make([dynamic]^Exists_Expr, allocator)
	b.exists_plans = make([dynamic]Plan, allocator)
	b.terms = make([dynamic]rdf.Term, allocator)
	b.allocator = allocator
}

// plan_builder_destroy releases the builder's own bookkeeping. The plans
// it produced belong to the caller — but the triple terms they borrow
// are the builder's, so it must outlive them.
plan_builder_destroy :: proc(b: ^Plan_Builder) {
	delete(b.exists_nodes)
	delete(b.exists_plans)
	for term in b.terms {
		triple_term_free(term, b.allocator)
	}
	delete(b.terms)
}

// builder_term materializes a ground triple term the builder will own,
// for a plan node that keeps the term and not only its ID.
@(private = "file")
builder_term :: proc(b: ^Plan_Builder, tt: ^Triple_Term) -> rdf.Term {
	term := triple_term_term(tt, b.allocator)
	append(&b.terms, term)
	return term
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
		subject, subject_ok := path_end(b, v.subject)
		if !subject_ok {
			return nil, false
		}
		object, object_ok := path_end(b, v.object)
		if !object_ok {
			return nil, false
		}
		return build_path(b, subject, v.path, object)
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
		if !plan_ref_is_var(ref) {
			// GRAPH <iri> names one graph and binds nothing. §18.5 reads
			// it as eval(D(D[iri]), P), which is the swap and no more.
			b.graph = ref
			return plan_build(b, v.input)
		}
		// GRAPH ?g is §18.5's `for each IRI i in D` and the join with
		// Ω(?g→i) that follows it. The body matches in a slot of the
		// engine's own so that ?g stays out of scope inside it, exactly as
		// the specification has it, and Plan_Graph_Bind performs the join
		// on the way out. See Plan_Graph_Bind for the two entries that
		// pin the difference.
		inner_slot := fresh_internal_slot(b.slots)
		b.graph = Plan_Ref{slot = inner_slot, id = UNBOUND}
		inner := plan_build(b, v.input) or_return
		body := inner
		if !plan_matches_triples(inner) {
			// Nothing in the body carries the graph position — `GRAPH ?g
			// {}`, or a body that is only a VALUES block — so there is
			// nothing to enumerate the graphs by matching, and the clause
			// still ranges over them. Then they are enumerated.
			scan := new(Plan_Graph_Scan, b.allocator)
			scan.slot = inner_slot
			node := new(Plan_Join, b.allocator)
			node.left = scan
			node.right = scoped(b, inner)
			body = node
		} else if plan_blocks(inner) {
			// A blocking operator under GRAPH ?g has to run once per
			// graph, and having the triple patterns carry the graph
			// position does not achieve that: the pattern would match
			// every graph and the group or the sort would collapse them
			// into one answer. So the graphs are enumerated and the body
			// is run against each.
			//
			// It is materialized *correlated*: collected once per graph
			// rather than once per query. Collecting is what makes the
			// body's solutions merge into the enclosing row instead of
			// replacing it — a subquery projects its own variables and
			// nothing else, so its rows would otherwise arrive with the
			// graph masked back out. The trade is deliberate and narrow:
			// the body's own variables are correlated too, which a
			// subquery's scoping says they should not be, and the
			// alternative is a wrong answer for every query of this shape.
			scan := new(Plan_Graph_Scan, b.allocator)
			scan.slot = inner_slot
			collected := new(Plan_Materialized, b.allocator)
			collected.input = inner
			collected.correlated = true
			node := new(Plan_Join, b.allocator)
			node.left = scan
			node.right = collected
			body = node
		} else if plan_has_path(inner) {
			// A path operator reads the active graph rather than binding
			// it, so a body holding one needs the graph bound before it
			// runs even when the body also has triple patterns that could
			// have bound it themselves. See plan_has_path.
			scan := new(Plan_Graph_Scan, b.allocator)
			scan.slot = inner_slot
			node := new(Plan_Join, b.allocator)
			node.left = scan
			node.right = scoped(b, inner)
			body = node
		}
		bind := new(Plan_Graph_Bind, b.allocator)
		bind.slot = ref.slot
		bind.graph = inner_slot
		bind.input = body
		return bind, true
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
		return build_group(b, v)
	case ^Alg_Order:
		for condition in v.conditions {
			if !expr_check(b, condition.expr) {
				return nil, false
			}
		}
		input := plan_build(b, v.input) or_return
		node := new(Plan_Order, b.allocator)
		node.conditions = make([dynamic]Order_Condition, b.allocator)
		for condition in v.conditions {
			append(&node.conditions, condition)
		}
		node.input = input
		return node, true
	case nil:
		b.unsupported = "empty algebra"
	}
	return nil, false
}

// build_group turns the algebra's Group into a plan, resolving each
// grouping condition's output variable and each aggregate's ".N" slot.
//
// A condition's output slot follows §18.2.4.1's rewriting: `(expr AS
// ?y)` names ?y, a bare variable names itself, and a bare expression
// names nothing — the grammar refuses to let such a group's key be
// projected, so there is nothing to bind it to.
@(private = "file")
build_group :: proc(b: ^Plan_Builder, g: ^Alg_Group) -> (p: Plan, ok: bool) {
	for condition in g.by {
		if !expr_check(b, condition.expr) {
			return nil, false
		}
	}
	for binding in g.aggregates {
		aggregate, is_aggregate := binding.expr.(^Aggregate)
		if !is_aggregate {
			b.unsupported = "aggregate binding"
			return nil, false
		}
		if aggregate.expr != nil && !expr_check(b, aggregate.expr) {
			return nil, false
		}
	}
	input := plan_build(b, g.input) or_return
	node := new(Plan_Group, b.allocator)
	node.keys = make([dynamic]Plan_Group_Key, b.allocator)
	node.aggregates = make([dynamic]Plan_Aggregate, b.allocator)
	for condition in g.by {
		key := Plan_Group_Key {
			slot   = -1,
			source = -1,
			expr   = condition.expr,
		}
		if variable, is_var := condition.expr.(Var); is_var {
			key.source = var_slot(b.slots, variable.name)
			key.slot = key.source
		}
		if condition.has_var {
			key.slot = var_slot(b.slots, condition.v.name)
		}
		append(&node.keys, key)
	}
	for binding in g.aggregates {
		append(
			&node.aggregates,
			Plan_Aggregate{slot = var_slot(b.slots, binding.v.name), agg = binding.expr.(^Aggregate)},
		)
	}
	node.input = input
	return node, true
}

// --- Property paths -------------------------------------------------
//
// §18.4's path expressions, compiled into plan operators. The translation
// already turned the forms that *are* triple patterns into triple
// patterns (a bare link, and the sequences and inverses built from them),
// so what arrives here is an alternative, a negated property set, one of
// the three repeats, or any of those nested inside a repeat's operand.

// path_end resolves one endpoint of a path pattern. Unlike plan_ref it
// has no "absent" answer: a ground term the store does not hold is
// carried as itself, because a zero-length path binds it regardless.
@(private = "file")
path_end :: proc(b: ^Plan_Builder, node: Pattern_Node) -> (end: Plan_Path_End, ok: bool) {
	switch v in node {
	case Var:
		return Plan_Path_End{slot = var_slot(b.slots, v.name)}, true
	case rdf.Blank_Node:
		return Plan_Path_End{slot = blank_slot(b.slots, string(v))}, true
	case rdf.IRI:
		return ground_end(b, v), true
	case rdf.Literal:
		return ground_end(b, v), true
	case ^Triple_Term:
		// A ground triple term is a term like any other, so a path can
		// start or end at one. A non-ground one would need the shape
		// machinery a basic graph pattern has and a path endpoint does
		// not: there is no unification step to hang it on.
		if !triple_term_is_ground(v) {
			b.unsupported = "triple term pattern"
			return {}, false
		}
		// The builder owns the node: an endpoint the store does not hold
		// keeps its term, to be named synthetically when the execution is
		// built.
		return ground_end(b, builder_term(b, v)), true
	case ^Path_Expr:
		b.unsupported = "property path in a path endpoint"
		return {}, false
	}
	b.unsupported = "empty pattern position"
	return {}, false
}

@(private = "file")
ground_end :: proc(b: ^Plan_Builder, term: rdf.Term) -> Plan_Path_End {
	id, found := exec_resolve(b.snapshot, term)
	if !found {
		return Plan_Path_End{slot = -1, absent = true, term = term}
	}
	return Plan_Path_End{slot = -1, id = id}
}

@(private = "file")
slot_end :: proc(slot: int) -> Plan_Path_End {
	return Plan_Path_End{slot = slot}
}

// end_ref narrows a path endpoint to a triple-pattern position. present
// is false for a ground term the store does not hold: a *step* through
// such a term matches nothing, even though a zero-length path over it
// does not.
@(private = "file")
end_ref :: proc(end: Plan_Path_End) -> (ref: Plan_Ref, present: bool) {
	if end.slot >= 0 {
		return Plan_Ref{slot = end.slot}, true
	}
	if end.absent {
		return {}, false
	}
	return Plan_Ref{slot = -1, id = end.id}, true
}

// build_path compiles one path expression between two endpoints.
@(private = "file")
build_path :: proc(
	b: ^Plan_Builder,
	subject: Plan_Path_End,
	path: ^Path_Expr,
	object: Plan_Path_End,
) -> (
	p: Plan,
	ok: bool,
) {
	if path == nil {
		b.unsupported = "empty property path"
		return nil, false
	}
	switch path.op {
	case .Link:
		return build_path_link(b, subject, path.iri, object)
	case .Inverse:
		return build_path(b, object, path.children[0], subject)
	case .Sequence:
		// X (P1/…/Pn) Y — a fresh internal slot joins each pair of steps.
		// The steps are BGPs whenever the parts are links, and join_plans
		// folds those back into one probe chain.
		acc: Plan
		current := subject
		for part, i in path.children {
			target := object
			if i < len(path.children) - 1 {
				target = slot_end(fresh_internal_slot(b.slots))
			}
			step, step_ok := build_path(b, current, part, target)
			if !step_ok {
				plan_destroy(acc, b.allocator)
				return nil, false
			}
			if acc == nil {
				acc = step
			} else {
				joined, joined_ok := join_plans(b, acc, step)
				if !joined_ok {
					return nil, false
				}
				acc = joined
			}
			current = target
		}
		if acc == nil {
			return new(Plan_Unit, b.allocator), true
		}
		return acc, true
	case .Alternative:
		// A union, not a set: `(:p1|:p2)/(:p3|:p4)` answers twice when both
		// alternatives reach the same node, which the suite's path-p2 pins.
		acc: Plan
		for part in path.children {
			branch, branch_ok := build_path(b, subject, part, object)
			if !branch_ok {
				plan_destroy(acc, b.allocator)
				return nil, false
			}
			if acc == nil {
				acc = branch
				continue
			}
			node := new(Plan_Union, b.allocator)
			node.left = acc
			node.right = branch
			acc = node
		}
		if acc == nil {
			return new(Plan_Nothing, b.allocator), true
		}
		return acc, true
	case .Negated_Set:
		return build_path_negated(b, subject, path, object)
	case .Zero_Or_One:
		return build_path_repeat(b, subject, path, object, include_start = true, closure = false)
	case .Zero_Or_More:
		return build_path_repeat(b, subject, path, object, include_start = true, closure = true)
	case .One_Or_More:
		return build_path_repeat(b, subject, path, object, include_start = false, closure = true)
	}
	b.unsupported = "property path operator"
	return nil, false
}

@(private = "file")
build_path_link :: proc(
	b: ^Plan_Builder,
	subject: Plan_Path_End,
	iri: rdf.IRI,
	object: Plan_Path_End,
) -> (
	p: Plan,
	ok: bool,
) {
	subject_ref, subject_present := end_ref(subject)
	object_ref, object_present := end_ref(object)
	predicate_ref, predicate_ok, predicate_present := ground_ref(b, iri)
	if !predicate_ok {
		return nil, false
	}
	if !subject_present || !object_present || !predicate_present {
		return new(Plan_Nothing, b.allocator), true
	}
	plan := new(Plan_BGP, b.allocator)
	plan.triples = make([dynamic]Plan_Triple, b.allocator)
	plan.order = make([dynamic]int, b.allocator)
	plan.shapes = make([dynamic]Plan_Term_Shape, b.allocator)
	plan.shape_range = make([dynamic][2]int, b.allocator)
	triple: Plan_Triple
	triple[QUAD_S] = subject_ref
	triple[QUAD_P] = predicate_ref
	triple[QUAD_O] = object_ref
	triple[QUAD_G] = b.graph
	append(&plan.triples, triple)
	// No triple term can occur in a path step — a path endpoint that is
	// one is ground, and its predicate is an IRI — but the range still
	// has to be there, because merging two patterns reads one per triple.
	append(&plan.shape_range, [2]int{0, 0})
	join_order(b, plan)
	return plan, true
}

// build_path_negated compiles `!(…)`. §18.4 splits the set by direction:
// the forward members and the inverse members are two separate negated
// sets, and the pattern is their union. A set with no inverse members —
// including the empty `!()` — is the forward side alone.
@(private = "file")
build_path_negated :: proc(
	b: ^Plan_Builder,
	subject: Plan_Path_End,
	path: ^Path_Expr,
	object: Plan_Path_End,
) -> (
	p: Plan,
	ok: bool,
) {
	subject_ref, subject_present := end_ref(subject)
	object_ref, object_present := end_ref(object)
	if !subject_present || !object_present {
		return new(Plan_Nothing, b.allocator), true
	}
	forward := make([dynamic]record.Term_ID, b.allocator)
	inverse := make([dynamic]record.Term_ID, b.allocator)
	inverse_members := false
	for member in path.children {
		target := &forward
		iri_node := member
		if member.op == .Inverse {
			target = &inverse
			inverse_members = true
			iri_node = member.children[0]
		}
		if iri_node.op != .Link {
			delete(forward)
			delete(inverse)
			b.unsupported = "negated property set member"
			return nil, false
		}
		// A member the store never saw excludes nothing, so it is dropped
		// rather than kept as an ID that could not match anyway.
		if id, found := exec_resolve(b.snapshot, iri_node.iri); found {
			append(target, id)
		}
	}

	acc: Plan
	if !inverse_members || len(forward) > 0 {
		node := new(Plan_NPS, b.allocator)
		node.subject = subject_ref
		node.object = object_ref
		node.graph = b.graph
		node.excluded = forward
		acc = node
	} else {
		delete(forward)
	}
	if inverse_members {
		node := new(Plan_NPS, b.allocator)
		node.subject = subject_ref
		node.object = object_ref
		node.graph = b.graph
		node.excluded = inverse
		node.inverse = true
		if acc == nil {
			acc = node
		} else {
			union_node := new(Plan_Union, b.allocator)
			union_node.left = acc
			union_node.right = node
			acc = union_node
		}
	} else {
		delete(inverse)
	}
	return acc, true
}

@(private = "file")
build_path_repeat :: proc(
	b: ^Plan_Builder,
	subject: Plan_Path_End,
	path: ^Path_Expr,
	object: Plan_Path_End,
	include_start: bool,
	closure: bool,
) -> (
	p: Plan,
	ok: bool,
) {
	in_slot := fresh_internal_slot(b.slots)
	out_slot := fresh_internal_slot(b.slots)
	step, step_ok := build_path(b, slot_end(in_slot), path.children[0], slot_end(out_slot))
	if !step_ok {
		return nil, false
	}
	node := new(Plan_Path, b.allocator)
	node.subject = subject
	node.object = object
	node.graph = b.graph
	node.step = step
	node.in_slot = in_slot
	node.out_slot = out_slot
	node.include_start = include_start
	node.closure = closure
	return node, true
}

// plan_has_path reports whether a sub-plan holds a property-path operator.
//
// It decides one thing: whether `GRAPH ?g` has to enumerate its graphs.
// A triple pattern carries the graph position and binds ?g by matching, so
// a body made of triple patterns needs no help. A path operator instead
// *reads* the active graph — its traversal and its nodes(G) enumeration
// both have to know which graph they are in before they start — so ?g has
// to be bound before it runs, whatever else the body contains.
@(private = "file")
plan_has_path :: proc(p: Plan) -> bool {
	switch v in p {
	case ^Plan_NPS, ^Plan_Path:
		return true
	case ^Plan_BGP, ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan:
		return false
	case ^Plan_Filter:
		return plan_has_path(v.input)
	case ^Plan_Project:
		return plan_has_path(v.input)
	case ^Plan_Distinct:
		return plan_has_path(v.input)
	case ^Plan_Slice:
		return plan_has_path(v.input)
	case ^Plan_Extend:
		return plan_has_path(v.input)
	case ^Plan_Materialized:
		return plan_has_path(v.input)
	case ^Plan_Graph_Bind:
		// A nested GRAPH clause has bound its own graph already, and a
		// path inside it reads that one. Whether the *enclosing* clause
		// must enumerate is not a question its subtree can answer, so it
		// answers no — for the same reason plan_matches_triples does.
		return false
	case ^Plan_Group:
		return plan_has_path(v.input)
	case ^Plan_Order:
		return plan_has_path(v.input)
	case ^Plan_Union:
		return plan_has_path(v.left) || plan_has_path(v.right)
	case ^Plan_Join:
		return plan_has_path(v.left) || plan_has_path(v.right)
	case ^Plan_Left_Join:
		return plan_has_path(v.left) || plan_has_path(v.right)
	case ^Plan_Minus:
		return plan_has_path(v.left)
	}
	return false
}

// plan_blocks reports whether a sub-plan holds an operator whose answer
// depends on having seen all of its input — which is what makes it wrong
// to run once across several graphs. See the GRAPH case in plan_build.
@(private = "file")
plan_blocks :: proc(p: Plan) -> bool {
	switch v in p {
	case ^Plan_Group, ^Plan_Order:
		return true
	case ^Plan_BGP, ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan, ^Plan_NPS:
		return false
	case ^Plan_Path:
		// The step sub-plan is evaluated inside the traversal, one frontier
		// node at a time, so it is never re-run across graphs on its own.
		return false
	case ^Plan_Filter:
		return plan_blocks(v.input)
	case ^Plan_Project:
		return plan_blocks(v.input)
	case ^Plan_Distinct:
		return plan_blocks(v.input)
	case ^Plan_Slice:
		return plan_blocks(v.input)
	case ^Plan_Extend:
		return plan_blocks(v.input)
	case ^Plan_Materialized:
		return plan_blocks(v.input)
	case ^Plan_Graph_Bind:
		return plan_blocks(v.input)
	case ^Plan_Union:
		return plan_blocks(v.left) || plan_blocks(v.right)
	case ^Plan_Join:
		return plan_blocks(v.left) || plan_blocks(v.right)
	case ^Plan_Left_Join:
		return plan_blocks(v.left) || plan_blocks(v.right)
	case ^Plan_Minus:
		return plan_blocks(v.left)
	}
	return false
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
		// The shapes move with their patterns: a merged pattern keeps its
		// own triple-term decompositions, and its range slides by however
		// many shapes the left side already had.
		base := len(left_bgp.shapes)
		for shape in right_bgp.shapes {
			append(&left_bgp.shapes, shape)
		}
		for t, i in right_bgp.triples {
			append(&left_bgp.triples, t)
			range := right_bgp.shape_range[i]
			append(&left_bgp.shape_range, [2]int{base + range[0], base + range[1]})
		}
		clear(&left_bgp.order)
		join_order(b, left_bgp)
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
	case ^Plan_BGP, ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan, ^Plan_NPS, ^Plan_Path:
		// A path operator is safe to correlate for the same reason a
		// pattern is, and for one more: which of §18.4's cases applies is
		// decided by the pattern's endpoints, not by what is bound when it
		// runs, so a binding narrows the answer without redefining it.
		return true
	case ^Plan_Filter:
		for condition in v.conditions {
			if !expr_within(b.slots, condition, bindable) {
				return false
			}
		}
		return probe_safe_under(b, v.input, bindable)
	case ^Plan_Graph_Bind:
		// Safe exactly when its body is. Pre-binding ?g is the one case
		// the operator is glad to see: it hands the binding down to the
		// graph position instead of checking it afterwards, which is the
		// join with Ω(?g→i) done early rather than late.
		return probe_safe_under(b, v.input, bindable)
	case ^Plan_Project,
	     ^Plan_Distinct,
	     ^Plan_Slice,
	     ^Plan_Extend,
	     ^Plan_Left_Join,
	     ^Plan_Minus,
	     ^Plan_Materialized,
	     ^Plan_Group,
	     ^Plan_Order:
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
	case ^Plan_Nothing, ^Plan_Unit, ^Plan_Table, ^Plan_Graph_Scan, ^Plan_NPS, ^Plan_Path:
		// A path operator reads the graph position instead of binding it,
		// so it cannot carry a GRAPH variable — see plan_has_path.
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
	case ^Plan_Graph_Bind:
		// The triple patterns under a GRAPH clause match in *its* graph
		// slot, so they can carry no enclosing GRAPH variable however many
		// of them there are. `GRAPH ?g { GRAPH ?h { ?s ?p ?o } }` has to
		// enumerate ?g's graphs; nothing below binds it.
		return false
	case ^Plan_Group:
		return plan_matches_triples(v.input)
	case ^Plan_Order:
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
	case ^Plan_NPS:
		for position in ([2]Plan_Ref{v.subject, v.object}) {
			if plan_ref_is_var(position) && position.slot < len(out) {
				out[position.slot] = true
			}
		}
	case ^Plan_Path:
		for end in ([2]Plan_Path_End{v.subject, v.object}) {
			if end.slot >= 0 && end.slot < len(out) {
				out[end.slot] = true
			}
		}
	case ^Plan_Graph_Scan:
		if v.slot >= 0 && v.slot < len(out) {
			out[v.slot] = true
		}
	case ^Plan_Graph_Bind:
		plan_bindable(v.input, out)
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
	case ^Plan_Order:
		plan_bindable(v.input, out)
	case ^Plan_Group:
		// A group's solution is its keys and its aggregates, and nothing
		// its input bound — aggregation collapses the solutions it saw.
		for key in v.keys {
			if key.slot >= 0 && key.slot < len(out) {
				out[key.slot] = true
			}
		}
		for aggregate in v.aggregates {
			if aggregate.slot >= 0 && aggregate.slot < len(out) {
				out[aggregate.slot] = true
			}
		}
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
			case ^Triple_Term:
				// A data block is ground by the grammar, so a triple term
				// here always names a term; the builder owns the node
				// because an absent cell keeps it.
				term := builder_term(b, v)
				out.id, _, out.bound = ground_ref_id(b, term)
				out.absent = !out.bound
				out.term = term
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
ground_ref_id :: proc(b: ^Plan_Builder, term: rdf.Term) -> (id: record.Term_ID, ok: bool, present: bool) {
	ref, ref_ok, ref_present := ground_ref(b, term)
	return ref.id, ref_ok, ref_present
}

@(private = "file")
build_bgp :: proc(b: ^Plan_Builder, bgp: ^Alg_BGP) -> (p: Plan, ok: bool) {
	plan := new(Plan_BGP, b.allocator)
	plan.triples = make([dynamic]Plan_Triple, b.allocator)
	plan.order = make([dynamic]int, b.allocator)
	plan.shapes = make([dynamic]Plan_Term_Shape, b.allocator)
	plan.shape_range = make([dynamic][2]int, b.allocator)

	for triple in bgp.triples {
		t: Plan_Triple
		start := len(plan.shapes)
		positions := [3]Pattern_Node{triple.subject, triple.predicate, triple.object}
		for node, i in positions {
			ref, ref_ok, present := plan_ref(b, node, &plan.shapes)
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
		t[QUAD_G] = b.graph
		append(&plan.triples, t)
		append(&plan.shape_range, [2]int{start, len(plan.shapes)})
	}
	join_order(b, plan)
	return plan, true
}

// plan_ref resolves one pattern position. present is false when the
// position is a ground term the store does not hold.
@(private = "file")
discard_bgp :: proc(plan: ^Plan_BGP, allocator: runtime.Allocator) {
	delete(plan.triples)
	delete(plan.order)
	delete(plan.shapes)
	delete(plan.shape_range)
	free(plan, allocator)
}

// plan_ref resolves one pattern position. shapes is where a non-ground
// triple term deposits its decomposition; a caller that has nowhere to
// put one passes nil and gets an unsupported instead — a property path's
// endpoint, which has no unification step to hang a shape on.
@(private = "file")
plan_ref :: proc(
	b: ^Plan_Builder,
	node: Pattern_Node,
	shapes: ^[dynamic]Plan_Term_Shape = nil,
) -> (
	ref: Plan_Ref,
	ok: bool,
	present: bool,
) {
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
		return triple_term_ref(b, v, shapes)
	case ^Path_Expr:
		b.unsupported = "property path"
		return {}, false, false
	}
	b.unsupported = "empty pattern position"
	return {}, false, false
}

// --- Triple terms ----------------------------------------------------
//
// A SPARQL 1.2 triple term in a pattern position is one of two things,
// and which one it is is decided here rather than per solution.
//
// **Ground** — every component is an IRI or a literal, all the way down.
// Then the term has an identity the dictionary can answer for, and it
// resolves to a Term_ID exactly as an IRI does: `find_term` walks the
// components itself, and a term the store does not hold makes the
// pattern unsatisfiable, so the whole basic graph pattern collapses.
// Nothing about matching changes — the position is an ID and the store
// probes it.
//
// **Non-ground** — some component is a variable or a blank node. Then
// the position matches *any* triple term whose components unify, which
// the store cannot express: a match pattern binds a position to one ID
// or leaves it open. So the position becomes a fresh internal slot, the
// store hands back whatever triple term sits there, and the components
// are checked afterwards against the shape — the same
// bind-or-compare unification a repeated variable within one pattern
// gets. Taking the matched term apart is exec_triple_parts, one read
// out of record's encoding (exec.odin).

// triple_term_ref resolves a triple term in a pattern position.
@(private = "file")
triple_term_ref :: proc(
	b: ^Plan_Builder,
	tt: ^Triple_Term,
	shapes: ^[dynamic]Plan_Term_Shape,
) -> (
	ref: Plan_Ref,
	ok: bool,
	present: bool,
) {
	if triple_term_is_ground(tt) {
		term := triple_term_term(tt, b.allocator)
		defer triple_term_free(term, b.allocator)
		return ground_ref(b, term)
	}
	if shapes == nil {
		b.unsupported = "triple term pattern"
		return {}, false, false
	}
	slot, shape_ok, shape_present := build_shape(b, shapes, tt)
	return Plan_Ref{slot = slot}, shape_ok, shape_present
}

// build_shape appends the shape for a non-ground triple term (and,
// depth-first, for the non-ground triple terms inside it) and returns the
// slot its ID will be matched into. present is false when a ground
// component is a term the store does not hold: then no triple term in the
// store can have it, and the pattern matches nothing.
@(private = "file")
build_shape :: proc(
	b: ^Plan_Builder,
	shapes: ^[dynamic]Plan_Term_Shape,
	tt: ^Triple_Term,
) -> (
	slot: int,
	ok: bool,
	present: bool,
) {
	at := len(shapes^)
	slot = fresh_internal_slot(b.slots)
	append(shapes, Plan_Term_Shape{slot = slot})
	positions := [3]Pattern_Node{tt.subject, tt.predicate, tt.object}
	for node, i in positions {
		// The nested case is spelled out rather than left to plan_ref so
		// that a nested shape lands in the same list, after this one.
		part, part_ok, part_present := plan_ref(b, node, shapes)
		if !part_ok {
			return 0, false, false
		}
		if !part_present {
			return 0, true, false
		}
		shapes[at].parts[i] = part
	}
	return slot, true, true
}

// triple_term_is_ground reports whether a triple-term pattern names one
// term — every component an IRI or a literal, all the way down. A
// variable or a blank node anywhere inside makes it a pattern instead.
//
// Groundness is asked separately from materializing so that building the
// term cannot fail halfway and leave nodes with no owner.
@(private)
triple_term_is_ground :: proc(tt: ^Triple_Term) -> bool {
	if tt == nil {
		return false
	}
	for position in ([3]Pattern_Node{tt.subject, tt.predicate, tt.object}) {
		switch v in position {
		case rdf.IRI, rdf.Literal:
		case ^Triple_Term:
			if !triple_term_is_ground(v) {
				return false
			}
		case Var, rdf.Blank_Node, ^Path_Expr:
			return false
		case nil:
			return false
		}
	}
	return true
}

// triple_term_term materializes a ground triple-term pattern as the RDF
// term it names. Only the ^rdf.Triple nodes are allocated; every string
// is the query's, which outlives anything built here. Free with
// triple_term_free.
@(private)
triple_term_term :: proc(tt: ^Triple_Term, allocator: runtime.Allocator) -> rdf.Term {
	node := new(rdf.Triple, allocator)
	parts: [3]rdf.Term
	for position, i in ([3]Pattern_Node{tt.subject, tt.predicate, tt.object}) {
		switch v in position {
		case rdf.IRI:
			parts[i] = v
		case rdf.Literal:
			parts[i] = v
		case ^Triple_Term:
			parts[i] = triple_term_term(v, allocator)
		case Var, rdf.Blank_Node, ^Path_Expr:
			panic("triple_term_term: not a ground triple term")
		}
	}
	node^ = rdf.Triple {
		subject   = parts[0],
		predicate = parts[1],
		object    = parts[2],
	}
	return node
}

// triple_term_free releases what triple_term_term allocated: the nodes,
// and nothing else — the strings inside are borrowed.
@(private)
triple_term_free :: proc(term: rdf.Term, allocator: runtime.Allocator) {
	node, is_triple := term.(^rdf.Triple)
	if !is_triple || node == nil {
		return
	}
	triple_term_free(node.subject, allocator)
	triple_term_free(node.predicate, allocator)
	triple_term_free(node.object, allocator)
	free(node, allocator)
}

@(private = "file")
ground_ref :: proc(b: ^Plan_Builder, term: rdf.Term) -> (ref: Plan_Ref, ok: bool, present: bool) {
	id, found := exec_resolve(b.snapshot, term)
	if !found {
		return {}, true, false
	}
	// The property odin-rdf-store stated as "never a Sentinel-tagged ID"
	// survives the port with a different spelling, because record has no
	// sentinel kind: snapshot_resolve answers with a dictionary id or an
	// inlined literal, never with one of the values reserved for a
	// consumer's own computed terms. A ground term resolving into that
	// range would mean the two spaces had met, which is the collision
	// SPARQL-T-0019 recorded and record's reservation exists to prevent —
	// worth failing on rather than matching against.
	assert(!is_synthetic(id), "the store resolved a ground term into the consumer id range")
	return Plan_Ref{slot = -1, id = id}, true, true
}

// join_order fills a BGP's evaluation order. This is the planner seam:
// the whole of the engine's join-ordering policy lives in this one
// procedure.
//
// ~~today it is the order the patterns were written in. Cost-based
// ordering waits for the store to be able to estimate cardinality (an
// initiative-level upstream proposal); nothing above here assumes the
// identity permutation.~~ **The wait ended with the port**
// (`SPARQL-T-0037`). record answers better than the estimate that was
// asked for: `range_len` is an *exact* candidate count in O(1) —
// arithmetic on a window whose binary searches `snapshot_match` already
// paid — so there is no estimate, no error bar, and no case where the
// store declines to answer.
//
// # Cheapest first, but connected first before that
//
// The rule is two-level, and the second level is not optional:
//
//  1. **A pattern that shares a variable with what is already bound
//     wins**, whatever it costs, over one that does not.
//  2. Within that class, ascending candidate count; ties keep the
//     written order.
//
// Level 1 is the whole difference between a planner and a hazard. This
// executor is a nested loop (`probe_pattern` in exec.odin): a pattern
// evaluated at depth d is probed once per surviving row from depth
// d-1, with the row's bindings substituted in. A pattern sharing no
// variable with anything bound substitutes nothing, so every one of
// those probes is the *same full scan*, and the join degenerates into a
// cross product that a later pattern then filters.
//
// So ordering on cost alone — which is what this task was specified as,
// and what a cardinality-ordered planner is usually described as doing
// — makes plans arbitrarily worse rather than better, and the
// benchmark's own `bgp3` is an example. `?s a b:Entity` (20,000
// candidates), `?s b:knows ?o` (80,000), `?o b:name ?name` (20,000):
// ascending cost is 0, 2, 1, which pairs every entity with every name
// before `b:knows` filters — 4x10^8 intermediate rows for 80,000
// answers. Connected-first gives 0, 1, 2, which is what the query
// already said.
//
// # What the count is, exactly
//
// `range_len` counts every fact *generation* in the window, retracted
// ones included, so on a heavily edited store it reads slightly high.
// That is the right direction: it is an exact upper bound on visible
// matches at this epoch, and an upper bound is what a planner prices
// with. Not a correction to make.
//
// Costs are computed against **the builder's snapshot** — the one the
// evaluation will read. A plan priced against a different dataset than
// it runs on is a bug waiting for a concurrent writer.
//
// Cost: one `snapshot_match` per pattern, two binary searches per bound
// prefix, once per query rather than once per row. Measured rather than
// guessed at (`SPARQL-T-0037`): unmeasurable against every case of the
// benchmark, including the two-pattern BGP where it was most likely to
// show. No threshold, therefore, and no heuristic to skip small BGPs.
@(private = "file")
join_order :: proc(b: ^Plan_Builder, plan: ^Plan_BGP) {
	n := len(plan.triples)
	if n == 0 {
		return
	}
	// One pattern has no ordering problem, and pricing it would be a
	// store round trip that cannot change anything.
	if n == 1 {
		append(&plan.order, 0)
		return
	}

	costs := make([]int, n, context.temp_allocator)
	for t, i in plan.triples {
		p: record.Pattern
		// A variable is unbound *at plan time* whatever it becomes at
		// run time, so the static cost of a pattern is the width of the
		// window its ground terms alone can narrow to. That is what
		// makes these numbers comparable across patterns.
		p.s = 0 if plan_ref_is_var(t[QUAD_S]) else t[QUAD_S].id
		p.p = 0 if plan_ref_is_var(t[QUAD_P]) else t[QUAD_P].id
		p.o = 0 if plan_ref_is_var(t[QUAD_O]) else t[QUAD_O].id
		p.g = 0 if plan_ref_is_var(t[QUAD_G]) else t[QUAD_G].id
		// Priced at plan time, so it is a `store_ops` and nothing else:
		// `counting.odin` promises that verb counts every round trip
		// into the store wherever it is made, and this is a new place it
		// is made. It is deliberately **not** a `match` — that verb
		// means a scan opened for one pattern at one depth, which is an
		// evaluation event, and inflating it would break the comparison
		// `SPARQL-T-0036` pinned. Nor a `candidate`: nothing is scanned
		// here, and the window priced is the static one rather than the
		// probe's.
		when SPARQL_COUNT_READS {
			read_counts.store_ops += 1
		}
		costs[i] = record.range_len(record.snapshot_match(b.snapshot, p))
	}

	taken := make([]bool, n, context.temp_allocator)
	// The slots bound by everything chosen so far. A pattern is
	// "connected" when one of its own variable slots is in here.
	bound := make(map[int]bool, 0, context.temp_allocator)
	defer delete(bound)

	for _ in 0 ..< n {
		best := -1
		best_connected := false
		for i in 0 ..< n {
			if taken[i] {
				continue
			}
			connected := false
			for position in plan.triples[i] {
				if plan_ref_is_var(position) && position.slot in bound {
					connected = true
					break
				}
			}
			if best < 0 {
				best, best_connected = i, connected
				continue
			}
			// Connectivity first, then cost. Neither comparison is `<=`:
			// an equal candidate keeps the earlier one, which is where
			// stability comes from — the written order still decides
			// what the data does not.
			if connected != best_connected {
				if connected {
					best, best_connected = i, connected
				}
				continue
			}
			if costs[i] < costs[best] {
				best, best_connected = i, connected
			}
		}
		append(&plan.order, best)
		taken[best] = true
		for position in plan.triples[best] {
			if plan_ref_is_var(position) {
				bound[position.slot] = true
			}
		}
	}
}

// plan_destroy frees a plan tree.
plan_destroy :: proc(p: Plan, allocator := context.allocator) {
	switch v in p {
	case ^Plan_BGP:
		delete(v.triples)
		delete(v.order)
		delete(v.shapes)
		delete(v.shape_range)
		free(v, allocator)
	case ^Plan_NPS:
		delete(v.excluded)
		free(v, allocator)
	case ^Plan_Path:
		plan_destroy(v.step, allocator)
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
	case ^Plan_Graph_Bind:
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Group:
		delete(v.keys)
		delete(v.aggregates)
		plan_destroy(v.input, allocator)
		free(v, allocator)
	case ^Plan_Order:
		delete(v.conditions)
		plan_destroy(v.input, allocator)
		free(v, allocator)
	}
}
