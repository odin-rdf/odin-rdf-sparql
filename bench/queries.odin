package main

// The query mix: one query per operator class the port touches
// (SPARQL-I-0003 §10). Each is named, each is reported as a line, and
// each is chosen so that the operator under test is what dominates the
// work rather than a scan that happens to sit underneath it.
//
// These are the *portable* half of the benchmark — they are text, they
// name no backend, and SPARQL-T-0036 runs them unchanged against
// odin-rdf-record.

// A Case is one measured query.
Case :: struct {
	name:  string,
	// What operator class this exists to exercise, in the report line,
	// because "bgp3" alone does not say why three patterns.
	about: string,
	text:  string,
}

PREFIX :: "PREFIX b: <" + NS + ">\n"

CASES := []Case {
	// Two patterns over the same subject: the simplest join, and the one
	// whose cost is dominated by how many candidates the first pattern
	// produces. ~~This is what SPARQL-T-0037's cardinality ordering will
	// change the plan of, so its "before" number matters twice.~~
	// **It changed nothing** (SPARQL-T-0037): both patterns have one
	// candidate per entity, so the counts tie and stability keeps the
	// written order. Its value now is the opposite one — it is where a
	// plan-time pricing cost would have shown up, and it does not.
	{
		name = "bgp2",
		about = "two-pattern BGP join on a shared subject",
		text = PREFIX + `SELECT ?s ?name WHERE { ?s a b:Entity . ?s b:name ?name }`,
	},

	// Three patterns with a shared variable in the middle: a real join
	// ordering problem, since the selective pattern is not written first.
	// ~~Written deliberately worst-first — `a b:Entity` matches every
	// entity — so that a planner which reorders has something to gain and
	// one which does not is visibly paying for it.~~
	//
	// **That was wrong, and SPARQL-T-0037 measured it.** `a b:Entity` is
	// 20,000 candidates, `b:knows` is 80,000 and `b:name` is 20,000, and
	// as written this is the *optimal* left-deep plan: 100,001 scans for
	// 80,000 solutions, which is the floor. There was nothing here to
	// gain. Worse, ordering on cost alone would pick 0, 2, 1 and pair
	// every entity with every name — the case that made connectivity the
	// first level of the rule rather than the second. `bgp3-selective-
	// last` below is the badly-ordered case this one was believed to be.
	{
		name = "bgp3",
		about = "three-pattern BGP, selective pattern written last",
		text = PREFIX +
		`SELECT ?s ?o ?name WHERE { ?s a b:Entity . ?s b:knows ?o . ?o b:name ?name }`,
	},

	// A bound graph. **This is the §12 case** — odin-rdf-store answers it
	// from a prefix range because every one of its indexes is graph-first,
	// and odin-rdf-record cannot, its six orders all ending with G as the
	// residual tiebreaker (RECORD-A-0004). The configurations vary the
	// default graph's size while holding this graph's size fixed, so the
	// question the pair answers is: does the cost of naming a graph depend
	// on how much data is in the graphs you did not name?
	{
		name = "graph",
		about = "GRAPH <g1> { ?s ?p ?o } -- the graph-first regression case",
		// Since record v0.6.0 (SPARQL-T-0046) the regression is gone: G
		// leads the GPOS order and the window is exactly the graph.
		text = PREFIX + `SELECT ?s ?p ?o WHERE { GRAPH b:g1 { ?s ?p ?o } }`,
	},

	// OPTIONAL with a right side that is present for some rows and absent
	// for others. A right side present for all of them is a join wearing
	// OPTIONAL's name and would measure the wrong thing.
	{
		name = "optional",
		about = "left join, right side absent for most rows",
		text = PREFIX +
		`SELECT ?s ?nick WHERE { ?s a b:Entity . OPTIONAL { ?s b:nickname ?nick } }`,
	},

	// Aggregation over a low-cardinality key: the group table stays small
	// and the cost is the scan plus the accumulate, which is the shape a
	// consumer's dashboard query has.
	{
		name = "group",
		about = "GROUP BY over a low-cardinality key, two aggregates",
		text = PREFIX +
		`SELECT ?d (COUNT(?s) AS ?n) (AVG(?r) AS ?avg) WHERE { ?s b:dept ?d . ?s b:rank ?r } GROUP BY ?d`,
	},

	// A full sort. The key is the name literal, not the subject, so the
	// input is not already in order -- see entity_name in generate.odin.
	{
		name = "order",
		about = "ORDER BY over a literal key, whole solution set",
		text = PREFIX + `SELECT ?s ?name WHERE { ?s b:name ?name } ORDER BY ?name`,
	},

	// The same sort with a small LIMIT. Today this materializes and sorts
	// everything and then discards all but ten; ~~SPARQL-T-0038's
	// streaming-order consumer is what makes it stop at ten, so this pair
	// is that task's before-and-after in one line each.~~
	//
	// **Re-aimed 2026-08-25 at `SPARQL-T-0041`.** SPARQL-T-0038 is closed
	// as evidence — record's id order is not SPARQL's, so a *streaming*
	// sort is blocked permanently. Stopping at ten never needed the store:
	// a bounded heap over the same comparator does it, and this line is
	// that task's before-and-after. The pair with `order` is what makes it
	// readable — they are within noise of each other today, which is the
	// finding.
	{
		name = "order-limit",
		about = "ORDER BY ... LIMIT 10 -- sorts everything today",
		text = PREFIX + `SELECT ?s ?name WHERE { ?s b:name ?name } ORDER BY ?name LIMIT 10`,
	},

	// **The case `bgp3` was supposed to be, and is not.** Added by
	// SPARQL-T-0037, whose measurement found every existing case here
	// already optimally ordered — `bgp3` included, despite its comment.
	// Three patterns on one subject, the selective one written last:
	// `a b:Entity` and `b:name` are one per entity, `b:dept b:d0` is one
	// in `depts`. Written order probes twenty thousand rows through two
	// patterns to reach the ~1,700 that a planner reaches by starting
	// with the third.
	//
	// It is a fair case rather than a rigged one: the shape — filter the
	// population by a low-cardinality attribute, then project two more —
	// is what a consumer's dashboard query looks like, and writing the
	// filter last is what a person does when they think of the filter
	// last.
	{
		name = "bgp3-selective-last",
		about = "three patterns, the selective one written last -- SPARQL-T-0037's case",
		text = PREFIX +
		`SELECT ?s ?name WHERE { ?s a b:Entity . ?s b:name ?name . ?s b:dept b:d0 }`,
	},

	// **The merge join's declining case** (SPARQL-T-0029), and the only
	// case here that exists to make a planner say no. Same two-pattern
	// shape as `bgp2`, with the left side narrowed to one node's
	// neighbours: `b:knows` from `b:e0` is four facts where `b:name` is
	// one per entity, so the right window is ~5,000x the left and
	// MERGE_SCAN_PRICE declines the merge.
	//
	// **It guards the decision, not a timing.** The row to watch is
	// `match`: 5 is the nested loop (one scan plus four probes) and 2
	// would be a merge, so raising the price past this ratio moves this
	// pin and nothing else here would notice.
	//
	// Its *timing* is deliberately not the argument, because on this
	// corpus the declined merge would have been fast anyway — and why is
	// worth writing down. record assigns dictionary ids in first-mention
	// order, and `b:e0`'s four targets are first mentioned while `b:e0`
	// itself is being emitted, so they hold among the lowest entity ids
	// in the store and sit at the very front of the right window. A merge
	// walks only as far as the largest join value it is asked for, so it
	// would touch six facts of 20,500 here. Nothing in the pattern says
	// so, which is exactly why the planner prices the full walk instead.
	{
		name = "bgp2-narrow-left",
		about = "two patterns, left side ~5000x smaller -- the merge's declining case",
		text = PREFIX + `SELECT ?o ?name WHERE { b:e0 b:knows ?o . ?o b:name ?name }`,
	},

	// A property path from one fixed start node. Fixed rather than
	// unbound on purpose: `?a b:knows+ ?b` over this corpus is quadratic
	// and would measure the generator's fan-out rather than the operator.
	// From one node the frontier grows and then saturates, which is the
	// traversal a consumer actually writes.
	{
		name = "path",
		about = "b:knows+ from one fixed start node",
		text = PREFIX + `SELECT ?x WHERE { b:e0 b:knows+ ?x }`,
	},
}
