package sparql

import "core:testing"

// The regex tests are written from two sources: the XPath/XSD
// definition of each construct, and the exact patterns and subjects the
// vendored DAWG regex directory uses. The second set is the one that
// matters most — this engine exists because those patterns are what a
// general-purpose engine got wrong (see regex.odin's header).

@(private = "file")
matches :: proc(t: ^testing.T, pattern, flags, subject: string, want: bool, loc := #caller_location) {
	parsed, flags_ok := regex_parse_flags(flags)
	if !testing.expectf(t, flags_ok, "flags %q rejected", flags, loc = loc) {
		return
	}
	rx, compiled := regex_compile(pattern, parsed)
	if !testing.expectf(t, compiled, "pattern %q did not compile", pattern, loc = loc) {
		return
	}
	defer regex_destroy(&rx)
	got, ok := regex_matches(&rx, subject)
	testing.expectf(t, ok, "pattern %q ran out of budget on %q", pattern, subject, loc = loc)
	testing.expectf(
		t,
		got == want,
		"regex(%q, %q, %q) = %v, want %v",
		subject,
		pattern,
		flags,
		got,
		want,
		loc = loc,
	)
}

@(private = "file")
replaces :: proc(t: ^testing.T, subject, pattern, replacement, flags, want: string, loc := #caller_location) {
	parsed, flags_ok := regex_parse_flags(flags)
	if !testing.expectf(t, flags_ok, "flags %q rejected", flags, loc = loc) {
		return
	}
	rx, compiled := regex_compile(pattern, parsed)
	if !testing.expectf(t, compiled, "pattern %q did not compile", pattern, loc = loc) {
		return
	}
	defer regex_destroy(&rx)
	got, ok := regex_replace(&rx, subject, replacement)
	defer delete(got)
	testing.expectf(t, ok, "replace(%q, %q) failed", subject, pattern, loc = loc)
	testing.expectf(
		t,
		got == want,
		"replace(%q, %q, %q, %q) = %q, want %q",
		subject,
		pattern,
		replacement,
		flags,
		got,
		want,
		loc = loc,
	)
}

// The subjects the DAWG's regex-data-quantifiers.ttl holds, which every
// test in that directory is run against.
@(private = "file")
QUANTIFIER_DATA :: [?]string{"ac", "abc", "abbc", "abbbc", "a\nc", "a\nb\nc", "a.c", "ABC", "a?+*.{}()[]c", "b"}

// suite_selection runs a pattern over that data set and asserts exactly
// which subjects come back — the same assertion the .srx expectations
// make, expressed as a set of indices into QUANTIFIER_DATA.
@(private = "file")
suite_selection :: proc(t: ^testing.T, pattern, flags: string, want: []int, loc := #caller_location) {
	for subject, i in QUANTIFIER_DATA {
		expected := false
		for w in want {
			if w == i {
				expected = true
			}
		}
		matches(t, pattern, flags, subject, expected, loc = loc)
	}
}

@(test)
test_regex_dawg_quantifiers :: proc(t: ^testing.T) {
	suite_selection(t, "ab?c", "", {0, 1})
	suite_selection(t, "ab*c", "", {0, 1, 2, 3})
	suite_selection(t, "ab+c", "", {1, 2, 3})
	suite_selection(t, "ab{2}c", "", {2})
	suite_selection(t, "ab{1,}c", "", {1, 2, 3})
	suite_selection(t, "ab{1,2}c", "", {1, 2})
}

// The dot tests are the reason this engine does not sit on a
// general-purpose one: without the s flag, '.' must not cross a
// newline, so "a\nc" is excluded and "abc"/"a.c" are not.
@(test)
test_regex_dawg_dot :: proc(t: ^testing.T) {
	suite_selection(t, "a.c", "", {1, 6})
	suite_selection(t, "a.c", "s", {1, 4, 6})
}

@(test)
test_regex_dawg_anchors :: proc(t: ^testing.T) {
	suite_selection(t, "^b$", "", {9})
	// And the other reason: under m, '^' must match after a newline, so
	// "a\nb\nc" comes back too.
	suite_selection(t, "^b$", "m", {5, 9})
}

@(test)
test_regex_dawg_classes :: proc(t: ^testing.T) {
	suite_selection(t, "a[b\\n]c", "", {1, 4})
	suite_selection(t, "a[^b]c", "", {4, 6})
}

@(test)
test_regex_dawg_flags :: proc(t: ^testing.T) {
	suite_selection(t, "abc", "i", {1, 7})
	// The q flag: every character literal, so only the subject that is
	// the pattern spelled out matches.
	suite_selection(t, "a?+*.{}()[]c", "q", {8})
	suite_selection(t, "a?+*.{}()[]C", "iq", {8})
	// x drops unescaped whitespace outside a class...
	suite_selection(t, " a\n\tc ", "x", {0})
	// ...but not inside one, so [\n] still matches a newline.
	suite_selection(t, " a\n\r\t[\\n]c ", "x", {4})
}

// The four original DAWG regex tests, over regex-data-01.ttl.
@(test)
test_regex_dawg_original :: proc(t: ^testing.T) {
	matches(t, "GHI", "", "ABCdefGHIjkl", true)
	matches(t, "GHI", "", "abcDEFghiJKL", false)
	matches(t, "DeFghI", "i", "abcDEFghiJKL", true)
	matches(t, "example\\.com", "", "http://example.com/literal", true)
	matches(t, "example\\.com", "", "abcDEFghiJKL", false)
}

@(test)
test_regex_replace_suite :: proc(t: ^testing.T) {
	// replace01: everything outside [a-z0-9] becomes '-'.
	replaces(t, "123", "[^a-z0-9]", "-", "", "123")
	replaces(t, "日本語", "[^a-z0-9]", "-", "", "---")
	replaces(t, "English", "[^a-z0-9]", "-", "", "-nglish")
	replaces(t, "Français", "[^a-z0-9]", "-", "", "-ran-ais")
	// replace02: overlapping candidates resolve leftmost, then resume
	// after the match — "banana" has one "ana", not two.
	replaces(t, "banana", "ana", "*", "", "b*na")
	// replace03: a group that did not participate contributes nothing.
	// This is the case a capture-compacting engine cannot express.
	replaces(t, "abcd", "(ab)|(a)", "[1=$1][2=$2]", "", "[1=ab][2=]cd")
	// replace-case-insensitive.
	replaces(t, "aAbBaC", "a", "~/", "i", "~/~/bB~/C")
}

@(test)
test_regex_uuid_pattern :: proc(t: ^testing.T) {
	// The pattern uuid01 and struuid01 filter with.
	P :: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
	matches(t, P, "i", "1b4e28ba-2fa1-11d2-883f-0016d3cca427", true)
	matches(t, P, "i", "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", true)
	matches(t, P, "", "1b4e28ba-2fa1-11d2-883f-0016d3cca427", false)
	matches(t, P, "i", "1b4e28ba-2fa1-11d2-883f-0016d3cca42", false)
	matches(t, "^urn:uuid:[0-9A-F]{8}", "i", "urn:uuid:1b4e28ba-", true)
}

// The constructs the flavour has that a suite pattern never reaches,
// tested from the XPath definition rather than from a .srx file.
@(test)
test_regex_flavour :: proc(t: ^testing.T) {
	// Alternation, grouping, nesting.
	matches(t, "(ab)+c", "", "ababc", true)
	matches(t, "(?:ab)+c", "", "ababc", true)
	matches(t, "a(b|c)d", "", "acd", true)
	matches(t, "a(b|c)d", "", "aed", false)

	// Back-references.
	matches(t, "(a+)\\1", "", "aaaa", true)
	matches(t, "(ab)\\1", "", "abab", true)
	matches(t, "(ab)\\1", "", "abcd", false)

	// Reluctant quantifiers change what is matched, not whether.
	replaces(t, "<a><b>", "<.+?>", "x", "", "xx")
	replaces(t, "<a><b>", "<.+>", "x", "", "x")

	// Character-class escapes.
	matches(t, "^\\d+$", "", "12345", true)
	matches(t, "^\\d+$", "", "12a45", false)
	matches(t, "^\\s$", "", "\t", true)
	matches(t, "^\\S+$", "", "abc", true)
	matches(t, "\\p{L}", "", "123a", true)
	matches(t, "^\\p{Lu}+$", "", "ABC", true)
	matches(t, "^\\p{Lu}+$", "", "AbC", false)

	// XSD class subtraction: a-z without the vowels.
	matches(t, "^[a-z-[aeiou]]+$", "", "bcdfg", true)
	matches(t, "^[a-z-[aeiou]]+$", "", "bcadfg", false)

	// A class whose first character is ']' is a literal ']'.
	matches(t, "^[]]$", "", "]", true)

	// Anchors without the m flag are the whole string, so a trailing
	// newline is not a line boundary.
	matches(t, "^abc$", "", "abc\n", false)
	matches(t, "^abc$", "m", "abc\n", true)

	// An empty-matching body under a star must terminate rather than
	// loop (the Mark/Progress guard).
	matches(t, "^(a?)*$", "", "aaa", true)
	matches(t, "^(a?)*b$", "", "aaa", false)
}

@(test)
test_regex_rejects_bad_patterns :: proc(t: ^testing.T) {
	for pattern in ([?]string{"(", ")", "[a", "a{2,1}", "*a", "a\\", "\\q", "\\p{Nope}", "a**"}) {
		rx, ok := regex_compile(pattern, {})
		if ok {
			regex_destroy(&rx)
		}
		testing.expectf(t, !ok, "pattern %q should not compile", pattern)
	}
	_, flags_ok := regex_parse_flags("z")
	testing.expect(t, !flags_ok, "flag 'z' should be rejected")
}

// A replacement string may only escape '$' and '\'; anything else is an
// error rather than a literal, so a typo is reported and not silently
// rewritten.
@(test)
test_regex_replacement_escapes :: proc(t: ^testing.T) {
	replaces(t, "abc", "b", "\\$", "", "a$c")
	replaces(t, "abc", "b", "\\\\", "", "a\\c")
	replaces(t, "abc", "(b)", "[$1]", "", "a[b]c")

	rx, compiled := regex_compile("b", {})
	testing.expect(t, compiled)
	defer regex_destroy(&rx)
	bad, ok := regex_replace(&rx, "abc", "\\n")
	delete(bad)
	testing.expect(t, !ok, "an unescapable backslash in the replacement must fail")
}
