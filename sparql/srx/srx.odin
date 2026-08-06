// Package srx writes the SPARQL Query Results XML Format, with the
// SPARQL 1.2 additions for triple terms and base direction.
//
//	<sparql xmlns="http://www.w3.org/2005/sparql-results#">
//	  <head><variable name="x"/></head>
//	  <results><result><binding name="x"><uri>…</uri></binding></result></results>
//	</sparql>
//
// and, for ASK, a `<boolean>` in place of `<results>`.
//
// The shape follows odin-rdf-parser's emitters: `emitter_init` / `emit`
// / `emitter_finish` for the streaming SELECT form, and a stateless
// `emit_boolean` for ASK. Solutions are written one at a time and
// nothing materializes the result set.
//
// **Allocation.** None. Every value is written straight to the writer,
// escaping as it goes.
//
// **Borrowing.** The emitter keeps the caller's `vars` slice and the
// strings in it; both must outlive `emitter_finish`. Terms passed to
// `emit` are read and never retained.
//
// **Term encoding.** `<uri>`, `<bnode>` (label written *without* its
// `_:` prefix, which is serialization syntax rather than identity),
// `<literal>` with a `datatype` or `xml:lang` attribute, and `<triple>`
// with `<subject>`/`<predicate>`/`<object>` children for RDF-star triple
// terms. A literal with a base direction carries a `dir` attribute
// alongside `xml:lang`.
//
// **Output is not indented.** A result document is machine input; the
// bytes a caller wants are the smallest valid ones. Whitespace between
// elements would also be character content inside `<literal>`, so the
// writer never emits any it did not receive.
package srx

import "core:io"

import rdf "rdf:rdf"

// NS is the SPARQL results namespace.
NS :: "http://www.w3.org/2005/sparql-results#"

// Emitter streams a SELECT result set. Zero value is not usable; call
// emitter_init.
Emitter :: struct {
	w:    io.Writer,
	vars: []string,
}

// emitter_init writes the XML declaration, the root element, and the
// head. vars is borrowed, not copied, and is the order every row is
// written in.
emitter_init :: proc(e: ^Emitter, w: io.Writer, vars: []string) -> io.Error {
	e.w = w
	e.vars = vars

	io.write_string(w, `<?xml version="1.0"?>`) or_return
	io.write_string(w, `<sparql xmlns="` + NS + `"><head>`) or_return
	for v in vars {
		io.write_string(w, `<variable name="`) or_return
		write_xml_attr(w, v) or_return
		io.write_string(w, `"/>`) or_return
	}
	io.write_string(w, `</head><results>`) or_return
	return nil
}

// emit writes one solution. row is aligned to the vars given at init: a
// nil cell is an unbound variable, and unbound variables are omitted
// rather than written as an empty binding, per the format. A row shorter
// than vars is treated as unbound from there on; a longer one is a
// caller error and asserts.
emit :: proc(e: ^Emitter, row: []rdf.Term) -> io.Error {
	assert(len(row) <= len(e.vars), "solution has more cells than the emitter has variables")

	io.write_string(e.w, "<result>") or_return
	for term, i in row {
		if term == nil {
			continue
		}
		io.write_string(e.w, `<binding name="`) or_return
		write_xml_attr(e.w, e.vars[i]) or_return
		io.write_string(e.w, `">`) or_return
		write_term(e.w, term) or_return
		io.write_string(e.w, "</binding>") or_return
	}
	io.write_string(e.w, "</result>") or_return
	return nil
}

// emitter_finish closes the results element and the document. The
// emitter must not be used afterwards.
emitter_finish :: proc(e: ^Emitter) -> io.Error {
	io.write_string(e.w, "</results></sparql>") or_return
	return nil
}

// emit_boolean writes a complete ASK result document.
emit_boolean :: proc(w: io.Writer, value: bool) -> io.Error {
	io.write_string(w, `<?xml version="1.0"?>`) or_return
	io.write_string(w, `<sparql xmlns="` + NS + `"><head/><boolean>`) or_return
	io.write_string(w, "true" if value else "false") or_return
	io.write_string(w, "</boolean></sparql>") or_return
	return nil
}

@(private)
write_term :: proc(w: io.Writer, term: rdf.Term) -> io.Error {
	switch v in term {
	case rdf.IRI:
		io.write_string(w, "<uri>") or_return
		write_xml_text(w, string(v)) or_return
		io.write_string(w, "</uri>") or_return
		return nil

	case rdf.Blank_Node:
		io.write_string(w, "<bnode>") or_return
		write_xml_text(w, string(v)) or_return
		io.write_string(w, "</bnode>") or_return
		return nil

	case rdf.Literal:
		io.write_string(w, "<literal") or_return
		if v.language != "" {
			io.write_string(w, ` xml:lang="`) or_return
			write_xml_attr(w, v.language) or_return
			io.write_byte(w, '"') or_return
			#partial switch v.direction {
			case .LTR:
				io.write_string(w, ` dir="ltr"`) or_return
			case .RTL:
				io.write_string(w, ` dir="rtl"`) or_return
			}
		} else if v.datatype != "" && v.datatype != rdf.XSD_STRING {
			// A plain literal's datatype is xsd:string by the data
			// model's invariant; readers infer it.
			io.write_string(w, ` datatype="`) or_return
			write_xml_attr(w, string(v.datatype)) or_return
			io.write_byte(w, '"') or_return
		}
		io.write_byte(w, '>') or_return
		write_xml_text(w, v.lexical) or_return
		io.write_string(w, "</literal>") or_return
		return nil

	case ^rdf.Triple:
		io.write_string(w, "<triple><subject>") or_return
		write_term(w, v.subject) or_return
		io.write_string(w, "</subject><predicate>") or_return
		write_term(w, v.predicate) or_return
		io.write_string(w, "</predicate><object>") or_return
		write_term(w, v.object) or_return
		io.write_string(w, "</object></triple>") or_return
		return nil
	}
	return nil
}

// write_xml_text escapes character content: the two that could start
// markup, plus `>` (not strictly required outside `]]>`, but escaping it
// unconditionally is what every serializer does and costs nothing) and
// carriage return, which an XML processor would otherwise normalize away
// and silently change the literal's value.
@(private)
write_xml_text :: proc(w: io.Writer, s: string) -> io.Error {
	return write_escaped(w, s, false)
}

// write_xml_attr escapes attribute values: everything character content
// needs, plus the quote delimiter and the whitespace characters that
// attribute-value normalization would turn into spaces.
@(private)
write_xml_attr :: proc(w: io.Writer, s: string) -> io.Error {
	return write_escaped(w, s, true)
}

@(private)
write_escaped :: proc(w: io.Writer, s: string, attribute: bool) -> io.Error {
	start := 0
	for i in 0 ..< len(s) {
		escape: string
		switch s[i] {
		case '&':
			escape = "&amp;"
		case '<':
			escape = "&lt;"
		case '>':
			escape = "&gt;"
		case '\r':
			escape = "&#xD;"
		case '"':
			if attribute {
				escape = "&quot;"
			}
		case '\n':
			if attribute {
				escape = "&#xA;"
			}
		case '\t':
			if attribute {
				escape = "&#x9;"
			}
		}
		if escape == "" {
			continue
		}
		if i > start {
			io.write_string(w, s[start:i]) or_return
		}
		io.write_string(w, escape) or_return
		start = i + 1
	}
	if start < len(s) {
		io.write_string(w, s[start:]) or_return
	}
	return nil
}
