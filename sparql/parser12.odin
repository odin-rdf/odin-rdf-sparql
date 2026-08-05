// SPARQL 1.2 surface syntax (SPARQL-T-0008): triple terms, reified
// triples, reifiers and annotation blocks, per the current SPARQL 1.2
// draft (mirroring Turtle 1.2). Reified triples and annotations
// desugar at parse time into rdf:reifies triples — only Triple_Term
// survives into the AST. Triple_Term nodes register in
// p.triple_terms because desugaring may share one node between the
// annotated pattern and its reifies triple; the registry frees them
// flatly (see destroy_pattern_node).
package sparql

import rdf "rdf:rdf"

// Term_Context restricts triple-term constituents by where the term
// appears: patterns allow variables and blank nodes, expressions
// forbid blank nodes, and VALUES data blocks must be ground.
Term_Context :: enum {
	Pattern,
	Expression,
	Data,
}

// parse_triple_term parses tripleTerm ::= '<<(' ttSubject Verb
// ttObject ')>>', with the opening token current. The subject position
// excludes literals and nested triple terms; nesting is object-side
// only.
@(private)
parse_triple_term :: proc(p: ^Parser, ctx: Term_Context) -> ^Triple_Term {
	pos := token_pos(p.tok)
	advance(p) // '<<('
	tt := new(Triple_Term, p.allocator)
	append(&p.triple_terms, tt)
	tt.pos = pos
	tt.subject = parse_tt_node(p, ctx, true)
	if p.err.kind != .None {
		return tt
	}
	tt.predicate = parse_rt_verb(p, ctx)
	if p.err.kind != .None {
		return tt
	}
	tt.object = parse_tt_node(p, ctx, false)
	if p.err.kind != .None {
		return tt
	}
	if !at(p, .Triple_Term_Close) {
		fail_current(p, .Unclosed_Triple_Term)
		return tt
	}
	advance(p)
	return tt
}

@(private = "file")
parse_tt_node :: proc(p: ^Parser, ctx: Term_Context, subject_position: bool) -> Pattern_Node {
	if !p.has_tok {
		fail_here(p, .Expected_Object)
		return nil
	}
	tok := p.tok
	if at(p, .Triple_Term_Open) {
		// A nested triple term may not be a SUBJECT in ground/expression
		// contexts (the sparql12 tripleterm-subject tests); graph
		// patterns allow it.
		if subject_position && ctx != .Pattern {
			fail_at(p, .Expected_Subject, tok)
			return nil
		}
		return parse_triple_term(p, ctx)
	}
	#partial switch tok.kind {
	case .Var:
		if ctx == .Data {
			fail_at(p, .Expected_Data_Value, tok)
			return nil
		}
	case .Blank_Node_Label, .Anon:
		if ctx != .Pattern {
			fail_at(p, .Expected_Data_Value if ctx == .Data else .Expected_Expression, tok)
			return nil
		}
	case .String_Literal, .Integer, .Decimal, .Double, .Boolean:
		if subject_position && ctx != .Pattern {
			fail_at(p, .Expected_Subject, tok)
			return nil
		}
	case .Nil:
		// '()' — rdf:nil via the collection shorthand — is not a
		// triple-term constituent (the sparql12 list-* tests).
		fail_at(p, .Expected_Object, tok)
		return nil
	}
	node := parse_var_or_term(p)
	if node == nil && p.err.kind == .None {
		fail_current(p, .Expected_Object)
	}
	return node
}

// parse_rt_verb parses the predicate of a reified triple or triple
// term: a variable ('a' and IRIs everywhere; no variables in data).
@(private = "file")
parse_rt_verb :: proc(p: ^Parser, ctx: Term_Context) -> Pattern_Node {
	switch {
	case at(p, .Var):
		if ctx == .Data {
			fail_at(p, .Expected_Data_Value, p.tok)
			return nil
		}
		v := var_of(p.tok)
		advance(p)
		return v
	case at(p, .A):
		advance(p)
		return rdf.RDF_TYPE
	case at(p, .IRI_Ref), at(p, .PName):
		iri, ok := parse_iri(p)
		if !ok {
			return nil
		}
		return iri
	}
	fail_current(p, .Expected_Predicate)
	return nil
}

// parse_reified_triple parses reifiedTriple ::= '<<' rtSubject Verb
// rtObject reifier? '>>' with the opening token current, desugaring to
// `R rdf:reifies <<(s p o)>>` appended to bp; R (named or fresh)
// stands in the enclosing triple.
@(private)
parse_reified_triple :: proc(p: ^Parser, bp: ^Basic_Pattern) -> Pattern_Node {
	pos := token_pos(p.tok)
	advance(p) // '<<'
	tt := new(Triple_Term, p.allocator)
	append(&p.triple_terms, tt)
	tt.pos = pos
	tt.subject = parse_rt_node(p, bp)
	if p.err.kind != .None {
		return nil
	}
	tt.predicate = parse_rt_verb(p, .Pattern)
	if p.err.kind != .None {
		return nil
	}
	tt.object = parse_rt_node(p, bp)
	if p.err.kind != .None {
		return nil
	}
	reifier: Pattern_Node
	if at(p, .Tilde) {
		advance(p)
		reifier = parse_reifier_id(p)
		if p.err.kind != .None {
			return nil
		}
	}
	if reifier == nil {
		reifier = fresh_blank(p)
	}
	if !at(p, .Reified_Close) {
		fail_current(p, .Unclosed_Reified_Triple)
		return nil
	}
	advance(p)
	append(&bp.triples, Triple_Pattern{subject = reifier, predicate = rdf.RDF_REIFIES, object = tt, pos = pos})
	return reifier
}

// parse_rt_node parses rtSubject/rtObject: variables, terms, triple
// terms (both positions here, unlike inside triple terms), and nested
// reified triples.
@(private = "file")
parse_rt_node :: proc(p: ^Parser, bp: ^Basic_Pattern) -> Pattern_Node {
	if at(p, .Reified_Open) {
		return parse_reified_triple(p, bp)
	}
	if at(p, .Triple_Term_Open) {
		return parse_triple_term(p, .Pattern)
	}
	return parse_tt_node(p, .Pattern, false)
}

// parse_reifier_id parses the optional varOrReifierId after '~': a
// variable, IRI, or blank node; nothing (an anonymous reifier) when
// the next token cannot start one.
@(private = "file")
parse_reifier_id :: proc(p: ^Parser) -> Pattern_Node {
	if !p.has_tok {
		return nil
	}
	#partial switch p.tok.kind {
	case .Var, .IRI_Ref, .PName, .Blank_Node_Label, .Anon:
		return parse_var_or_term(p)
	}
	return nil // bare '~': anonymous reifier, caller generates
}

// parse_annotations parses the (reifier | annotationBlock)* suffix
// after an object. Each '~' names (or freshly creates) a reifier and
// emits its rdf:reifies triple immediately; an annotation block
// attaches a property list to the pending reifier, creating a fresh
// one when none is pending, and clears it after closing.
@(private)
parse_annotations :: proc(p: ^Parser, bp: ^Basic_Pattern, subject, predicate, object: Pattern_Node, pos: Position) {
	pending: Pattern_Node
	for p.err.kind == .None {
		switch {
		case at(p, .Tilde):
			advance(p)
			reifier := parse_reifier_id(p)
			if p.err.kind != .None {
				return
			}
			if reifier == nil {
				reifier = fresh_blank(p)
			}
			emit_reifies(p, bp, reifier, subject, predicate, object, pos)
			pending = reifier
		case at(p, .Annotation_Open):
			advance(p)
			if pending == nil {
				pending = fresh_blank(p)
				emit_reifies(p, bp, pending, subject, predicate, object, pos)
			}
			if !starts_verb(p) {
				fail_current(p, .Expected_Predicate)
				return
			}
			parse_property_list(p, bp, pending, pos)
			if p.err.kind != .None {
				return
			}
			if !at(p, .Annotation_Close) {
				fail_current(p, .Unclosed_Annotation)
				return
			}
			advance(p)
			pending = nil
		case:
			return
		}
	}
}

@(private = "file")
emit_reifies :: proc(p: ^Parser, bp: ^Basic_Pattern, reifier, subject, predicate, object: Pattern_Node, pos: Position) {
	tt := new(Triple_Term, p.allocator)
	append(&p.triple_terms, tt)
	tt.pos = pos
	tt.subject = subject
	tt.predicate = predicate
	tt.object = object
	append(&bp.triples, Triple_Pattern{subject = reifier, predicate = rdf.RDF_REIFIES, object = tt, pos = pos})
}
