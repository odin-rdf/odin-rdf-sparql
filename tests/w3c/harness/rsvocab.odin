// Readers for the DAWG result-set vocabulary — an answer expressed as
// an RDF graph rather than as a results document.
//
//	[] rdf:type rs:ResultSet ;
//	   rs:resultVariable "x" ;
//	   rs:solution [ rs:index 1 ;
//	                 rs:binding [ rs:variable "x" ; rs:value :a ] ] .
//
// The sparql10 suites state most of their expectations this way, in
// Turtle (`.ttl`) and — in sparql10-sort alone — in RDF/XML (`.rdf`).
// The Turtle side goes through the family's parser like everything
// else. The RDF/XML side does not: RDF/XML is not one of the four
// formats odin-rdf-parser implements, and adding a general reader for
// it to run ten sort tests would be the wrong trade. Instead the ten
// files are read structurally through the harness's XML subset, against
// the exact shape those files use (striped elements with
// rdf:parseType="Resource"). That reader is not an RDF/XML parser and
// is not offered as one; a file outside the shape fails to read rather
// than being misread.
//
// A `.ttl` expectation that carries no rs:ResultSet is a plain RDF
// graph: the expected output of a CONSTRUCT or DESCRIBE query. Both
// land in the same Result_Set type, distinguished by kind.
package w3c

import "core:strconv"
import "core:strings"

import rdf "rdf:rdf"

RS_NS :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#"
RS_RESULT_SET :: rdf.IRI(RS_NS + "ResultSet")
RS_RESULT_VARIABLE :: rdf.IRI(RS_NS + "resultVariable")
RS_SOLUTION :: rdf.IRI(RS_NS + "solution")
RS_BINDING :: rdf.IRI(RS_NS + "binding")
RS_VARIABLE :: rdf.IRI(RS_NS + "variable")
RS_VALUE :: rdf.IRI(RS_NS + "value")
RS_INDEX :: rdf.IRI(RS_NS + "index")
RS_BOOLEAN :: rdf.IRI(RS_NS + "boolean")

// read_result_turtle reads a Turtle expectation: a result set in the
// vocabulary above, or — when the graph has no rs:ResultSet — the graph
// itself, as a CONSTRUCT or DESCRIBE expectation. base resolves the
// document's relative IRIs and must be the test file's own IRI.
read_result_turtle :: proc(source: string, base: string) -> (rs: Result_Set, ok: bool) {
	g, parse_ok := graph_from_turtle(source, base)
	defer graph_destroy(&g)
	if !parse_ok {
		return {}, false
	}

	set_node := graph_subject_of_type(&g, RS_RESULT_SET)
	if set_node == nil {
		rs.kind = .Graph
		for t in g.statements {
			result_set_add_triple(&rs, t)
		}
		return rs, true
	}

	if boolean := graph_object(&g, set_node, RS_BOOLEAN); boolean != nil {
		rs.kind = .Boolean
		if lit, is_literal := boolean.(rdf.Literal); is_literal {
			rs.boolean = lit.lexical == "true"
		}
		return rs, true
	}

	rs.kind = .Bindings
	variables := graph_objects(&g, set_node, RS_RESULT_VARIABLE)
	defer delete(variables)
	for v in variables {
		if lit, is_literal := v.(rdf.Literal); is_literal {
			result_set_var(&rs, lit.lexical)
		}
	}

	solutions := graph_objects(&g, set_node, RS_SOLUTION)
	defer delete(solutions)
	indexed := 0
	for solution in solutions {
		row := result_set_add_row(&rs)
		bindings := graph_objects(&g, solution, RS_BINDING)
		defer delete(bindings)
		for binding in bindings {
			name := graph_object(&g, binding, RS_VARIABLE)
			value := graph_object(&g, binding, RS_VALUE)
			lit, is_literal := name.(rdf.Literal)
			if !is_literal || value == nil {
				continue
			}
			result_set_bind(&rs, row, lit.lexical, value)
		}
		index := 0
		if index_term := graph_object(&g, solution, RS_INDEX); index_term != nil {
			if index_lit, index_is_literal := index_term.(rdf.Literal); index_is_literal {
				if parsed, parse_index_ok := strconv.parse_int(index_lit.lexical); parse_index_ok {
					index = parsed
					indexed += 1
				}
			}
		}
		append(&rs.order_index, index)
	}
	if indexed != len(rs.rows) {
		// Only a fully indexed result states an order; drop a partial
		// one rather than sorting on zeros.
		clear(&rs.order_index)
	}
	result_set_sort_by_index(&rs)
	return rs, true
}

// read_result_rdfxml reads the result-set vocabulary out of the striped
// RDF/XML the sparql10-sort expectations use. See the package note on
// why this is a shape reader and not an RDF/XML parser.
read_result_rdfxml :: proc(source: string) -> (rs: Result_Set, ok: bool) {
	root, xml_ok := xml_parse(source)
	if !xml_ok {
		return {}, false
	}
	defer xml_destroy(root)

	set_element := find_element(root, "ResultSet")
	if set_element == nil {
		return {}, false
	}

	if boolean := xml_child(set_element, "boolean"); boolean != nil {
		rs.kind = .Boolean
		rs.boolean = strings.trim_space(boolean.text) == "true"
		return rs, true
	}

	rs.kind = .Bindings
	indexed := 0
	for child in set_element.children {
		switch child.name {
		case "resultVariable":
			result_set_var(&rs, strings.trim_space(child.text))
		case "solution":
			row := result_set_add_row(&rs)
			index := 0
			for member in child.children {
				switch member.name {
				case "index":
					if parsed, parse_ok := strconv.parse_int(strings.trim_space(member.text)); parse_ok {
						index = parsed
						indexed += 1
					}
				case "binding":
					name_element := xml_child(member, "variable")
					value_element := xml_child(member, "value")
					if name_element == nil || value_element == nil {
						continue
					}
					result_set_bind(&rs, row, strings.trim_space(name_element.text), rdfxml_value(value_element))
				}
			}
			append(&rs.order_index, index)
		}
	}
	if indexed != len(rs.rows) {
		clear(&rs.order_index)
	}
	result_set_sort_by_index(&rs)
	return rs, true
}

// rdfxml_value reads one rs:value element. An IRI or blank node is
// carried by an attribute and the element is empty; a literal is the
// element's text, typed by rdf:datatype or tagged by xml:lang.
@(private = "file")
rdfxml_value :: proc(e: ^Xml_Element) -> rdf.Term {
	if resource, found := xml_attr(e, "resource"); found {
		return rdf.IRI(resource)
	}
	if node_id, found := xml_attr(e, "nodeID"); found {
		return rdf.Blank_Node(node_id)
	}
	if datatype, found := xml_attr(e, "datatype"); found {
		return rdf.literal_typed(e.text, rdf.IRI(datatype))
	}
	if language, found := xml_attr(e, "lang"); found {
		return rdf.literal_lang(e.text, language)
	}
	return rdf.literal_plain(e.text)
}

@(private = "file")
find_element :: proc(e: ^Xml_Element, name: string) -> ^Xml_Element {
	if e.name == name {
		return e
	}
	for child in e.children {
		if found := find_element(child, name); found != nil {
			return found
		}
	}
	return nil
}
