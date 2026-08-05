package sparql

import "core:testing"

import rdf "rdf:rdf"

// The golden strings follow Jena ARQ's SSE notation (`arq.qparse
// --print op`): operator tags, term syntax, bare numeric/boolean
// lexical forms, two-space indentation, closing parens accumulating on
// the last child line. They are hand-derived from ARQ's documented
// output format (SPARQL-T-0006; no Jena installation on the build
// host) — regenerating them against a live Jena is a T-0007 option
// once the translation makes end-to-end comparisons meaningful.

@(private = "file")
expect_sse :: proc(t: ^testing.T, a: Algebra, want: string, loc := #caller_location) {
	got := algebra_to_string(a)
	defer delete(got)
	testing.expectf(t, got == want, "SSE mismatch:\n--- got ---\n%s--- want ---\n%s", got, want, loc = loc)
}

@(private = "file")
v :: proc(name: string) -> Var {
	return {name = name}
}

@(private = "file")
bgp1 :: proc(s, p, o: Pattern_Node) -> ^Alg_BGP {
	b := new(Alg_BGP)
	append(&b.triples, Alg_Triple{subject = s, predicate = p, object = o})
	return b
}

@(test)
test_sse_bgp_and_terms :: proc(t: ^testing.T) {
	b := new(Alg_BGP)
	defer destroy_algebra(b)
	append(&b.triples, Alg_Triple{subject = v("s"), predicate = rdf.IRI("urn:p"), object = rdf.literal_typed("42", rdf.XSD_INTEGER)})
	append(
		&b.triples,
		Alg_Triple{subject = rdf.Blank_Node("b0"), predicate = rdf.RDF_TYPE, object = rdf.literal_lang("chat", "fr")},
	)
	expect_sse(
		t,
		b,
		"(bgp (triple ?s <urn:p> 42) (triple _:b0 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> \"chat\"@fr))\n",
	)
}

@(test)
test_sse_filter_project_slice :: proc(t: ^testing.T) {
	gt := new(Binary_Expr)
	gt.op = .Gt
	gt.left = v("age")
	gt.right = rdf.literal_typed("18", rdf.XSD_INTEGER)
	defer free(gt)

	f := new(Alg_Filter)
	append(&f.conditions, Expr(gt))
	f.input = bgp1(v("s"), rdf.IRI("urn:age"), v("age"))

	pr := new(Alg_Project)
	append(&pr.vars, v("s"))
	pr.input = f

	d := new(Alg_Distinct)
	d.input = pr

	sl := new(Alg_Slice)
	sl.start = 5
	sl.length = 10
	sl.input = d
	defer destroy_algebra(sl)

	expect_sse(
		t,
		sl,
		"(slice 5 10\n" +
		"  (distinct\n" +
		"    (project (?s)\n" +
		"      (filter (> ?age 18)\n" +
		"        (bgp (triple ?s <urn:age> ?age))))))\n",
	)
}

@(test)
test_sse_leftjoin_union_graph :: proc(t: ^testing.T) {
	bound := new(Builtin_Call)
	bound.builtin = .Bound
	append(&bound.args, Expr(v("m")))
	defer {
		delete(bound.args)
		free(bound)
	}

	lj := new(Alg_Left_Join)
	lj.left = bgp1(v("s"), rdf.IRI("urn:p"), v("o"))
	lj.right = bgp1(v("s"), rdf.IRI("urn:m"), v("m"))
	lj.condition = bound

	u := new(Alg_Union)
	u.left = lj
	u.right = bgp1(v("a"), rdf.IRI("urn:q"), v("b"))

	g := new(Alg_Graph)
	g.graph = v("g")
	g.input = u
	defer destroy_algebra(g)

	expect_sse(
		t,
		g,
		"(graph ?g\n" +
		"  (union\n" +
		"    (leftjoin\n" +
		"      (bgp (triple ?s <urn:p> ?o))\n" +
		"      (bgp (triple ?s <urn:m> ?m))\n" +
		"      (bound ?m))\n" +
		"    (bgp (triple ?a <urn:q> ?b))))\n",
	)
}

@(test)
test_sse_extend_group_order :: proc(t: ^testing.T) {
	count := new(Aggregate)
	count.op = .Count
	count.is_distinct = true
	count.expr = v("v")
	defer free(count)

	grp := new(Alg_Group)
	append(&grp.by, Group_Condition{expr = v("s")})
	append(&grp.aggregates, Alg_Binding{v = v(".0"), expr = count})
	grp.input = bgp1(v("s"), rdf.IRI("urn:p"), v("v"))

	ext := new(Alg_Extend)
	append(&ext.bindings, Alg_Binding{v = v("n"), expr = v(".0")})
	ext.input = grp

	ord := new(Alg_Order)
	append(&ord.conditions, Order_Condition{expr = v("s"), direction = .Ascending})
	append(&ord.conditions, Order_Condition{expr = v("n"), direction = .Descending})
	ord.input = ext
	defer destroy_algebra(ord)

	expect_sse(
		t,
		ord,
		"(order (?s (desc ?n))\n" +
		"  (extend ((?n ?.0))\n" +
		"    (group (?s) ((?.0 (count distinct ?v)))\n" +
		"      (bgp (triple ?s <urn:p> ?v)))))\n",
	)
}

@(test)
test_sse_minus_and_paths :: proc(t: ^testing.T) {
	// (seq (seq <a> (reverse <b>)) (path* <c>)) — n-ary sequences fold
	// binary left-associative, ARQ style.
	link :: proc(iri: string) -> ^Path_Expr {
		l := new(Path_Expr)
		l.op = .Link
		l.iri = rdf.IRI(iri)
		return l
	}
	rev := new(Path_Expr)
	rev.op = .Inverse
	append(&rev.children, link("urn:b"))
	star := new(Path_Expr)
	star.op = .Zero_Or_More
	append(&star.children, link("urn:c"))
	seq := new(Path_Expr)
	seq.op = .Sequence
	append(&seq.children, link("urn:a"), rev, star)

	pathop := new(Alg_Path)
	pathop.subject = v("s")
	pathop.path = seq
	pathop.object = v("o")

	m := new(Alg_Minus)
	m.left = pathop
	m.right = bgp1(v("s"), rdf.IRI("urn:d"), v("x"))
	defer {
		destroy_path(seq)
		destroy_algebra(m)
	}

	expect_sse(
		t,
		m,
		"(minus\n" +
		"  (path ?s (seq (seq <urn:a> (reverse <urn:b>)) (path* <urn:c>)) ?o)\n" +
		"  (bgp (triple ?s <urn:d> ?x)))\n",
	)
}

@(test)
test_sse_table :: proc(t: ^testing.T) {
	tbl := new(Alg_Table)
	append(&tbl.vars, v("x"), v("y"))
	row1 := make([dynamic]Pattern_Node)
	append(&row1, Pattern_Node(rdf.literal_typed("1", rdf.XSD_INTEGER)), Pattern_Node(rdf.literal_plain("a")))
	row2 := make([dynamic]Pattern_Node)
	append(&row2, Pattern_Node(nil), Pattern_Node(rdf.literal_typed("true", rdf.XSD_BOOLEAN)))
	append(&tbl.rows, row1, row2)
	defer destroy_algebra(tbl)

	expect_sse(
		t,
		tbl,
		"(table (vars ?x ?y)\n" +
		"  (row [?x 1] [?y \"a\"])\n" +
		"  (row [?y true]))\n",
	)

	unit := new(Alg_Table)
	unit.unit = true
	defer destroy_algebra(unit)
	expect_sse(t, unit, "(table unit)\n")
}
