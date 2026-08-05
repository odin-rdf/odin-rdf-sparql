// RFC 3986 section 5 reference resolution for the query parser,
// mirrored from odin-rdf-parser's internal resolver (rdf/internal/iri)
// — internal packages cannot be imported across the collection
// boundary, so this package carries its own copy, kept semantically
// identical (SPARQL-T-0003).
//
// Resolution is lexical and byte-level: no percent-decoding, no case
// normalization. The resolved IRI is built in a caller-owned scratch
// buffer and interned, so steady-state resolution allocates only for
// IRIs the intern table has not seen.
package sparql

import rdf "rdf:rdf"

// Iri_Components is an IRI reference split per RFC 3986 appendix B.
// Slices borrow from the parsed string; the has_* flags distinguish an
// absent component from an empty one.
@(private)
Iri_Components :: struct {
	scheme:        string, // without the ':'
	authority:     string, // without the '//'
	path:          string,
	query:         string, // without the '?'
	fragment:      string, // without the '#'
	has_scheme:    bool,
	has_authority: bool,
	has_query:     bool,
	has_fragment:  bool,
}

// iri_parse splits an IRI reference into components. It cannot fail:
// every string is a syntactically valid reference under the appendix B
// grammar's totality (garbage lands in the path).
@(private)
iri_parse :: proc(s: string) -> (c: Iri_Components) {
	rest := s

	// Scheme: ALPHA (ALPHA | DIGIT | '+' | '-' | '.')* ':' before any
	// '/', '?', or '#'.
	scheme_scan: for i in 0 ..< len(rest) {
		switch ch := rest[i]; ch {
		case ':':
			if i > 0 {
				c.scheme = rest[:i]
				c.has_scheme = true
				rest = rest[i + 1:]
			}
			break scheme_scan
		case 'a' ..= 'z', 'A' ..= 'Z':
		// always allowed
		case '0' ..= '9', '+', '-', '.':
			if i == 0 {
				break scheme_scan
			}
		case:
			break scheme_scan
		}
	}

	if len(rest) >= 2 && rest[0] == '/' && rest[1] == '/' {
		rest = rest[2:]
		end := len(rest)
		for i in 0 ..< len(rest) {
			if ch := rest[i]; ch == '/' || ch == '?' || ch == '#' {
				end = i
				break
			}
		}
		c.authority = rest[:end]
		c.has_authority = true
		rest = rest[end:]
	}

	path_end := len(rest)
	for i in 0 ..< len(rest) {
		if ch := rest[i]; ch == '?' || ch == '#' {
			path_end = i
			break
		}
	}
	c.path = rest[:path_end]
	rest = rest[path_end:]

	if len(rest) > 0 && rest[0] == '?' {
		rest = rest[1:]
		end := len(rest)
		for i in 0 ..< len(rest) {
			if rest[i] == '#' {
				end = i
				break
			}
		}
		c.query = rest[:end]
		c.has_query = true
		rest = rest[end:]
	}

	if len(rest) > 0 && rest[0] == '#' {
		c.fragment = rest[1:]
		c.has_fragment = true
	}
	return
}

// Resolve_Scratch is caller-owned working memory for iri_resolve; its
// capacity is retained across calls, so steady-state resolution does
// not allocate.
@(private)
Resolve_Scratch :: struct {
	merged: [dynamic]byte, // the §5.2.3 merged path (input to dot removal)
	out:    [dynamic]byte, // the recomposed target IRI
}

@(private)
resolve_scratch_destroy :: proc(s: ^Resolve_Scratch) {
	delete(s.merged)
	delete(s.out)
	s^ = {}
}

// iri_resolve transforms reference ref against base per RFC 3986 §5.2.2
// (strict) and returns the target IRI interned in table. ok is false
// only when ref is relative and base has no scheme — the caller's
// no-base-established error case.
@(private)
iri_resolve :: proc(
	table: ^rdf.Intern_Table,
	base: string,
	ref: string,
	scratch: ^Resolve_Scratch,
) -> (result: string, ok: bool) {
	resolved := iri_resolve_build(base, ref, scratch) or_return
	return rdf.intern(table, resolved), true
}

// iri_resolve_build is iri_resolve without the interning: the target
// IRI is left in the scratch buffer and returned as a borrow of it,
// valid until the next call. Evaluation needs this — IRI() resolves a
// reference the query computed, and interning it would put a runtime
// value into the parser's table.
@(private)
iri_resolve_build :: proc(base: string, ref: string, scratch: ^Resolve_Scratch) -> (result: string, ok: bool) {
	r := iri_parse(ref)
	b := iri_parse(base)

	target: Iri_Components
	if r.has_scheme {
		target = r
	} else {
		if !b.has_scheme {
			return "", false
		}
		target.scheme = b.scheme
		target.has_scheme = true
		target.fragment = r.fragment
		target.has_fragment = r.has_fragment
		if r.has_authority {
			target.authority = r.authority
			target.has_authority = true
			target.path = r.path
			target.query = r.query
			target.has_query = r.has_query
		} else {
			target.authority = b.authority
			target.has_authority = b.has_authority
			if len(r.path) == 0 {
				target.path = b.path
				if r.has_query {
					target.query = r.query
					target.has_query = true
				} else {
					target.query = b.query
					target.has_query = b.has_query
				}
			} else {
				target.path = r.path // merged below when relative
				target.query = r.query
				target.has_query = r.has_query
			}
		}
	}

	// The dot-removal algorithm must see the whole merged path as one
	// input — running it over only the reference part would let leading
	// '..' segments strip without popping the base's segments.
	path_input := target.path
	if !r.has_scheme && !r.has_authority && len(r.path) > 0 && r.path[0] != '/' {
		// §5.2.3 merge: base path up to and including its last '/', or
		// just '/' when the base has an authority and an empty path.
		clear(&scratch.merged)
		if b.has_authority && len(b.path) == 0 {
			append(&scratch.merged, '/')
		} else if idx := last_slash(b.path); idx >= 0 {
			append(&scratch.merged, b.path[:idx + 1])
		}
		append(&scratch.merged, r.path)
		path_input = string(scratch.merged[:])
	}

	out := &scratch.out
	clear(out)
	append(out, target.scheme)
	append(out, ':')
	if target.has_authority {
		append(out, "//")
		append(out, target.authority)
	}
	remove_dot_segments(out, len(out), path_input)
	if target.has_query {
		append(out, '?')
		append(out, target.query)
	}
	if target.has_fragment {
		append(out, '#')
		append(out, target.fragment)
	}
	return string(out[:]), true
}

// remove_dot_segments appends input to out with '.' and '..' segments
// applied, per RFC 3986 §5.2.4. Content already in out from path_start
// on is part of the path (the merged base prefix) and may be popped by
// leading '..' segments. Transcribed literally from the RFC — the
// abnormal examples in §5.4.2 exist because optimized versions get the
// edge cases wrong.
@(private = "file")
remove_dot_segments :: proc(out: ^[dynamic]byte, path_start: int, input: string) {
	in_ := input
	for len(in_) > 0 {
		switch {
		case iri_prefix(in_, "../"):
			in_ = in_[3:]
		case iri_prefix(in_, "./"):
			in_ = in_[2:]
		case iri_prefix(in_, "/./"):
			in_ = in_[2:] // "/./x" -> "/x"
		case in_ == "/.":
			in_ = "/"
		case iri_prefix(in_, "/../"):
			in_ = in_[3:] // "/../x" -> "/x"
			pop_segment(out, path_start)
		case in_ == "/..":
			in_ = "/"
			pop_segment(out, path_start)
		case in_ == "." || in_ == "..":
			in_ = ""
		case:
			// Move the first segment (an optional leading '/' plus
			// everything up to the next '/') from input to output.
			end := len(in_)
			for i in 1 ..< len(in_) {
				if in_[i] == '/' {
					end = i
					break
				}
			}
			append(out, in_[:end])
			in_ = in_[end:]
		}
	}
}

// pop_segment removes the last path segment (and its leading '/') from
// out, never receding past path_start.
@(private = "file")
pop_segment :: proc(out: ^[dynamic]byte, path_start: int) {
	i := len(out) - 1
	for i >= path_start {
		if out[i] == '/' {
			break
		}
		i -= 1
	}
	if i < path_start {
		i = path_start
	}
	resize(out, i)
}

@(private = "file")
last_slash :: proc(s: string) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '/' {
			return i
		}
	}
	return -1
}

@(private = "file")
iri_prefix :: proc(s: string, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}
