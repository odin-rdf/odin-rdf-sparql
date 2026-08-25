// The engine's own id vocabulary, over odin-rdf-record's ids
// (SPARQL-T-0031).
//
// Before the port this file did not exist: `store:store` published
// `Term_ID`, four sentinels, `Encoded_Quad` and `Match_Pattern`, and the
// engine imported them. odin-rdf-record publishes ids and a `Pattern`
// struct and nothing else, because it is a system of record rather than
// a match interface — so the shapes the executor indexes positionally
// are declared here, and converted at the scan boundary.
//
// **Why the engine keeps `[4]Term_ID` rather than adopting record's
// struct.** The executor indexes a quad and a pattern by position at ten
// sites, four of them dynamically — `quad[i]` inside `unify_quad`'s
// per-position loop is the hottest code in this package. A struct with
// named fields cannot be indexed by a loop variable, and reinterpreting
// record's `Quad` as an array would couple this repository to a
// sibling's field order across a repository boundary: a reorder there
// would compile cleanly here and corrupt every result. So the four
// components are copied into the engine's own array once per matched
// fact, and the loops are untouched (SPARQL-T-0031, owner 2026-08-24).
package sparql

import record "record:record"

// UNBOUND marks a solution-row slot that holds no binding, and WILDCARD
// a pattern position that matches anything.
//
// **On odin-rdf-record they are the same value, and that is safe rather
// than lucky.** odin-rdf-store gave each of its meanings a distinct
// tagged sentinel; record spends no id space on them and says instead
// that a `Pattern` component of 0 is unbound (read.odin's `Pattern`),
// while no fact carries 0 in S, P or O. So a row slot of 0 and a pattern
// position of 0 can never be confused with a term, and substituting an
// unbound slot into a pattern — which is exactly what makes an index
// probe a probe — becomes the identity rather than a translation.
//
// They stay two names because the two meanings are still two: a reader
// of `pattern[i] = WILDCARD` and of `e.work[slot] = UNBOUND` should not
// have to know they coincide, and a backend that separated them again
// would find every site already saying which it meant.
UNBOUND :: record.Term_ID(0)
WILDCARD :: record.Term_ID(0)

// DEFAULT_GRAPH selects exactly the default graph **in a pattern**, and
// is record's one reserved pattern value.
//
// **It does not appear in a fact**, which is the one place the port had
// to split a constant odin-rdf-store kept whole. record stores the
// default graph as `G = 0` (log.md par. 5.3, amended) — the same value a
// pattern reads as unbound — so a quad's graph component is compared
// against STORED_DEFAULT_GRAPH and never against this. Every site that
// reads a quad's G says which of the two it means; see `graph_scan_next`
// and `unify_quad`.
DEFAULT_GRAPH :: record.MATCH_DEFAULT_GRAPH

// STORED_DEFAULT_GRAPH is what a *fact* carries in G for the default
// graph. It is spelled as its own constant rather than as `0` because
// the same bits are also UNBOUND, and a bare `0` at those sites would
// read as either.
STORED_DEFAULT_GRAPH :: record.Term_ID(0)

// Encoded_Quad is a matched fact's four components, in S, P, O, G order.
// Built by the scan boundary from record's `Fact`; see this file's
// header for why it is an array.
Encoded_Quad :: [4]record.Term_ID

// Match_Pattern is a quad pattern over ids: WILDCARD in a position
// matches anything, anything else must match exactly, and
// DEFAULT_GRAPH in the graph position selects the default graph alone.
// Position indices are QUAD_S/P/O/G, as for Encoded_Quad.
Match_Pattern :: distinct [4]record.Term_ID

// MATCH_ALL matches every fact in the dataset, default graph included.
MATCH_ALL :: Match_Pattern{WILDCARD, WILDCARD, WILDCARD, WILDCARD}

// The component order both shapes use.
QUAD_S :: 0
QUAD_P :: 1
QUAD_O :: 2
QUAD_G :: 3
