// A deliberately small XML reader, for the harness only.
//
// Two of the W3C expected-result formats are XML: the SPARQL Results
// XML format (`.srx`) and, in sparql10-sort, the result-set vocabulary
// serialized as RDF/XML (`.rdf`). Both are machine-generated and use a
// narrow, regular subset of XML, so the harness reads them with the
// scanner below rather than taking on a general XML parser as a
// dependency.
//
// The subset, stated so the boundary is explicit rather than
// discovered: elements, attributes (single- or double-quoted),
// character data, CDATA sections, comments, processing instructions,
// and a DOCTYPE declaration with no internal subset. The five
// predefined entities and numeric character references are decoded;
// any other entity reference is left as written. Namespaces are *not*
// resolved — an element or attribute name is reduced to its local part
// (the text after the last ':'), which is unambiguous for these files
// because they use one prefix per vocabulary and never rebind it. A
// document that leaves the subset fails to parse rather than being
// silently misread; readers_test.odin parses every vendored file as
// the guard that the assumption holds.
package w3c

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Xml_Attr is one attribute of an element: local name, decoded value.
Xml_Attr :: struct {
	name:  string,
	value: string,
}

// Xml_Element is a node of the parsed tree. text is the element's own
// character data, concatenated across the gaps between its children and
// decoded; children are in document order. Both the element and every
// string it holds are owned by the tree and freed by xml_destroy.
Xml_Element :: struct {
	name:     string,
	attrs:    [dynamic]Xml_Attr,
	text:     string,
	children: [dynamic]^Xml_Element,
}

// xml_parse builds the tree of the document's root element. ok is false
// for a malformed document or one outside the subset above; nothing is
// allocated in that case beyond what the partial tree held, which is
// freed before returning.
xml_parse :: proc(source: string, allocator := context.allocator) -> (root: ^Xml_Element, ok: bool) {
	p := Xml_Parser {
		src       = source,
		allocator = allocator,
	}
	skip_prolog(&p)
	if p.pos >= len(p.src) || p.src[p.pos] != '<' {
		return nil, false
	}
	root, ok = parse_element(&p)
	if !ok {
		if root != nil {
			xml_destroy(root, allocator)
		}
		return nil, false
	}
	return root, true
}

// xml_destroy frees an element and everything below it.
xml_destroy :: proc(e: ^Xml_Element, allocator := context.allocator) {
	if e == nil {
		return
	}
	for child in e.children {
		xml_destroy(child, allocator)
	}
	delete(e.children)
	for a in e.attrs {
		delete(a.name, allocator)
		delete(a.value, allocator)
	}
	delete(e.attrs)
	delete(e.name, allocator)
	delete(e.text, allocator)
	free(e, allocator)
}

// xml_attr returns an attribute's value by local name, and whether it
// was present. Callers match on the local part, so `xml:lang` is found
// as "lang" and `rdf:datatype` as "datatype".
xml_attr :: proc(e: ^Xml_Element, name: string) -> (value: string, found: bool) {
	for a in e.attrs {
		if a.name == name {
			return a.value, true
		}
	}
	return "", false
}

// xml_child returns the first child with the given local name.
xml_child :: proc(e: ^Xml_Element, name: string) -> ^Xml_Element {
	for c in e.children {
		if c.name == name {
			return c
		}
	}
	return nil
}

@(private = "file")
Xml_Parser :: struct {
	src:       string,
	pos:       int,
	allocator: runtime.Allocator,
}

// skip_prolog consumes whitespace, the XML declaration, comments, and a
// DOCTYPE, stopping at the root element's '<'.
@(private = "file")
skip_prolog :: proc(p: ^Xml_Parser) {
	for p.pos < len(p.src) {
		skip_space(p)
		if !skip_markup_noise(p) {
			return
		}
	}
}

// skip_markup_noise consumes one comment, processing instruction, or
// DOCTYPE at the cursor and reports whether it consumed anything.
@(private = "file")
skip_markup_noise :: proc(p: ^Xml_Parser) -> bool {
	rest := p.src[p.pos:]
	switch {
	case strings.has_prefix(rest, "<!--"):
		if end := strings.index(rest, "-->"); end >= 0 {
			p.pos += end + 3
		} else {
			p.pos = len(p.src)
		}
		return true
	case strings.has_prefix(rest, "<?"):
		if end := strings.index(rest, "?>"); end >= 0 {
			p.pos += end + 2
		} else {
			p.pos = len(p.src)
		}
		return true
	case strings.has_prefix(rest, "<!DOCTYPE"):
		// No internal subset in these files, so the declaration ends at
		// the first '>'.
		if end := strings.index_byte(rest, '>'); end >= 0 {
			p.pos += end + 1
		} else {
			p.pos = len(p.src)
		}
		return true
	}
	return false
}

@(private = "file")
skip_space :: proc(p: ^Xml_Parser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', '\n':
			p.pos += 1
		case:
			return
		}
	}
}

// parse_element parses the element starting at the cursor's '<',
// including its content and end tag.
@(private = "file")
parse_element :: proc(p: ^Xml_Parser) -> (e: ^Xml_Element, ok: bool) {
	if p.pos >= len(p.src) || p.src[p.pos] != '<' {
		return nil, false
	}
	p.pos += 1
	name := scan_name(p)
	if name == "" {
		return nil, false
	}

	e = new(Xml_Element, p.allocator)
	e.name = strings.clone(local_name(name), p.allocator)
	e.attrs = make([dynamic]Xml_Attr, p.allocator)
	e.children = make([dynamic]^Xml_Element, p.allocator)

	// Attributes, then either '/>' (empty element) or '>' (content
	// follows and an end tag closes it).
	self_closing := false
	for {
		skip_space(p)
		if p.pos >= len(p.src) {
			xml_destroy(e, p.allocator)
			return nil, false
		}
		if p.src[p.pos] == '>' {
			p.pos += 1
			break
		}
		if strings.has_prefix(p.src[p.pos:], "/>") {
			p.pos += 2
			self_closing = true
			break
		}
		attr_name := scan_name(p)
		if attr_name == "" {
			xml_destroy(e, p.allocator)
			return nil, false
		}
		skip_space(p)
		if p.pos >= len(p.src) || p.src[p.pos] != '=' {
			xml_destroy(e, p.allocator)
			return nil, false
		}
		p.pos += 1
		skip_space(p)
		value, value_ok := scan_attr_value(p)
		if !value_ok {
			xml_destroy(e, p.allocator)
			return nil, false
		}
		append(&e.attrs, Xml_Attr{strings.clone(local_name(attr_name), p.allocator), value})
	}

	if self_closing {
		e.text = strings.clone("", p.allocator)
		return e, true
	}

	text := strings.builder_make(p.allocator)
	defer strings.builder_destroy(&text)
	for {
		if p.pos >= len(p.src) {
			xml_destroy(e, p.allocator)
			return nil, false
		}
		if p.src[p.pos] != '<' {
			append_text_run(p, &text)
			continue
		}
		rest := p.src[p.pos:]
		switch {
		case strings.has_prefix(rest, "</"):
			p.pos += 2
			end_name := scan_name(p)
			skip_space(p)
			if p.pos >= len(p.src) || p.src[p.pos] != '>' || local_name(end_name) != e.name {
				xml_destroy(e, p.allocator)
				return nil, false
			}
			p.pos += 1
			e.text = strings.clone(strings.to_string(text), p.allocator)
			return e, true
		case strings.has_prefix(rest, "<![CDATA["):
			p.pos += 9
			end := strings.index(p.src[p.pos:], "]]>")
			if end < 0 {
				xml_destroy(e, p.allocator)
				return nil, false
			}
			strings.write_string(&text, p.src[p.pos:][:end])
			p.pos += end + 3
		case skip_markup_noise(p):
		// A comment or PI between children contributes no text.
		case:
			child, child_ok := parse_element(p)
			if !child_ok {
				xml_destroy(e, p.allocator)
				return nil, false
			}
			append(&e.children, child)
		}
	}
}

// append_text_run consumes character data up to the next '<', decoding
// entity and character references as it goes.
@(private = "file")
append_text_run :: proc(p: ^Xml_Parser, out: ^strings.Builder) {
	for p.pos < len(p.src) && p.src[p.pos] != '<' {
		if p.src[p.pos] == '&' {
			write_reference(p, out)
			continue
		}
		strings.write_byte(out, p.src[p.pos])
		p.pos += 1
	}
}

// write_reference decodes the reference at the cursor. An unrecognized
// reference is written through verbatim — these files use only the
// predefined five and numeric references, and passing anything else
// along keeps a surprise visible in the comparison rather than
// silently dropped.
@(private = "file")
write_reference :: proc(p: ^Xml_Parser, out: ^strings.Builder) {
	rest := p.src[p.pos:]
	end := strings.index_byte(rest, ';')
	if end < 0 {
		strings.write_byte(out, '&')
		p.pos += 1
		return
	}
	name := rest[1:end]
	switch name {
	case "lt":
		strings.write_byte(out, '<')
	case "gt":
		strings.write_byte(out, '>')
	case "amp":
		strings.write_byte(out, '&')
	case "quot":
		strings.write_byte(out, '"')
	case "apos":
		strings.write_byte(out, '\'')
	case:
		code, code_ok := parse_char_reference(name)
		if !code_ok {
			strings.write_string(out, rest[:end + 1])
			p.pos += end + 1
			return
		}
		buf, width := utf8.encode_rune(code)
		strings.write_bytes(out, buf[:width])
	}
	p.pos += end + 1
}

@(private = "file")
parse_char_reference :: proc(name: string) -> (r: rune, ok: bool) {
	if !strings.has_prefix(name, "#") {
		return 0, false
	}
	digits := name[1:]
	base := 10
	if strings.has_prefix(digits, "x") || strings.has_prefix(digits, "X") {
		digits = digits[1:]
		base = 16
	}
	if digits == "" {
		return 0, false
	}
	value, parse_ok := strconv.parse_u64_of_base(digits, base)
	if !parse_ok || value > 0x10FFFF {
		return 0, false
	}
	return rune(value), true
}

@(private = "file")
scan_name :: proc(p: ^Xml_Parser) -> string {
	start := p.pos
	for p.pos < len(p.src) {
		switch c := p.src[p.pos]; c {
		case ' ', '\t', '\r', '\n', '>', '/', '=':
			return p.src[start:p.pos]
		case:
			p.pos += 1
		}
	}
	return p.src[start:p.pos]
}

@(private = "file")
scan_attr_value :: proc(p: ^Xml_Parser) -> (value: string, ok: bool) {
	if p.pos >= len(p.src) {
		return "", false
	}
	quote := p.src[p.pos]
	if quote != '"' && quote != '\'' {
		return "", false
	}
	p.pos += 1
	b := strings.builder_make(p.allocator)
	defer strings.builder_destroy(&b)
	for p.pos < len(p.src) && p.src[p.pos] != quote {
		if p.src[p.pos] == '&' {
			write_reference(p, &b)
			continue
		}
		strings.write_byte(&b, p.src[p.pos])
		p.pos += 1
	}
	if p.pos >= len(p.src) {
		return "", false
	}
	p.pos += 1
	return strings.clone(strings.to_string(b), p.allocator), true
}

// local_name drops a namespace prefix; see the package note on why
// prefixes are not resolved.
@(private = "file")
local_name :: proc(name: string) -> string {
	if idx := strings.last_index_byte(name, ':'); idx >= 0 {
		return name[idx + 1:]
	}
	return name
}
