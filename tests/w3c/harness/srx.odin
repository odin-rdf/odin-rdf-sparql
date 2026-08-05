// Reader for the SPARQL Query Results XML Format (`.srx`), the format
// the great majority of the vendored evaluation suites state their
// expectations in.
//
// The grammar this reads is the one the specification fixes:
//
//	<sparql>
//	  <head><variable name="x"/> …</head>
//	  <results>
//	    <result><binding name="x"><uri>…</uri></binding> …</result>
//	  </results>
//	</sparql>
//
// with <boolean>true|false</boolean> in place of <results> for an ASK
// answer, and a binding's value being one of <uri>, <bnode>, <literal>
// (bare, `datatype=`, or `xml:lang=`), or the SPARQL 1.2 <triple> with
// <subject>/<predicate>/<object> children. Elements outside that set —
// <link> in the head, for instance — are ignored rather than rejected:
// they carry no part of the answer.
package w3c

import "core:strings"

import rdf "rdf:rdf"

// read_srx parses an SRX document into a Result_Set. ok is false if the
// document is not XML in this package's subset or has no <sparql> root.
// The caller owns the result and frees it with result_set_destroy.
read_srx :: proc(source: string) -> (rs: Result_Set, ok: bool) {
	root, xml_ok := xml_parse(source)
	if !xml_ok {
		return {}, false
	}
	defer xml_destroy(root)
	if root.name != "sparql" {
		return {}, false
	}

	if head := xml_child(root, "head"); head != nil {
		for child in head.children {
			if child.name != "variable" {
				continue
			}
			if name, found := xml_attr(child, "name"); found {
				result_set_var(&rs, name)
			}
		}
	}

	if boolean := xml_child(root, "boolean"); boolean != nil {
		rs.kind = .Boolean
		rs.boolean = strings.trim_space(boolean.text) == "true"
		return rs, true
	}

	rs.kind = .Bindings
	results := xml_child(root, "results")
	if results == nil {
		// A results document with neither <results> nor <boolean> is an
		// empty solution sequence, which is a perfectly good answer.
		return rs, true
	}
	for result in results.children {
		if result.name != "result" {
			continue
		}
		row := result_set_add_row(&rs)
		for binding in result.children {
			if binding.name != "binding" {
				continue
			}
			name, has_name := xml_attr(binding, "name")
			if !has_name {
				continue
			}
			value_element := first_value_element(binding)
			if value_element == nil {
				continue
			}
			term, term_ok := srx_term(value_element)
			if !term_ok {
				result_set_destroy(&rs)
				return {}, false
			}
			result_set_bind(&rs, row, name, term)
			destroy_scratch_term(term)
		}
	}
	return rs, true
}

@(private = "file")
first_value_element :: proc(binding: ^Xml_Element) -> ^Xml_Element {
	for child in binding.children {
		switch child.name {
		case "uri", "bnode", "literal", "triple":
			return child
		}
	}
	return nil
}

// srx_term builds the term one value element denotes. The returned term
// borrows the XML tree's strings, except for a <triple>, whose node is
// freshly allocated — both are handed to result_set_bind, which clones,
// and then released with destroy_scratch_term.
@(private = "file")
srx_term :: proc(e: ^Xml_Element) -> (term: rdf.Term, ok: bool) {
	switch e.name {
	case "uri":
		return rdf.IRI(e.text), true
	case "bnode":
		return rdf.Blank_Node(e.text), true
	case "literal":
		if datatype, found := xml_attr(e, "datatype"); found {
			return rdf.literal_typed(e.text, rdf.IRI(datatype)), true
		}
		if language, found := xml_attr(e, "lang"); found {
			// SPARQL 1.2 writes a base direction as a second attribute
			// alongside the language tag.
			if dir, has_dir := xml_attr(e, "dir"); has_dir {
				switch dir {
				case "ltr":
					return rdf.literal_dir_lang(e.text, language, .LTR), true
				case "rtl":
					return rdf.literal_dir_lang(e.text, language, .RTL), true
				}
			}
			return rdf.literal_lang(e.text, language), true
		}
		return rdf.literal_plain(e.text), true
	case "triple":
		subject := xml_child(e, "subject")
		predicate := xml_child(e, "predicate")
		object := xml_child(e, "object")
		if subject == nil || predicate == nil || object == nil {
			return nil, false
		}
		t := new(rdf.Triple)
		s_ok, p_ok, o_ok: bool
		t.subject, s_ok = srx_component(subject)
		t.predicate, p_ok = srx_component(predicate)
		t.object, o_ok = srx_component(object)
		if !s_ok || !p_ok || !o_ok {
			destroy_scratch_term(t)
			return nil, false
		}
		return t, true
	}
	return nil, false
}

// srx_component reads one position of a <triple>, which wraps its value
// element the same way a <binding> does.
@(private = "file")
srx_component :: proc(position: ^Xml_Element) -> (term: rdf.Term, ok: bool) {
	value_element := first_value_element(position)
	if value_element == nil {
		return nil, false
	}
	return srx_term(value_element)
}

// destroy_scratch_term frees the triple nodes a reader allocated while
// building a term to hand to result_set_bind. Only the ^Triple spine is
// owned; every string in it belongs to the source document.
destroy_scratch_term :: proc(term: rdf.Term) {
	t, is_triple := term.(^rdf.Triple)
	if !is_triple || t == nil {
		return
	}
	destroy_scratch_term(t.subject)
	destroy_scratch_term(t.predicate)
	destroy_scratch_term(t.object)
	free(t)
}
