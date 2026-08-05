// Expression evaluation (SPARQL-T-0012): an expression tree from the
// parser, a solution row, and the store's dictionary, in — a Value out.
//
// The awkward part of SPARQL expressions is not the operators, it is
// what happens when they are given something they do not understand.
// SPARQL does not stop: it produces a type error, propagates it, and
// then specific operators recover from it. `||` is true if *either* side
// is true even when the other errored; `&&` is false if either side is
// false; FILTER treats an error like a false. Getting that wrong does
// not crash anything, it just quietly returns the wrong rows — which is
// why the three-valued cases have their own tests and their own suite
// directories.
//
// Variables are read from the solution row, so evaluating an expression
// means materializing the terms it mentions and nothing else. Terms come
// back through a Term_Loader, a procedure pointer: it is called once per
// variable occurrence per solution, not per matched quad, and the
// SPARQL-T-0011 spike measured indirect calls at that frequency as free.
// The loader says whether the term it returned is owned, because the two
// backends differ — memstore borrows from its dictionary, kvstore builds
// the term — and an owned one is released when the evaluation ends.
package sparql

import "base:runtime"

import "core:strings"
import "core:time"

import rdf "rdf:rdf"
import store "store:store"

// Term_Loader materializes a term ID. owned=true means the term was
// allocated for this call and the caller releases it.
Term_Loader :: #type proc(
	data: rawptr,
	id: store.Term_ID,
	allocator: runtime.Allocator,
) -> (
	term: rdf.Term,
	owned: bool,
)

// Exists_Runner evaluates the index-th EXISTS sub-plan against the
// solution currently in the row, and reports whether it has one.
Exists_Runner :: #type proc(data: rawptr, index: int) -> bool

// Bnode_Binding is one BNODE(str) memo entry: the string the query
// passed and the label it produced. The list is short — a query names a
// handful of blank nodes, not thousands — so a linear scan beats a map
// that would have to be rebuilt every solution.
Bnode_Binding :: struct {
	key:   string,
	label: string,
}

// Regex_Cache_Entry is one compiled pattern. REGEX's pattern is a
// constant in essentially every query, and compiling it per solution
// would cost more than matching does.
//
// The compiled program is held behind a pointer rather than inline: the
// cache is a dynamic array, and a caller holding a ^Regex across an
// append would otherwise be left pointing into the old backing store.
Regex_Cache_Entry :: struct {
	pattern: string,
	flags:   Regex_Flags,
	rx:      ^Regex,
	ok:      bool,
}

// Expr_Context is everything an expression needs beyond its own tree.
// row is repointed at each solution; scratch collects the terms the
// loader allocated for the current evaluation.
Expr_Context :: struct {
	slots:     ^Var_Slots,
	row:       []store.Term_ID,
	load:      Term_Loader,
	load_data: rawptr,
	scratch:   [dynamic]rdf.Term,
	// Terms this query computed — BIND results, which the store has
	// never seen. See the note on synthetic IDs below.
	computed:  ^[dynamic]rdf.Term,
	// EXISTS is a pattern inside a value, so evaluating one means running
	// a sub-plan against the current solution. The executor supplies that
	// as a procedure pointer: the call has to cross back into code that
	// is generic over the backend, and a generic procedure that reaches
	// itself directly is what hangs the compiler (SPARQL-T-0011).
	exists:       Exists_Runner,
	exists_data:  rawptr,
	exists_nodes: []^Exists_Expr,

	// Strings the §17 functions built. They are released with the rest of
	// one evaluation's scratch, which is after the value has been
	// rendered into a binding — see conditions_hold and the Extend case
	// in exec.odin.
	texts:     [dynamic]string,

	// The query-scoped state the impure functions need (see
	// functions.odin's header). base anchors IRI(); now is the one
	// instant NOW() answers with for the whole query; seed drives RAND
	// and UUID; bnodes is BNODE(str)'s per-solution memo and blanks
	// counts the labels handed out.
	base:      string,
	now:       Value,
	seed:      u64,
	bnodes:    [dynamic]Bnode_Binding,
	blanks:    int,
	regexes:   [dynamic]Regex_Cache_Entry,

	allocator: runtime.Allocator,
}

// A solution row holds store IDs, so a value a query *computes* —
// `BIND(?a + ?b AS ?c)` — has no ID to be bound to. Interning it would
// make a query a write, which is the one thing the term-binding bridge
// exists to prevent.
//
// So the engine names computed terms itself, in a space the store
// guarantees it will never assign: the Sentinel kind, whose counters 0,
// 1, and 2 are DEFAULT_GRAPH, WILDCARD, and UNBOUND, and whose counters
// from 3 up are unused. A synthetic ID is an index into the query's own
// table of computed terms, and it is resolved before the store is asked.
//
// This works, and it is also evidence: an engine that has to invent a
// term space because the store has no query-local one is describing a
// gap in the interface. Recorded for SPARQL-T-0019.
SYNTHETIC_FIRST :: 3

// synthetic_id names the index-th computed term; is_synthetic recognizes
// one, and synthetic_index reads the index back out. A synthetic ID is
// valid only inside the query that made it and must never reach a match
// pattern — plan building asserts on one that does.
synthetic_id :: proc(index: int) -> store.Term_ID {
	return store.make_id(.Sentinel, u64(SYNTHETIC_FIRST + index))
}

is_synthetic :: proc(id: store.Term_ID) -> bool {
	return store.id_kind(id) == .Sentinel && store.id_counter(id) >= SYNTHETIC_FIRST
}

synthetic_index :: proc(id: store.Term_ID) -> int {
	return int(store.id_counter(id)) - SYNTHETIC_FIRST
}

// expr_context_init prepares the evaluation context a plan's expressions
// share. load/load_data materialize a term ID, computed is the execution's
// table of terms the query invented, and everything the context allocates
// comes from the given allocator. One context serves a whole execution:
// only one operator evaluates an expression at a time.
expr_context_init :: proc(
	ctx: ^Expr_Context,
	slots: ^Var_Slots,
	load: Term_Loader,
	load_data: rawptr,
	computed: ^[dynamic]rdf.Term,
	allocator := context.allocator,
) {
	ctx.slots = slots
	ctx.load = load
	ctx.load_data = load_data
	ctx.computed = computed
	ctx.allocator = allocator
	ctx.scratch = make([dynamic]rdf.Term, allocator)
	ctx.texts = make([dynamic]string, allocator)
	ctx.bnodes = make([dynamic]Bnode_Binding, allocator)
	ctx.regexes = make([dynamic]Regex_Cache_Entry, allocator)
	expr_context_start_query(ctx)
}

// expr_context_start_query fixes the values that are constant for one
// query execution: NOW's instant (§17.4.5.1 — "all calls return the
// same value ... within one query") and the seed RAND and UUID draw
// from. Reading the clock once here is the whole of it; there is no
// other place a query is allowed to notice time passing.
@(private = "file")
expr_context_start_query :: proc(ctx: ^Expr_Context) {
	stamp := time.now()
	ctx.seed = u64(time.to_unix_nanoseconds(stamp)) | 1
	ctx.now = expr_instant_value(ctx, stamp)
}

// expr_context_set_base gives the context the query's base IRI, which
// IRI() resolves relative references against. The string is copied: the
// parser that owns the original need not outlive the execution.
expr_context_set_base :: proc(ctx: ^Expr_Context, base: string) {
	if base == "" {
		return
	}
	ctx.base = strings.clone(base, ctx.allocator)
}

// expr_context_destroy frees what the context owns for the whole query —
// the compiled regex cache, the BNODE memo, the evaluation scratch. It
// does not free the computed-term table, which belongs to the execution
// (see Exec.computed).
expr_context_destroy :: proc(ctx: ^Expr_Context) {
	expr_context_release(ctx)
	expr_context_new_solution(ctx)
	delete(ctx.scratch)
	delete(ctx.texts)
	delete(ctx.bnodes)
	for entry in ctx.regexes {
		delete(entry.pattern, ctx.allocator)
		regex_destroy(entry.rx)
		free(entry.rx, ctx.allocator)
	}
	delete(ctx.regexes)
	// NOW's lexical form outlives every evaluation — it is the query's
	// instant — so it is not in the per-evaluation list and is released
	// here instead.
	delete(ctx.base, ctx.allocator)
	delete(ctx.now.text, ctx.allocator)
	ctx^ = {}
}

// expr_context_release frees the terms and strings materialized during
// one evaluation. Called after each condition, so a filter over a
// million solutions holds one solution's worth at a time.
expr_context_release :: proc(ctx: ^Expr_Context) {
	for term in ctx.scratch {
		rdf.destroy_term(term, ctx.allocator)
	}
	clear(&ctx.scratch)
	for text in ctx.texts {
		delete(text, ctx.allocator)
	}
	clear(&ctx.texts)
}

// expr_context_new_solution ends BNODE(str)'s memo scope. §17.4.2.2
// scopes it to one solution mapping: the same string twice in one
// solution is one blank node, and the same string in the next solution
// is a different one.
//
// The executor calls this as each solution reaches an operator that
// evaluates expressions, which is a slightly coarser scope than the
// spec's — a BNODE in a FILTER and a BNODE in a BIND over the same
// solution get different nodes. Nothing in SPARQL can observe the
// difference, because a FILTER cannot export a value.
expr_context_new_solution :: proc(ctx: ^Expr_Context) {
	for entry in ctx.bnodes {
		delete(entry.key, ctx.allocator)
		delete(entry.label, ctx.allocator)
	}
	clear(&ctx.bnodes)
}

// expr_own_text copies a string into the evaluation scratch and returns
// the copy, which lives until the current evaluation is released.
expr_own_text :: proc(ctx: ^Expr_Context, text: string) -> string {
	owned := strings.clone(text, ctx.allocator)
	append(&ctx.texts, owned)
	return owned
}

// expr_adopt_text takes over a string already allocated in the
// context's allocator — what a strings.Builder result is.
expr_adopt_text :: proc(ctx: ^Expr_Context, text: string) -> string {
	append(&ctx.texts, text)
	return text
}

// expr_literal builds a value from an RDF literal the query computed,
// interpreting it exactly as though it had been read from the store —
// so STRDT's result knows whether it is a number, and an unparseable
// lexical form becomes an ill-typed literal rather than an error.
expr_literal :: proc(ctx: ^Expr_Context, lexical: string, datatype: rdf.IRI, language: string) -> Value {
	literal := rdf.Literal {
		lexical  = expr_own_text(ctx, lexical),
		datatype = rdf.IRI(expr_own_text(ctx, string(datatype))),
		language = expr_own_text(ctx, language),
	}
	return value_of(literal)
}

// expr_random draws the next value for RAND: a double in [0, 1). The
// generator is splitmix64, seeded once per query — small, allocation
// free, and good enough for a function whose only stated contract is
// the range it lands in.
expr_random :: proc(ctx: ^Expr_Context) -> f64 {
	// 53 bits is exactly what an f64 mantissa holds, so every value in
	// the range is reachable and none is reachable twice.
	return f64(expr_next_u64(ctx) >> 11) / f64(u64(1) << 53)
}

@(private = "file")
expr_next_u64 :: proc(ctx: ^Expr_Context) -> u64 {
	ctx.seed += 0x9E3779B97F4A7C15
	z := ctx.seed
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private = "file")
UUID_HEX := "0123456789abcdef"

// expr_uuid_string writes a version-4 UUID from the query's generator,
// in the lowercase hyphenated form urn:uuid: expects.
expr_uuid_string :: proc(ctx: ^Expr_Context) -> string {
	octets: [16]byte
	high, low := expr_next_u64(ctx), expr_next_u64(ctx)
	for i in 0 ..< 8 {
		octets[i] = byte(high >> uint(8 * (7 - i)))
		octets[8 + i] = byte(low >> uint(8 * (7 - i)))
	}
	octets[6] = (octets[6] & 0x0F) | 0x40 // version 4
	octets[8] = (octets[8] & 0x3F) | 0x80 // variant 1
	buf := make([]byte, 36, ctx.allocator)
	at := 0
	for octet, i in octets {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			buf[at] = '-'
			at += 1
		}
		buf[at] = UUID_HEX[octet >> 4]
		buf[at + 1] = UUID_HEX[octet & 0xF]
		at += 2
	}
	return expr_adopt_text(ctx, string(buf))
}

// expr_fresh_blank names a blank node BNODE created. The label is one
// a query cannot write and a store cannot hold: the '.' is not legal in
// a BLANK_NODE_LABEL's first position, so the node is distinct from
// every node in the dataset, which is what §17.4.2.2 requires.
//
// The caller owns the returned label and decides how long it lives —
// one evaluation for BNODE(), one solution for BNODE(str).
expr_fresh_blank :: proc(ctx: ^Expr_Context) -> string {
	ctx.blanks += 1
	b := strings.builder_make(ctx.allocator)
	strings.write_string(&b, ".bn")
	strings.write_int(&b, ctx.blanks)
	return strings.to_string(b)
}

// expr_instant_value turns a wall-clock reading into the xsd:dateTime
// NOW() answers with, in UTC.
@(private = "file")
expr_instant_value :: proc(ctx: ^Expr_Context, stamp: time.Time) -> Value {
	year, month, day := time.date(stamp)
	hour, minute, second := time.clock_from_time(stamp)
	b := strings.builder_make(ctx.allocator)
	strings.write_int(&b, year)
	for part in ([?]int{int(month), day}) {
		strings.write_byte(&b, '-')
		if part < 10 {
			strings.write_byte(&b, '0')
		}
		strings.write_int(&b, part)
	}
	strings.write_byte(&b, 'T')
	for part, i in ([?]int{hour, minute, second}) {
		if i > 0 {
			strings.write_byte(&b, ':')
		}
		if part < 10 {
			strings.write_byte(&b, '0')
		}
		strings.write_int(&b, part)
	}
	strings.write_byte(&b, 'Z')
	lexical := strings.to_string(b)
	// The literal borrows the lexical form and the constant datatype,
	// and the Value carries the literal as its term — so value_to_term
	// renders NOW as itself. The lexical form is freed with the context.
	return value_of(rdf.Literal{lexical = lexical, datatype = XSD_DATE_TIME})
}

// expr_regex compiles a pattern, or hands back the compilation from a
// previous solution. ok is false for a pattern the flavour rejects,
// which REGEX and REPLACE turn into a type error — and the failure is
// cached too, so an invalid pattern is diagnosed once.
expr_regex :: proc(ctx: ^Expr_Context, pattern: string, flags: string) -> (rx: ^Regex, ok: bool) {
	parsed, flags_ok := regex_parse_flags(flags)
	if !flags_ok {
		return nil, false
	}
	for entry in ctx.regexes {
		if entry.pattern == pattern && entry.flags == parsed {
			return entry.rx, entry.ok
		}
	}
	compiled := new(Regex, ctx.allocator)
	compiled_ok: bool
	compiled^, compiled_ok = regex_compile(pattern, parsed, ctx.allocator)
	append(
		&ctx.regexes,
		Regex_Cache_Entry {
			pattern = strings.clone(pattern, ctx.allocator),
			flags = parsed,
			rx = compiled,
			ok = compiled_ok,
		},
	)
	return compiled, compiled_ok
}

// expr_eval evaluates an expression against the context's current row.
// It never fails: an operator that cannot proceed returns a type-error
// Value, which its caller either recovers from or passes on.
expr_eval :: proc(ctx: ^Expr_Context, e: Expr) -> Value {
	switch v in e {
	case Var:
		return var_value(ctx, v.name)
	case rdf.IRI:
		return Value{kind = .IRI, text = string(v)}
	case rdf.Literal:
		return value_of(v)
	case ^Binary_Expr:
		return eval_binary(ctx, v)
	case ^Unary_Expr:
		return eval_unary(ctx, v)
	case ^In_Expr:
		return eval_in(ctx, v)
	case ^Builtin_Call:
		return eval_builtin(ctx, v)
	case ^Exists_Expr:
		if ctx.exists == nil {
			return ERROR_VALUE
		}
		index := exists_index(ctx.exists_nodes, v)
		if index < 0 {
			return ERROR_VALUE
		}
		found := ctx.exists(ctx.exists_data, index)
		return value_boolean(found != v.negated)
	case ^Function_Call:
		// The only function calls that reach here are the §17.5 casts;
		// anything else was refused at plan time.
		if len(v.args) != 1 || !cast_iri(v.iri) {
			return ERROR_VALUE
		}
		return eval_cast(ctx, v.iri, expr_eval(ctx, v.args[0]))
	case ^Triple_Term:
		return eval_triple_term(ctx, v)
	case ^Aggregate:
	// Refused at plan time (expr_check); reaching here would be a bug
	// in that check rather than a query the engine should answer.
	}
	return ERROR_VALUE
}

// eval_triple_term evaluates `<<( s p o )>>` written as an expression
// (SPARQL 1.2's ExprTripleTerm). It is TRIPLE(s, p, o) in surface
// syntax, so it is TRIPLE(s, p, o) here too — the same construction and
// the same refusals, over components that are terms or variables rather
// than arbitrary expressions.
@(private = "file")
eval_triple_term :: proc(ctx: ^Expr_Context, tt: ^Triple_Term) -> Value {
	if tt == nil {
		return ERROR_VALUE
	}
	subject := expr_eval(ctx, pattern_node_expr(tt.subject))
	predicate := expr_eval(ctx, pattern_node_expr(tt.predicate))
	object := expr_eval(ctx, pattern_node_expr(tt.object))
	return build_triple_value(ctx, subject, predicate, object)
}

// pattern_node_expr reads a triple term's component as the expression it
// is. The parser restricts an expression triple term's components to
// variables, IRIs, literals, and nested triple terms — the four the Expr
// union already carries — so this is a change of type and not a
// conversion.
@(private)
pattern_node_expr :: proc(node: Pattern_Node) -> Expr {
	switch v in node {
	case Var:
		return v
	case rdf.IRI:
		return v
	case rdf.Literal:
		return v
	case ^Triple_Term:
		return v
	case rdf.Blank_Node, ^Path_Expr:
	// Neither can occur in an expression; the parser rejects both.
	}
	return nil
}

@(private = "file")
var_value :: proc(ctx: ^Expr_Context, name: string) -> Value {
	slot, found := var_slot_lookup(ctx.slots, name)
	if !found || slot >= len(ctx.row) {
		// A variable the pattern never mentions is unbound, not an
		// error — BOUND(?nowhere) must be able to say false.
		return UNBOUND_VALUE
	}
	id := ctx.row[slot]
	if id == store.UNBOUND {
		return UNBOUND_VALUE
	}
	if is_synthetic(id) {
		value := value_of(ctx.computed[synthetic_index(id)])
		value.source = id
		value.has_source = true
		return value
	}
	term, owned := ctx.load(ctx.load_data, id, ctx.allocator)
	if owned {
		append(&ctx.scratch, term)
	}
	value := value_of(term)
	value.source = id
	value.has_source = true
	return value
}

@(private = "file")
eval_binary :: proc(ctx: ^Expr_Context, e: ^Binary_Expr) -> Value {
	// The logical operators evaluate lazily-ish: both sides are needed
	// only because either may supply the deciding truth value even when
	// the other errors (§17.2.1's truth tables).
	if e.op == .Or || e.op == .And {
		left, left_ok := effective_boolean_value(expr_eval(ctx, e.left))
		if e.op == .Or && left_ok && left {
			return value_boolean(true)
		}
		if e.op == .And && left_ok && !left {
			return value_boolean(false)
		}
		right, right_ok := effective_boolean_value(expr_eval(ctx, e.right))
		if e.op == .Or {
			if right_ok && right {
				return value_boolean(true)
			}
			if left_ok && right_ok {
				return value_boolean(false)
			}
			return ERROR_VALUE
		}
		if right_ok && !right {
			return value_boolean(false)
		}
		if left_ok && right_ok {
			return value_boolean(true)
		}
		return ERROR_VALUE
	}

	left := expr_eval(ctx, e.left)
	right := expr_eval(ctx, e.right)
	if left.kind == .Error || right.kind == .Error {
		return ERROR_VALUE
	}

	#partial switch e.op {
	case .Eq, .Ne:
		equal, ok := value_equal(left, right)
		if !ok {
			return ERROR_VALUE
		}
		return value_boolean(equal if e.op == .Eq else !equal)
	case .Lt, .Gt, .Le, .Ge:
		order, ok := value_compare(left, right)
		if !ok {
			return ERROR_VALUE
		}
		switch e.op {
		case .Lt:
			return value_boolean(order < 0)
		case .Gt:
			return value_boolean(order > 0)
		case .Le:
			return value_boolean(order <= 0)
		case .Ge:
			return value_boolean(order >= 0)
		case .Or, .And, .Eq, .Ne, .Add, .Sub, .Mul, .Div:
		}
	case .Add:
		return value_arithmetic(.Add, left, right)
	case .Sub:
		return value_arithmetic(.Subtract, left, right)
	case .Mul:
		return value_arithmetic(.Multiply, left, right)
	case .Div:
		return value_arithmetic(.Divide, left, right)
	}
	return ERROR_VALUE
}

@(private = "file")
eval_unary :: proc(ctx: ^Expr_Context, e: ^Unary_Expr) -> Value {
	operand := expr_eval(ctx, e.operand)
	switch e.op {
	case .Not:
		b, ok := effective_boolean_value(operand)
		if !ok {
			return ERROR_VALUE
		}
		return value_boolean(!b)
	case .Plus:
		if operand.kind != .Numeric {
			return ERROR_VALUE
		}
		return operand
	case .Minus:
		return value_negate(operand)
	}
	return ERROR_VALUE
}

// eval_in is `x IN (a, b, …)`. It is `x = a || x = b || …`, and so it
// inherits `||`'s error recovery: a match anywhere wins even if another
// comparison errored, and only an all-false-with-an-error result is an
// error.
@(private = "file")
eval_in :: proc(ctx: ^Expr_Context, e: ^In_Expr) -> Value {
	subject := expr_eval(ctx, e.value)
	if subject.kind == .Error {
		return ERROR_VALUE
	}
	errored := false
	for item in e.list {
		candidate := expr_eval(ctx, item)
		if candidate.kind == .Error {
			errored = true
			continue
		}
		equal, ok := value_equal(subject, candidate)
		if !ok {
			errored = true
			continue
		}
		if equal {
			return value_boolean(!e.negated)
		}
	}
	if errored {
		return ERROR_VALUE
	}
	return value_boolean(e.negated)
}

// expr_check walks an expression at plan time and names the first
// construct this engine cannot evaluate. Refusing here rather than
// returning a type error at runtime is the difference between "the
// engine does not implement REGEX" and "your filter matched nothing".
expr_check :: proc(b: ^Plan_Builder, e: Expr) -> bool {
	switch v in e {
	case Var, rdf.IRI, rdf.Literal:
		return true
	case ^Binary_Expr:
		return expr_check(b, v.left) && expr_check(b, v.right)
	case ^Unary_Expr:
		return expr_check(b, v.operand)
	case ^In_Expr:
		if !expr_check(b, v.value) {
			return false
		}
		for item in v.list {
			if !expr_check(b, item) {
				return false
			}
		}
		return true
	case ^Builtin_Call:
		if !builtin_implemented(v.builtin) {
			b.unsupported = "built-in function"
			return false
		}
		for arg in v.args {
			if !expr_check(b, arg) {
				return false
			}
		}
		return true
	case ^Function_Call:
		// A function call on an XSD IRI is a §17.5 cast, not an
		// extension function. Anything else is one, and this engine has
		// none.
		if !cast_iri(v.iri) || len(v.args) != 1 {
			b.unsupported = "extension function"
			return false
		}
		return expr_check(b, v.args[0])
	case ^Exists_Expr:
		if v.algebra == nil {
			b.unsupported = "EXISTS without a translated pattern"
			return false
		}
		if _, ok := exists_register(b, v); !ok {
			return false
		}
		return true
	case ^Aggregate:
		b.unsupported = "aggregate"
	case ^Triple_Term:
		if v == nil {
			b.unsupported = "empty triple term"
			return false
		}
		for component in ([3]Pattern_Node{v.subject, v.predicate, v.object}) {
			if !expr_check(b, pattern_node_expr(component)) {
				return false
			}
		}
		return true
	case nil:
		b.unsupported = "empty expression"
	}
	return false
}

// expr_within reports whether every variable an expression mentions is
// one the given set of slots can bind. It is what decides whether a
// filter may be evaluated with an enclosing solution's bindings already
// in place (see probe_safe in plan.odin): a filter over variables its own
// sub-plan binds means the same thing either way, and one that reaches
// outside does not.
expr_within :: proc(slots: ^Var_Slots, e: Expr, bindable: []bool) -> bool {
	switch v in e {
	case Var:
		slot, found := var_slot_lookup(slots, v.name)
		return found && slot < len(bindable) && bindable[slot]
	case rdf.IRI, rdf.Literal:
		return true
	case ^Binary_Expr:
		return expr_within(slots, v.left, bindable) && expr_within(slots, v.right, bindable)
	case ^Unary_Expr:
		return expr_within(slots, v.operand, bindable)
	case ^In_Expr:
		if !expr_within(slots, v.value, bindable) {
			return false
		}
		for item in v.list {
			if !expr_within(slots, item, bindable) {
				return false
			}
		}
		return true
	case ^Builtin_Call:
		for arg in v.args {
			if !expr_within(slots, arg, bindable) {
				return false
			}
		}
		return true
	case ^Exists_Expr:
		// An EXISTS reaches outside by design: its pattern is evaluated
		// against the enclosing solution. So a filter containing one is
		// never safe to move under a correlated join.
		return false
	case ^Function_Call:
		// Only a §17.5 cast gets this far, and a cast is a pure function
		// of its argument.
		for arg in v.args {
			if !expr_within(slots, arg, bindable) {
				return false
			}
		}
		return true
	case ^Triple_Term:
		if v == nil {
			return false
		}
		for component in ([3]Pattern_Node{v.subject, v.predicate, v.object}) {
			if !expr_within(slots, pattern_node_expr(component), bindable) {
				return false
			}
		}
		return true
	case ^Aggregate:
		return false
	case nil:
		return false
	}
	return false
}
