// The ORDER BY ordering (SPARQL-T-0015).
//
// §15.1 gives a *partial* order and then says an implementation may
// extend it: numbers order against numbers, simple literals against
// simple literals, and the relative order of, say, an IRI and a plain
// string is left open. A sort has to answer anyway, and a suite whose
// expected results are written as ordered sequences has to be answered
// the same way twice. So this file states the extension the family
// makes, in full:
//
//  1. **Across kinds**, lowest first: unbound, blank node, IRI, literal,
//     triple term. That is §15.1's own list, with SPARQL 1.2's triple
//     terms appended above literals. An expression that raises a type
//     error sorts with the unbound — ORDER BY is not a filter, and a row
//     whose key cannot be computed still has to go somewhere.
//  2. **Within blank nodes and IRIs**, by the label or the IRI string in
//     codepoint order.
//  3. **Within literals**, by value wherever §15.1 defines a value
//     comparison — the whole numeric tower against itself, strings with
//     the same language tag, booleans, dateTimes. Where it does not, by
//     lexical form, then datatype IRI, then language tag, all in
//     codepoint order.
//  4. **Within triple terms**, by subject, then predicate, then object,
//     each by this same order.
//
// Jena ARQ answers the same way for every case the suites reach, which
// is the tiebreak the initiative chose where the spec is silent.
//
// The comparison never fails. `value_compare` distinguishes "less than",
// "equal", and "no defined order"; a total order has no third answer, so
// rule 3's fallback absorbs it — including the indeterminate comparison
// of two partially timezoned dates, which is a type error to FILTER and
// merely a tie-break here.
//
// **Stability.** Solutions the order does not distinguish keep the order
// they arrived in. The sort is a bottom-up merge over a permutation of
// row indices, which is stable by construction — rather than an
// index tiebreak bolted onto an unstable sort, which would be stable in
// the same sense but would say so only in a comment.
package sparql

import rdf "rdf:rdf"

// Order_Rank is the outer key of the total order: the term kind, in
// §15.1's own sequence.
Order_Rank :: enum {
	Unbound,
	Blank_Node,
	IRI,
	Literal,
	Triple,
}

order_rank :: proc(v: Value) -> Order_Rank {
	#partial switch v.kind {
	case .Error, .Unbound:
		return .Unbound
	case .Blank_Node:
		return .Blank_Node
	case .IRI:
		return .IRI
	case .Triple:
		return .Triple
	}
	return .Literal
}

// value_order is the total order: -1, 0, or +1, always. See the file
// header for what "always" costs and why it is the right price.
value_order :: proc(a, b: Value) -> int {
	rank_a, rank_b := order_rank(a), order_rank(b)
	if rank_a != rank_b {
		return -1 if rank_a < rank_b else +1
	}
	switch rank_a {
	case .Unbound:
		return 0
	case .Blank_Node, .IRI:
		return text_compare(a.text, b.text)
	case .Triple:
		return term_order(a.term, b.term)
	case .Literal:
		return literal_order(a, b)
	}
	return 0
}

// literal_order is rule 3: by value where SPARQL defines one, and by the
// term's own spelling where it does not.
@(private = "file")
literal_order :: proc(a, b: Value) -> int {
	if order, defined := value_compare(a, b); defined {
		return order
	}
	if order := text_compare(a.text, b.text); order != 0 {
		return order
	}
	if order := text_compare(string(a.datatype), string(b.datatype)); order != 0 {
		return order
	}
	return text_compare(a.language, b.language)
}

// term_order is rule 4, over the RDF terms a triple term holds. It goes
// through value_order rather than comparing terms directly so that a
// triple term of two numbers orders by their values, exactly as the same
// two numbers would outside one.
@(private = "file")
term_order :: proc(a, b: rdf.Term) -> int {
	left, left_is_triple := a.(^rdf.Triple)
	right, right_is_triple := b.(^rdf.Triple)
	if !left_is_triple || !right_is_triple {
		return 0
	}
	if order := value_order(value_of(left.subject), value_of(right.subject)); order != 0 {
		return order
	}
	if order := value_order(value_of(left.predicate), value_of(right.predicate)); order != 0 {
		return order
	}
	return value_order(value_of(left.object), value_of(right.object))
}

// Sort_Key is one row's value for one ORDER BY condition, materialized
// once so the comparator never re-evaluates an expression. term is the
// copy the value's strings point into: a backend may hand back a term
// that only lives until the next materialization, and the sort holds
// every row's keys at once.
Sort_Key :: struct {
	value: Value,
	term:  rdf.Term,
}

// order_sort permutes the row indices in perm into sorted order.
// scratch must be the same length as perm, and keys[row][condition] is
// the materialized key for one condition of one row.
order_sort :: proc(perm: []int, scratch: []int, keys: [][]Sort_Key, conditions: []Order_Condition) {
	if len(perm) < 2 {
		return
	}
	source, target := perm, scratch
	for width := 1; width < len(perm); width *= 2 {
		for lo := 0; lo < len(perm); lo += 2 * width {
			merge_runs(
				source,
				target,
				lo,
				min(lo + width, len(perm)),
				min(lo + 2 * width, len(perm)),
				keys,
				conditions,
			)
		}
		source, target = target, source
	}
	if raw_data(source) != raw_data(perm) {
		copy(perm, source)
	}
}

// merge_runs merges source[lo:mid] and source[mid:hi] into target[lo:hi].
// A tie takes from the left run, which is what makes the sort stable.
@(private = "file")
merge_runs :: proc(
	source, target: []int,
	lo, mid, hi: int,
	keys: [][]Sort_Key,
	conditions: []Order_Condition,
) {
	left, right, at := lo, mid, lo
	for left < mid && right < hi {
		if rows_compare(keys, conditions, source[right], source[left]) < 0 {
			target[at] = source[right]
			right += 1
		} else {
			target[at] = source[left]
			left += 1
		}
		at += 1
	}
	for left < mid {
		target[at] = source[left]
		left += 1
		at += 1
	}
	for right < hi {
		target[at] = source[right]
		right += 1
		at += 1
	}
}

@(private = "file")
rows_compare :: proc(keys: [][]Sort_Key, conditions: []Order_Condition, left, right: int) -> int {
	for condition, i in conditions {
		order := value_order(keys[left][i].value, keys[right][i].value)
		if condition.direction == .Descending {
			order = -order
		}
		if order != 0 {
			return order
		}
	}
	return 0
}
