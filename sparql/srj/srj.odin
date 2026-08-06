// Package srj writes the SPARQL 1.1 Query Results JSON Format, with the
// SPARQL 1.2 additions for triple terms and base direction.
//
//	{ "head": { "vars": [ "x" ] },
//	  "results": { "bindings": [ { "x": {"type": "uri", "value": "…"} } ] } }
//
// and, for ASK, `{ "head": {}, "boolean": true }`.
//
// The shape follows odin-rdf-parser's emitters: `emitter_init` /
// `emit` / `emitter_finish` for the streaming SELECT form, and a
// stateless `emit_boolean` for ASK, which is one document with nothing
// to stream. Solutions are written one at a time and nothing
// materializes the result set — the emitter holds a writer, the caller's
// variable list, and a row counter.
//
// **Allocation.** None. Every value is written straight to the writer,
// escaping as it goes.
//
// **Borrowing.** The emitter keeps the caller's `vars` slice and the
// strings in it; both must outlive `emitter_finish`. Terms passed to
// `emit` are read and never retained.
//
// **Term encoding.** IRIs are `{"type":"uri"}`, blank nodes
// `{"type":"bnode"}` with the label written *without* its `_:` prefix
// (which is serialization syntax, not identity — see rdf.Blank_Node),
// literals `{"type":"literal"}` with `datatype` or `xml:lang`, and
// RDF-star triple terms `{"type":"triple"}` whose value is an object of
// subject/predicate/object. A literal with a base direction carries
// `its:dir` alongside `xml:lang`, the key the ITS vocabulary gives it.
package srj

import "core:io"

import rdf "rdf:rdf"

// Emitter streams a SELECT result set. Zero value is not usable; call
// emitter_init.
Emitter :: struct {
	w:    io.Writer,
	vars: []string,
	rows: int,
}

// emitter_init writes the head and opens the bindings array. vars is
// borrowed, not copied, and is the order every row is written in.
emitter_init :: proc(e: ^Emitter, w: io.Writer, vars: []string) -> io.Error {
	e.w = w
	e.vars = vars
	e.rows = 0

	io.write_string(w, `{"head":{"vars":[`) or_return
	for v, i in vars {
		if i > 0 {
			io.write_byte(w, ',') or_return
		}
		write_json_string(w, v) or_return
	}
	io.write_string(w, `]},"results":{"bindings":[`) or_return
	return nil
}

// emit writes one solution. row is aligned to the vars given at init: a
// nil cell is an unbound variable, and unbound variables are omitted
// from the object rather than written as null, per the format. A row
// shorter than vars is treated as unbound from there on; a longer one is
// a caller error and asserts.
emit :: proc(e: ^Emitter, row: []rdf.Term) -> io.Error {
	assert(len(row) <= len(e.vars), "solution has more cells than the emitter has variables")

	if e.rows > 0 {
		io.write_byte(e.w, ',') or_return
	}
	e.rows += 1

	io.write_byte(e.w, '{') or_return
	written := 0
	for term, i in row {
		if term == nil {
			continue
		}
		if written > 0 {
			io.write_byte(e.w, ',') or_return
		}
		written += 1
		write_json_string(e.w, e.vars[i]) or_return
		io.write_byte(e.w, ':') or_return
		write_term(e.w, term) or_return
	}
	io.write_byte(e.w, '}') or_return
	return nil
}

// emitter_finish closes the bindings array and the document. The
// emitter must not be used afterwards.
emitter_finish :: proc(e: ^Emitter) -> io.Error {
	io.write_string(e.w, "]}}") or_return
	return nil
}

// emit_boolean writes a complete ASK result document.
emit_boolean :: proc(w: io.Writer, value: bool) -> io.Error {
	io.write_string(w, `{"head":{},"boolean":`) or_return
	io.write_string(w, "true" if value else "false") or_return
	return io.write_byte(w, '}')
}

@(private)
write_term :: proc(w: io.Writer, term: rdf.Term) -> io.Error {
	switch v in term {
	case rdf.IRI:
		io.write_string(w, `{"type":"uri","value":`) or_return
		write_json_string(w, string(v)) or_return
		return io.write_byte(w, '}')

	case rdf.Blank_Node:
		io.write_string(w, `{"type":"bnode","value":`) or_return
		write_json_string(w, string(v)) or_return
		return io.write_byte(w, '}')

	case rdf.Literal:
		io.write_string(w, `{"type":"literal","value":`) or_return
		write_json_string(w, v.lexical) or_return
		if v.language != "" {
			io.write_string(w, `,"xml:lang":`) or_return
			write_json_string(w, v.language) or_return
			#partial switch v.direction {
			case .LTR:
				io.write_string(w, `,"its:dir":"ltr"`) or_return
			case .RTL:
				io.write_string(w, `,"its:dir":"rtl"`) or_return
			}
		} else if v.datatype != "" && v.datatype != rdf.XSD_STRING {
			// A plain literal's datatype is xsd:string by the data
			// model's invariant; writing it back would be correct but
			// noisy, and readers infer it.
			io.write_string(w, `,"datatype":`) or_return
			write_json_string(w, string(v.datatype)) or_return
		}
		return io.write_byte(w, '}')

	case ^rdf.Triple:
		io.write_string(w, `{"type":"triple","value":{"subject":`) or_return
		write_term(w, v.subject) or_return
		io.write_string(w, `,"predicate":`) or_return
		write_term(w, v.predicate) or_return
		io.write_string(w, `,"object":`) or_return
		write_term(w, v.object) or_return
		io.write_string(w, "}}") or_return
		return nil
	}
	return nil
}

// write_json_string writes a JSON string literal. Only what RFC 8259
// requires is escaped: the quote, the backslash, and the C0 controls --
// the short forms where they exist and \u00XX otherwise. Everything else,
// including all non-ASCII, passes through as UTF-8.
@(private)
write_json_string :: proc(w: io.Writer, s: string) -> io.Error {
	io.write_byte(w, '"') or_return
	start := 0
	for i in 0 ..< len(s) {
		c := s[i]
		escape: string
		switch c {
		case '"':
			escape = `\"`
		case '\\':
			escape = `\\`
		case '\n':
			escape = `\n`
		case '\r':
			escape = `\r`
		case '\t':
			escape = `\t`
		case '\b':
			escape = `\b`
		case '\f':
			escape = `\f`
		case:
			if c >= 0x20 {
				continue
			}
		}
		if i > start {
			io.write_string(w, s[start:i]) or_return
		}
		if escape != "" {
			io.write_string(w, escape) or_return
		} else {
			hex := "0123456789abcdef"
			io.write_string(w, `\u00`) or_return
			io.write_byte(w, hex[c >> 4]) or_return
			io.write_byte(w, hex[c & 0xf]) or_return
		}
		start = i + 1
	}
	if start < len(s) {
		io.write_string(w, s[start:]) or_return
	}
	return io.write_byte(w, '"')
}
