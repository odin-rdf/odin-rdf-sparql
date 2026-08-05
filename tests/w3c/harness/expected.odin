// Dispatch from an expected-result file to the reader for its format.
//
// A manifest names its expectation by file, and the extension is what
// tells the formats apart — the suites use `.srx` and `.srj` for results
// documents, `.ttl` for the result-set vocabulary or a CONSTRUCT graph,
// and `.rdf` for the result-set vocabulary in RDF/XML. `.csv` and `.tsv`
// belong to the result-serialization suites, which the engine's vision
// puts out of scope and this repo does not vendor; naming them here
// keeps an accidental reference a loud failure rather than a silent
// pass.
package w3c

import "core:os"
import "core:strings"

// read_expected reads the expectation at path. base is the file's own
// absolute IRI, used to resolve relative IRIs in the Turtle forms. ok is
// false when the file cannot be read or its format is not one the
// harness handles; the caller owns the result and frees it with
// result_set_destroy.
read_expected :: proc(path: string, base: string) -> (rs: Result_Set, ok: bool) {
	content, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(content)

	switch {
	case strings.has_suffix(path, ".srx"):
		return read_srx(string(content))
	case strings.has_suffix(path, ".srj"):
		return read_srj(content)
	case strings.has_suffix(path, ".ttl"):
		return read_result_turtle(string(content), base)
	case strings.has_suffix(path, ".rdf"):
		return read_result_rdfxml(string(content))
	}
	return {}, false
}
