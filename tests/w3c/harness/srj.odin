// Reader for the SPARQL 1.1 Query Results JSON Format (`.srj`), used by
// a handful of the vendored entries (sparql11-aggregates states two of
// its expectations this way).
//
// The document shape the specification fixes:
//
//	{ "head": { "vars": ["x"] },
//	  "results": { "bindings": [ { "x": {"type": "uri", "value": "…"} } ] } }
//
// with `"boolean": true|false` in place of `"results"` for an ASK
// answer. A binding value's "type" is "uri", "bnode", "literal", or the
// SPARQL 1.2 "triple", whose "value" is an object of subject/predicate/
// object. A literal carries an optional "datatype" or "xml:lang" (the
// key is spelled that way in the specification; "lang" is accepted too,
// as some writers emit it).
package w3c

import "core:encoding/json"

import rdf "rdf:rdf"

// read_srj parses an SRJ document into a Result_Set. The caller owns the
// result and frees it with result_set_destroy.
read_srj :: proc(source: []byte) -> (rs: Result_Set, ok: bool) {
	document, err := json.parse(source)
	if err != nil {
		return {}, false
	}
	defer json.destroy_value(document)

	root, is_object := document.(json.Object)
	if !is_object {
		return {}, false
	}

	if head, has_head := root["head"]; has_head {
		if head_object, head_is_object := head.(json.Object); head_is_object {
			if vars, has_vars := head_object["vars"]; has_vars {
				if list, is_array := vars.(json.Array); is_array {
					for entry in list {
						if name, is_string := entry.(json.String); is_string {
							result_set_var(&rs, string(name))
						}
					}
				}
			}
		}
	}

	if boolean, has_boolean := root["boolean"]; has_boolean {
		rs.kind = .Boolean
		value, is_boolean := boolean.(json.Boolean)
		if !is_boolean {
			result_set_destroy(&rs)
			return {}, false
		}
		rs.boolean = bool(value)
		return rs, true
	}

	rs.kind = .Bindings
	results, has_results := root["results"]
	if !has_results {
		return rs, true
	}
	results_object, results_is_object := results.(json.Object)
	if !results_is_object {
		result_set_destroy(&rs)
		return {}, false
	}
	bindings, has_bindings := results_object["bindings"]
	if !has_bindings {
		return rs, true
	}
	rows, rows_is_array := bindings.(json.Array)
	if !rows_is_array {
		result_set_destroy(&rs)
		return {}, false
	}
	for row_value in rows {
		row_object, row_is_object := row_value.(json.Object)
		if !row_is_object {
			result_set_destroy(&rs)
			return {}, false
		}
		row := result_set_add_row(&rs)
		for name, value in row_object {
			term, term_ok := srj_term(value)
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

// srj_term builds the term one binding-value object denotes; see
// destroy_scratch_term for what the caller owns afterwards.
@(private = "file")
srj_term :: proc(value: json.Value) -> (term: rdf.Term, ok: bool) {
	object, is_object := value.(json.Object)
	if !is_object {
		return nil, false
	}
	kind, has_kind := json_string(object, "type")
	if !has_kind {
		return nil, false
	}
	switch kind {
	case "uri":
		lexical := json_string(object, "value") or_return
		return rdf.IRI(lexical), true
	case "bnode":
		label := json_string(object, "value") or_return
		return rdf.Blank_Node(label), true
	case "literal":
		lexical := json_string(object, "value") or_return
		if datatype, found := json_string(object, "datatype"); found {
			return rdf.literal_typed(lexical, rdf.IRI(datatype)), true
		}
		language, has_language := json_string(object, "xml:lang")
		if !has_language {
			language, has_language = json_string(object, "lang")
		}
		if has_language {
			return rdf.literal_lang(lexical, language), true
		}
		return rdf.literal_plain(lexical), true
	case "triple":
		components, has_components := object["value"]
		if !has_components {
			return nil, false
		}
		component_object, components_are_object := components.(json.Object)
		if !components_are_object {
			return nil, false
		}
		t := new(rdf.Triple)
		s_ok, p_ok, o_ok: bool
		t.subject, s_ok = srj_component(component_object, "subject")
		t.predicate, p_ok = srj_component(component_object, "predicate")
		t.object, o_ok = srj_component(component_object, "object")
		if !s_ok || !p_ok || !o_ok {
			destroy_scratch_term(t)
			return nil, false
		}
		return t, true
	}
	return nil, false
}

@(private = "file")
srj_component :: proc(object: json.Object, key: string) -> (term: rdf.Term, ok: bool) {
	value, found := object[key]
	if !found {
		return nil, false
	}
	return srj_term(value)
}

@(private = "file")
json_string :: proc(object: json.Object, key: string) -> (value: string, ok: bool) {
	entry, found := object[key]
	if !found {
		return "", false
	}
	text, is_string := entry.(json.String)
	if !is_string {
		return "", false
	}
	return string(text), true
}
