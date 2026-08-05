// The harness's result model and the comparison that decides whether an
// evaluation test passed.
//
// A W3C evaluation test states its expectation as a file: a SPARQL
// results document (`.srx`, `.srj`), the result-set vocabulary in an RDF
// graph (`.ttl`, `.rdf`), or — for CONSTRUCT and DESCRIBE — a plain RDF
// graph. Every reader in this package produces the one Result_Set type
// below, so comparison is written once.
//
// Ownership: a Result_Set owns every string and term it holds. Terms are
// cloned in with rdf.clone_term (which deep-copies triple terms) and
// released by result_set_destroy. Nothing borrows the source buffer, so
// a result outlives the file it was read from.
//
// Comparison follows §12.2 of the SPARQL specification: a solution is a
// partial function from variable to term, so a variable bound nowhere is
// not a difference, and two result sets are equal when their solution
// *multisets* correspond under a bijection between their blank nodes.
// Bijection, not "ignore blank nodes": a blank node in the answer must
// stand for exactly one blank node in the expectation and vice versa, or
// distinct-blank-node structure would go unchecked.
package w3c

import "core:slice"
import "core:strings"

import rdf "rdf:rdf"

import sparql "../../../sparql"

// Result_Kind is the shape of an expectation or an answer.
Result_Kind :: enum {
	Bindings, // SELECT: a sequence of solutions
	Boolean, // ASK
	Graph, // CONSTRUCT / DESCRIBE
}

// Result_Set is one answer or one expectation.
//
// vars is the header's variable list, kept for diagnostics and for the
// SELECT-projection check; comparison itself works from the bindings,
// per the note above. A row is aligned to vars, and a nil cell is an
// unbound variable. order_index is the rs:index of each row where the
// source carried one (the result-set vocabulary records it) and is empty
// otherwise.
Result_Set :: struct {
	kind:        Result_Kind,
	vars:        [dynamic]string,
	rows:        [dynamic][dynamic]rdf.Term,
	order_index: [dynamic]int,
	boolean:     bool,
	graph:       [dynamic]rdf.Triple,
}

result_set_destroy :: proc(rs: ^Result_Set) {
	for v in rs.vars {
		delete(v)
	}
	delete(rs.vars)
	for row in rs.rows {
		for term in row {
			rdf.destroy_term(term)
		}
		delete(row)
	}
	delete(rs.rows)
	delete(rs.order_index)
	for t in rs.graph {
		rdf.destroy_triple(t)
	}
	delete(rs.graph)
	rs^ = {}
}

// result_set_var returns the index of a variable, adding it — and
// widening every existing row with an unbound cell — if it is new.
result_set_var :: proc(rs: ^Result_Set, name: string) -> int {
	for v, i in rs.vars {
		if v == name {
			return i
		}
	}
	append(&rs.vars, strings.clone(name))
	for &row in rs.rows {
		append(&row, nil)
	}
	return len(rs.vars) - 1
}

// result_set_add_row appends an all-unbound row and returns its index.
result_set_add_row :: proc(rs: ^Result_Set) -> int {
	row := make([dynamic]rdf.Term, len(rs.vars))
	append(&rs.rows, row)
	return len(rs.rows) - 1
}

// result_set_bind binds a variable in a row to a copy of term. Binding
// the same cell twice replaces the earlier value.
result_set_bind :: proc(rs: ^Result_Set, row: int, name: string, term: rdf.Term) {
	col := result_set_var(rs, name)
	if old := rs.rows[row][col]; old != nil {
		rdf.destroy_term(old)
	}
	rs.rows[row][col] = rdf.clone_term(term)
}

// result_set_add_triple appends a copy of a triple to a graph result.
result_set_add_triple :: proc(rs: ^Result_Set, t: rdf.Triple) {
	append(&rs.graph, rdf.clone_triple(t))
}

// result_set_sort_by_index reorders rows by the rs:index the source
// recorded, which is how the result-set vocabulary expresses the order
// an ORDER BY query's answer must come back in. A source that indexed
// no rows, or only some, is left alone.
result_set_sort_by_index :: proc(rs: ^Result_Set) {
	if len(rs.order_index) != len(rs.rows) || len(rs.rows) == 0 {
		return
	}
	Pair :: struct {
		index: int,
		row:   [dynamic]rdf.Term,
	}
	pairs := make([dynamic]Pair, 0, len(rs.rows))
	defer delete(pairs)
	for row, i in rs.rows {
		append(&pairs, Pair{rs.order_index[i], row})
	}
	slice.stable_sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.index < b.index})
	for p, i in pairs {
		rs.rows[i] = p.row
		rs.order_index[i] = p.index
	}
}

// Compare_Options selects the comparison the test's manifest entry asks
// for. ordered applies to a query with an ORDER BY: its answer is a
// sequence, so position matters. lax_cardinality is
// mf:resultCardinality mf:LaxCardinality — the REDUCED tests, where the
// spec permits any multiplicity between one and the full count, so both
// sides collapse to sets before they are compared.
Compare_Options :: struct {
	ordered:         bool,
	lax_cardinality: bool,
}

// results_equal reports whether an answer matches an expectation. reason
// is a static description of the first difference found, "" on success.
results_equal :: proc(actual, expected: ^Result_Set, opts := Compare_Options{}) -> (equal: bool, reason: string) {
	if actual.kind != expected.kind {
		return false, "result kind differs (bindings/boolean/graph)"
	}
	switch actual.kind {
	case .Boolean:
		if actual.boolean != expected.boolean {
			return false, "boolean answer differs"
		}
		return true, ""
	case .Graph:
		return graphs_isomorphic(actual.graph[:], expected.graph[:])
	case .Bindings:
		return bindings_equal(actual, expected, opts)
	}
	return false, "unreachable"
}

// A Solution is one row reduced to its bound (variable, term) pairs,
// sorted by variable name so two solutions are comparable positionally.
// This is the §12.2 view: unbound variables are absent, not null.
@(private = "file")
Solution :: struct {
	names: [dynamic]string,
	terms: [dynamic]rdf.Term,
}

@(private = "file")
solutions_of :: proc(rs: ^Result_Set) -> [dynamic]Solution {
	out := make([dynamic]Solution, 0, len(rs.rows))
	for row in rs.rows {
		sol: Solution
		sol.names = make([dynamic]string, 0, len(row))
		sol.terms = make([dynamic]rdf.Term, 0, len(row))
		for term, col in row {
			if term == nil {
				continue
			}
			// Insertion sort by name: rows are a handful of columns.
			at := len(sol.names)
			for at > 0 && sol.names[at - 1] > rs.vars[col] {
				at -= 1
			}
			inject_at(&sol.names, at, rs.vars[col])
			inject_at(&sol.terms, at, term)
		}
		append(&out, sol)
	}
	return out
}

@(private = "file")
destroy_solutions :: proc(s: ^[dynamic]Solution) {
	for sol in s {
		delete(sol.names)
		delete(sol.terms)
	}
	delete(s^)
}

@(private = "file")
bindings_equal :: proc(actual, expected: ^Result_Set, opts: Compare_Options) -> (equal: bool, reason: string) {
	a := solutions_of(actual)
	defer destroy_solutions(&a)
	e := solutions_of(expected)
	defer destroy_solutions(&e)

	if opts.lax_cardinality {
		// The multiplicity is unconstrained, so compare the underlying
		// sets. Deduplication is by the blank-node-blind key, which is
		// sound here: distinct solutions that differ only in which blank
		// node they carry collapse together on both sides alike.
		dedupe_solutions(&a)
		dedupe_solutions(&e)
	}

	if len(a) != len(e) {
		return false, "solution count differs"
	}
	if opts.ordered {
		return sequences_equal(a[:], e[:])
	}
	return multisets_equal(a[:], e[:])
}

@(private = "file")
dedupe_solutions :: proc(s: ^[dynamic]Solution) {
	seen: map[string]bool
	defer {
		for key in seen {
			delete(key)
		}
		delete(seen)
	}
	write := 0
	for i in 0 ..< len(s) {
		key := solution_key(s[i])
		if key in seen {
			delete(key)
			delete(s[i].names)
			delete(s[i].terms)
			continue
		}
		seen[key] = true
		s[write] = s[i]
		write += 1
	}
	resize(s, write)
}

// An ordered comparison pairs solutions by position, so the blank-node
// mapping it builds is forced rather than searched for.
@(private = "file")
sequences_equal :: proc(a, e: []Solution) -> (equal: bool, reason: string) {
	m := mapping_make()
	defer mapping_destroy(&m)
	for i in 0 ..< len(a) {
		if !unify_solution(a[i], e[i], &m) {
			return false, "solutions differ at a position (ordered comparison)"
		}
	}
	return true, ""
}

// An unordered comparison searches for a pairing of the two multisets
// that a single blank-node bijection supports. Candidates are narrowed
// first by a blank-node-blind key, so the search only ever branches over
// solutions that are identical apart from which blank nodes they name —
// which keeps it linear on the overwhelming majority of tests, where no
// blank node appears at all.
@(private = "file")
multisets_equal :: proc(a, e: []Solution) -> (equal: bool, reason: string) {
	keys_a := make([]string, len(a))
	keys_e := make([]string, len(e))
	defer {
		for k in keys_a {
			delete(k)
		}
		delete(keys_a)
		for k in keys_e {
			delete(k)
		}
		delete(keys_e)
	}
	for sol, i in a {
		keys_a[i] = solution_key(sol)
	}
	for sol, i in e {
		keys_e[i] = solution_key(sol)
	}
	// Equal key multisets are necessary (and, with no blank nodes,
	// sufficient); checking it first turns most mismatches into a cheap
	// failure instead of an exhausted search.
	sorted_a := slice.clone(keys_a)
	sorted_e := slice.clone(keys_e)
	defer delete(sorted_a)
	defer delete(sorted_e)
	slice.sort(sorted_a)
	slice.sort(sorted_e)
	for i in 0 ..< len(sorted_a) {
		if sorted_a[i] != sorted_e[i] {
			return false, "solutions differ (multiset comparison)"
		}
	}

	used := make([]bool, len(a))
	defer delete(used)
	m := mapping_make()
	defer mapping_destroy(&m)
	if search_pairing(a, e, keys_a, keys_e, used, &m, 0) {
		return true, ""
	}
	return false, "no blank-node bijection makes the solutions equal"
}

@(private = "file")
search_pairing :: proc(
	a, e: []Solution,
	keys_a, keys_e: []string,
	used: []bool,
	m: ^Mapping,
	at: int,
) -> bool {
	if at == len(e) {
		return true
	}
	for i in 0 ..< len(a) {
		if used[i] || keys_a[i] != keys_e[at] {
			continue
		}
		mark := mapping_mark(m)
		if unify_solution(a[i], e[at], m) {
			used[i] = true
			if search_pairing(a, e, keys_a, keys_e, used, m, at + 1) {
				return true
			}
			used[i] = false
		}
		mapping_rewind(m, mark)
	}
	return false
}

@(private = "file")
unify_solution :: proc(a, e: Solution, m: ^Mapping) -> bool {
	if len(a.names) != len(e.names) {
		return false
	}
	for i in 0 ..< len(a.names) {
		if a.names[i] != e.names[i] {
			return false
		}
		if !unify_term(a.terms[i], e.terms[i], m) {
			return false
		}
	}
	return true
}

// unify_term matches two terms under the bijection built so far,
// extending it when both sides are blank nodes.
@(private = "file")
unify_term :: proc(a, e: rdf.Term, m: ^Mapping) -> bool {
	a_blank, a_is_blank := a.(rdf.Blank_Node)
	e_blank, e_is_blank := e.(rdf.Blank_Node)
	if a_is_blank || e_is_blank {
		if !(a_is_blank && e_is_blank) {
			return false
		}
		return mapping_bind(m, string(a_blank), string(e_blank))
	}
	a_triple, a_is_triple := a.(^rdf.Triple)
	e_triple, e_is_triple := e.(^rdf.Triple)
	if a_is_triple || e_is_triple {
		if !(a_is_triple && e_is_triple) {
			return false
		}
		return(
			unify_term(a_triple.subject, e_triple.subject, m) &&
			unify_term(a_triple.predicate, e_triple.predicate, m) &&
			unify_term(a_triple.object, e_triple.object, m) \
		)
	}
	a_literal, a_is_literal := a.(rdf.Literal)
	e_literal, e_is_literal := e.(rdf.Literal)
	if a_is_literal && e_is_literal {
		return literals_equivalent(a_literal, e_literal)
	}
	return rdf.equal_term(a, e)
}

// literals_equivalent compares two literals of the same datatype by
// *value* where the engine interprets that datatype, and by lexical form
// otherwise.
//
// This is not laxity, it is what the suites require. The DAWG writes the
// expected result of adding two xsd:floats as "6", while XSD's canonical
// form is "6.0E0" — and elsewhere it writes "1.0E0". No implementation
// can match both by string, and both denote the same value. Comparing
// within a datatype keeps the distinctions the tests are actually about:
// "1"^^xsd:integer and "1.0"^^xsd:decimal remain different answers.
@(private = "file")
literals_equivalent :: proc(a, e: rdf.Literal) -> bool {
	if a.datatype != e.datatype || !strings.equal_fold(a.language, e.language) {
		return false
	}
	if a.lexical == e.lexical {
		return true
	}
	a_value := sparql.value_of(a)
	e_value := sparql.value_of(e)
	equal, comparable := sparql.value_equal(a_value, e_value)
	return comparable && equal
}

// graphs_isomorphic is the same search over triples: CONSTRUCT and
// DESCRIBE answers are graphs, compared up to blank-node renaming.
@(private = "file")
graphs_isomorphic :: proc(a, e: []rdf.Triple) -> (equal: bool, reason: string) {
	if len(a) != len(e) {
		return false, "graph size differs"
	}
	keys_a := make([]string, len(a))
	keys_e := make([]string, len(e))
	defer {
		for k in keys_a {
			delete(k)
		}
		delete(keys_a)
		for k in keys_e {
			delete(k)
		}
		delete(keys_e)
	}
	for t, i in a {
		keys_a[i] = triple_key(t)
	}
	for t, i in e {
		keys_e[i] = triple_key(t)
	}
	used := make([]bool, len(a))
	defer delete(used)
	m := mapping_make()
	defer mapping_destroy(&m)
	if search_triple_pairing(a, e, keys_a, keys_e, used, &m, 0) {
		return true, ""
	}
	return false, "graphs are not isomorphic"
}

@(private = "file")
search_triple_pairing :: proc(
	a, e: []rdf.Triple,
	keys_a, keys_e: []string,
	used: []bool,
	m: ^Mapping,
	at: int,
) -> bool {
	if at == len(e) {
		return true
	}
	for i in 0 ..< len(a) {
		if used[i] || keys_a[i] != keys_e[at] {
			continue
		}
		mark := mapping_mark(m)
		if unify_term(a[i].subject, e[at].subject, m) &&
		   unify_term(a[i].predicate, e[at].predicate, m) &&
		   unify_term(a[i].object, e[at].object, m) {
			used[i] = true
			if search_triple_pairing(a, e, keys_a, keys_e, used, m, at + 1) {
				return true
			}
			used[i] = false
		}
		mapping_rewind(m, mark)
	}
	return false
}

// Mapping is the partial blank-node bijection a comparison builds, kept
// as a trail so a failed branch rewinds in constant time per binding.
@(private = "file")
Mapping :: struct {
	forward: map[string]string, // actual label -> expected label
	reverse: map[string]string, // expected label -> actual label
	trail:   [dynamic][2]string,
}

@(private = "file")
mapping_make :: proc() -> Mapping {
	return Mapping{forward = make(map[string]string), reverse = make(map[string]string), trail = make([dynamic][2]string)}
}

@(private = "file")
mapping_destroy :: proc(m: ^Mapping) {
	delete(m.forward)
	delete(m.reverse)
	delete(m.trail)
}

@(private = "file")
mapping_mark :: proc(m: ^Mapping) -> int {
	return len(m.trail)
}

@(private = "file")
mapping_rewind :: proc(m: ^Mapping, mark: int) {
	for len(m.trail) > mark {
		pair := pop(&m.trail)
		delete_key(&m.forward, pair[0])
		delete_key(&m.reverse, pair[1])
	}
}

// mapping_bind extends the bijection with actual->expected, refusing a
// binding that would make it many-to-one in either direction.
@(private = "file")
mapping_bind :: proc(m: ^Mapping, actual, expected: string) -> bool {
	if bound, found := m.forward[actual]; found {
		return bound == expected
	}
	if bound, found := m.reverse[expected]; found {
		return bound == actual
	}
	m.forward[actual] = expected
	m.reverse[expected] = actual
	append(&m.trail, [2]string{actual, expected})
	return true
}

// A key is a blank-node-blind rendering: every blank node writes the
// same placeholder, so two solutions share a key exactly when they are
// equal for some renaming of their blank nodes. Keys narrow the search
// above; they never decide equality on their own.
@(private = "file")
solution_key :: proc(s: Solution) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< len(s.names) {
		strings.write_string(&b, s.names[i])
		strings.write_byte(&b, '=')
		write_term_key(&b, s.terms[i])
		strings.write_byte(&b, '\x1f')
	}
	return strings.clone(strings.to_string(b))
}

@(private = "file")
triple_key :: proc(t: rdf.Triple) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_term_key(&b, t.subject)
	strings.write_byte(&b, '\x1f')
	write_term_key(&b, t.predicate)
	strings.write_byte(&b, '\x1f')
	write_term_key(&b, t.object)
	return strings.clone(strings.to_string(b))
}

@(private = "file")
write_term_key :: proc(b: ^strings.Builder, term: rdf.Term) {
	switch v in term {
	case rdf.IRI:
		strings.write_string(b, "I<")
		strings.write_string(b, string(v))
		strings.write_byte(b, '>')
	case rdf.Blank_Node:
		strings.write_string(b, "B*")
	case rdf.Literal:
		strings.write_string(b, "L\"")
		// The key has to agree with literals_equivalent: two literals
		// that compare equal must share a key, or the pruning above would
		// refuse to pair them. So an interpreted datatype keys on its
		// value, not on how the value was written.
		value := sparql.value_of(v)
		#partial switch value.kind {
		case .Numeric:
			if value.numeric == .Integer {
				strings.write_i64(b, value.integer)
			} else {
				strings.write_f64(b, value.number, 'g')
			}
		case .Boolean:
			strings.write_string(b, value.boolean ? "true" : "false")
		case .Date_Time, .Date:
			strings.write_f64(b, value.datetime.seconds, 'g')
			strings.write_byte(b, value.datetime.has_tz ? 'z' : 'n')
		case:
			strings.write_string(b, v.lexical)
		}
		strings.write_string(b, "\"^^")
		strings.write_string(b, string(v.datatype))
		strings.write_byte(b, '@')
		strings.write_string(b, v.language)
		strings.write_byte(b, '#')
		strings.write_string(b, direction_tag(v.direction))
	case ^rdf.Triple:
		strings.write_string(b, "T(")
		write_term_key(b, v.subject)
		strings.write_byte(b, ' ')
		write_term_key(b, v.predicate)
		strings.write_byte(b, ' ')
		write_term_key(b, v.object)
		strings.write_byte(b, ')')
	case nil:
		strings.write_string(b, "U")
	}
}

@(private = "file")
direction_tag :: proc(d: rdf.Direction) -> string {
	switch d {
	case .None:
		return ""
	case .LTR:
		return "ltr"
	case .RTL:
		return "rtl"
	}
	return ""
}

// result_set_to_string renders a result for a failing test's message.
// The caller owns the returned string.
result_set_to_string :: proc(rs: ^Result_Set) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	switch rs.kind {
	case .Boolean:
		strings.write_string(&b, rs.boolean ? "boolean: true" : "boolean: false")
	case .Graph:
		for t in rs.graph {
			write_term_key(&b, t.subject)
			strings.write_byte(&b, ' ')
			write_term_key(&b, t.predicate)
			strings.write_byte(&b, ' ')
			write_term_key(&b, t.object)
			strings.write_byte(&b, '\n')
		}
	case .Bindings:
		for row in rs.rows {
			for term, col in row {
				if term == nil {
					continue
				}
				strings.write_string(&b, rs.vars[col])
				strings.write_byte(&b, '=')
				write_term_key(&b, term)
				strings.write_byte(&b, ' ')
			}
			strings.write_byte(&b, '\n')
		}
	}
	return strings.clone(strings.to_string(b))
}
