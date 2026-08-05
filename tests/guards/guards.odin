// Package guards holds allocation-guard tests: tracking-allocator
// assertions that the tokenizer and parser honor the family's zero-copy
// promise (tokens and terms borrow the caller-owned source; the parser
// owns derived allocations until parser_destroy). The pattern comes
// from odin-rdf-parser's tests/guards. Populated from SPARQL-T-0002 on;
// the package exists now so the Makefile's pinned package list is real
// from the first commit.
package guards
