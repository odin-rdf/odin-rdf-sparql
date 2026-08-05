// The regular-expression flavour REGEX and REPLACE are defined against
// (SPARQL-T-0014).
//
// SPARQL does not define a regex flavour of its own: §17.4.3.14 says
// REGEX is XPath's `fn:matches` and §17.4.3.15 says REPLACE is
// `fn:replace`, both of which are the XML Schema regular expression
// language plus XPath's additions — reluctant quantifiers,
// back-references, and the `^`/`$` anchors. That is a *specific*
// flavour, and the places it differs from the Perl-descended one are
// exactly the places the DAWG wrote tests.
//
// **Why this is not `core:text/regex`.** It was measured first, against
// every pattern the vendored suites use. Four differences, two of which
// cannot be reached from outside the library:
//
//   - `.` matches `\n` there and must not here (XSD: any character
//     except #x0A and #x0D unless the `s` flag is set). Reachable by
//     rewriting the pattern, but there is also no dot-all flag to turn
//     the behaviour back *on* for `s`.
//   - The `q` flag — the whole pattern taken literally — does not exist.
//     Reachable by escaping.
//   - `^` under the `m` flag never matches after a newline. Its
//     `Assert_Start_Multiline` opcode compares a string pointer measured
//     one rune ahead against a `last_rune` recorded one rune behind, so
//     the two never line up. `regex-start-end-multiline` requires
//     `^b$` to match "a\nb\nc". Not reachable: the flavour has no
//     lookbehind to express it with.
//   - Both capture APIs drop unmatched groups and compact the array, so
//     an unmatched group vanishes rather than reporting empty. REPLACE's
//     `$N` needs stable slots — `replace03` asks for `[1=ab][2=]cd`
//     from `REPLACE("abcd","(ab)|(a)","[1=$1][2=$2]")`. Not reachable.
//
// **This is not meant to be permanent.** Two of the four are plain
// upstream bugs rather than flavour differences, and both look
// fixable in `core:text/regex` itself:
//
//   - the multiline anchor is an off-by-one — compare the string
//     pointer and `last_rune` at the same position and the opcode is
//     already correct;
//   - the capture compaction is a deliberate choice in
//     `match_and_allocate_capture` and `match_with_preallocated_capture`
//     that discards information no caller can recover; a variant that
//     keeps `-1` slots would serve `fn:replace` and cost nothing.
//
// Worth revisiting: file both upstream, and if they land, re-measure
// whether the remaining flavour gaps (dot-all, the `q` flag, `\p{...}`,
// back-references) are small enough to reach by rewriting patterns and
// building on `core:text/regex` after all. Until then this file is what
// lets the regex directory be held to the same green-or-nothing rule as
// every other suite. Deleting it later is a good outcome, not a loss.
//
// So the flavour is implemented directly. It is a backtracking
// bytecode VM in the style of Thompson's construction with Cox's
// recursive backtracking matcher: `regex_compile` parses the pattern
// straight to a program (no AST — a quantifier copies the code its atom
// just emitted, rebasing absolute jump targets), and `rx_run` walks it.
// Recursion depth is bounded by the step budget, and a budget overrun is
// reported rather than silently answered "no match": a query whose
// REGEX gave up must raise a type error, not quietly drop rows.
//
// Matching is over runes, not bytes, because every length and offset
// SPARQL exposes is in codepoints.
package sparql

import "base:runtime"

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Regex_Flag is one of the five flags §17.4.3.14 admits. XPath also
// defines them; SPARQL adds nothing and removes nothing.
Regex_Flag :: enum {
	Case_Insensitive, // i
	Dot_All, // s: '.' also matches newline
	Multiline, // m: '^' and '$' match at line boundaries
	Ignore_Whitespace, // x: unescaped whitespace outside a class is dropped
	Literal, // q: the pattern has no metacharacters at all
}

Regex_Flags :: bit_set[Regex_Flag]

// regex_parse_flags reads the flags string. ok is false for a letter
// the flavour does not define, which REGEX turns into a type error.
regex_parse_flags :: proc(s: string) -> (flags: Regex_Flags, ok: bool) {
	for c in s {
		switch c {
		case 'i':
			flags += {.Case_Insensitive}
		case 's':
			flags += {.Dot_All}
		case 'm':
			flags += {.Multiline}
		case 'x':
			flags += {.Ignore_Whitespace}
		case 'q':
			flags += {.Literal}
		case:
			return {}, false
		}
	}
	return flags, true
}

// Rx_Op is the instruction set. Char/Class/Any consume a rune; Split
// and Jump are control flow; Save records a capture boundary; Mark and
// Progress are the empty-loop guard (see rx_emit_repeat).
@(private = "file")
Rx_Op :: enum u8 {
	Char,
	Class,
	Any,
	Split,
	Jump,
	Save,
	Mark,
	Progress,
	Backref,
	Assert_Start,
	Assert_End,
	Match,
}

@(private = "file")
Rx_Inst :: struct {
	op:   Rx_Op,
	r:    rune, // Char
	a, b: int, // Split, Jump: absolute program offsets
	n:    int, // Class index, Save/Mark slot, Backref group
}

@(private = "file")
Rx_Range :: struct {
	lo, hi: rune,
}

// Rx_Shorthand is a character-class escape that names a Unicode
// property rather than a range: `\d`, `\s`, `\w`, `\i`, `\c`, and the
// `\p{...}` categories. Kept as a predicate rather than expanded to
// ranges because the tables are already in core:unicode.
@(private = "file")
Rx_Shorthand :: enum u8 {
	Digit,
	Not_Digit,
	Space,
	Not_Space,
	Word,
	Not_Word,
	Name_Start,
	Not_Name_Start,
	Name_Char,
	Not_Name_Char,
	Letter, // \p{L}
	Upper, // \p{Lu}
	Lower, // \p{Ll}
	Number, // \p{N}
	Decimal, // \p{Nd}
	Punctuation, // \p{P}
	Separator, // \p{Z}
	Symbol, // \p{S}
	Mark, // \p{M}
	Other, // \p{C}
}

// Rx_Class is one character class. subtract is XSD's class subtraction
// (`[a-z-[aeiou]]`) and is an index into the same table, or -1.
//
// The order the three parts combine in is not the obvious one: the
// subtraction applies to the *positive* set, and negation applies to
// the result. So `[^a-z-[aeiou]]` is the complement of "a to z except
// the vowels", not "not a-z" minus the vowels.
@(private = "file")
Rx_Class :: struct {
	negated:    bool,
	ranges:     [dynamic]Rx_Range,
	shorthands: [dynamic]Rx_Shorthand,
	subtract:   int,
}

// Regex is a compiled pattern. It owns its program and class table and
// is released with regex_destroy.
Regex :: struct {
	prog:      [dynamic]Rx_Inst,
	classes:   [dynamic]Rx_Class,
	groups:    int, // capturing groups, numbered 1..groups
	marks:     int, // empty-loop guard slots
	flags:     Regex_Flags,
	allocator: runtime.Allocator,
}

// REGEX_STEP_BUDGET bounds the backtracking search. A pathological
// pattern over a long string is the one way this engine can fail to
// answer, and the budget is what turns "runs forever" into "raises a
// type error" — the behaviour §17.2's error propagation already has a
// place for.
REGEX_STEP_BUDGET :: 4_000_000

regex_destroy :: proc(rx: ^Regex) {
	for &class in rx.classes {
		delete(class.ranges)
		delete(class.shorthands)
	}
	delete(rx.classes)
	delete(rx.prog)
	rx^ = {}
}

// Rx_Parser is the compile-time state: the pattern as runes, a cursor,
// and the program being emitted.
@(private = "file")
Rx_Parser :: struct {
	pat:   []rune,
	at:    int,
	rx:    ^Regex,
	ok:    bool,
	depth: int,
}

// RX_MAX_DEPTH bounds group nesting, so a hostile pattern cannot
// exhaust the stack during *parsing* either.
@(private = "file")
RX_MAX_DEPTH :: 64

// regex_compile turns a pattern into a program. ok is false for a
// pattern the flavour does not accept, which REGEX and REPLACE turn
// into a type error (§17.4.3.14: "an error is raised if the pattern is
// invalid").
regex_compile :: proc(pattern: string, flags: Regex_Flags, allocator := context.allocator) -> (rx: Regex, ok: bool) {
	rx.allocator = allocator
	rx.flags = flags
	rx.prog = make([dynamic]Rx_Inst, allocator)
	rx.classes = make([dynamic]Rx_Class, allocator)

	runes := utf8.string_to_runes(pattern, context.temp_allocator)
	defer delete(runes, context.temp_allocator)

	if .Literal in flags {
		// The `q` flag: no metacharacters, so there is nothing to parse.
		for r in runes {
			append(&rx.prog, Rx_Inst{op = .Char, r = r})
		}
		append(&rx.prog, Rx_Inst{op = .Match})
		return rx, true
	}

	p := Rx_Parser {
		pat = runes,
		rx  = &rx,
		ok  = true,
	}
	rx_parse_alt(&p)
	if !p.ok || p.at != len(p.pat) {
		// A leftover ')' is the usual way to land here.
		regex_destroy(&rx)
		return {}, false
	}
	append(&rx.prog, Rx_Inst{op = .Match})
	return rx, true
}

// rx_parse_alt parses `branch ('|' branch)*`, emitting a chain of
// Splits with every branch's exit jumping to one shared end.
@(private = "file")
rx_parse_alt :: proc(p: ^Rx_Parser) {
	if p.depth >= RX_MAX_DEPTH {
		p.ok = false
		return
	}
	p.depth += 1
	defer p.depth -= 1

	jumps := make([dynamic]int, 0, 4, context.temp_allocator)
	for {
		split := -1
		if rx_more_branches(p) {
			split = len(p.rx.prog)
			append(&p.rx.prog, Rx_Inst{op = .Split})
		}
		rx_parse_branch(p)
		if !p.ok {
			return
		}
		if split < 0 {
			break
		}
		append(&jumps, len(p.rx.prog))
		append(&p.rx.prog, Rx_Inst{op = .Jump})
		p.rx.prog[split].a = split + 1
		p.rx.prog[split].b = len(p.rx.prog)
		p.at += 1 // the '|'
	}
	end := len(p.rx.prog)
	for j in jumps {
		p.rx.prog[j].a = end
	}
}

// rx_more_branches reports whether a '|' follows the branch about to be
// parsed, which is what decides whether it needs a Split in front of
// it. Scanning ahead is cheaper than emitting a Split unconditionally
// and patching it out.
@(private = "file")
rx_more_branches :: proc(p: ^Rx_Parser) -> bool {
	depth := 0
	for i := p.at; i < len(p.pat); i += 1 {
		switch p.pat[i] {
		case '\\':
			i += 1
		case '[':
			// Skip the class: a '|' inside one is an ordinary character.
			i += 1
			if i < len(p.pat) && p.pat[i] == '^' {
				i += 1
			}
			if i < len(p.pat) && p.pat[i] == ']' {
				i += 1
			}
			for i < len(p.pat) && p.pat[i] != ']' {
				if p.pat[i] == '\\' {
					i += 1
				}
				i += 1
			}
		case '(':
			depth += 1
		case ')':
			if depth == 0 {
				return false
			}
			depth -= 1
		case '|':
			if depth == 0 {
				return true
			}
		}
	}
	return false
}

@(private = "file")
rx_parse_branch :: proc(p: ^Rx_Parser) {
	for p.ok && p.at < len(p.pat) {
		c := p.pat[p.at]
		if c == '|' || c == ')' {
			return
		}
		rx_parse_piece(p)
	}
}

// rx_parse_piece is `atom quantifier?`. The atom emits its own code
// first; a quantifier then lifts that code back out and re-emits it as
// many times as the repetition needs. Absolute jump targets make the
// copy a rebase rather than a re-parse.
@(private = "file")
rx_parse_piece :: proc(p: ^Rx_Parser) {
	start := len(p.rx.prog)
	rx_parse_atom(p)
	if !p.ok {
		return
	}
	min_count, max_count, greedy, quantified := rx_parse_quantifier(p)
	if !p.ok || !quantified {
		return
	}
	// An anchor is a zero-width assertion; repeating one is meaningless
	// and, with the empty-loop guard, would never terminate usefully.
	// XSD does not permit it either.
	if len(p.rx.prog) == start {
		p.ok = false
		return
	}

	body := make([dynamic]Rx_Inst, 0, len(p.rx.prog) - start, context.temp_allocator)
	append(&body, ..p.rx.prog[start:])
	resize(&p.rx.prog, start)
	rx_emit_repeat(p, body[:], start, min_count, max_count, greedy)
}

// rx_place appends a copy of a body, rebasing its absolute targets.
// origin is where the body used to start.
@(private = "file")
rx_place :: proc(p: ^Rx_Parser, body: []Rx_Inst, origin: int) {
	shift := len(p.rx.prog) - origin
	for inst in body {
		copy_inst := inst
		#partial switch inst.op {
		case .Split:
			copy_inst.a += shift
			copy_inst.b += shift
		case .Jump:
			copy_inst.a += shift
		}
		append(&p.rx.prog, copy_inst)
	}
}

// rx_emit_repeat writes `body{min,max}`. max < 0 is unbounded.
//
// The unbounded form carries a Mark/Progress pair around its body: a
// body that can match the empty string — `(a?)*` — would otherwise loop
// forever, and the guard turns "matched nothing" into a failed
// iteration. The bounded form needs no guard because it cannot iterate
// more than max times.
@(private = "file")
rx_emit_repeat :: proc(p: ^Rx_Parser, body: []Rx_Inst, origin: int, min_count, max_count: int, greedy: bool) {
	for _ in 0 ..< min_count {
		rx_place(p, body, origin)
	}

	if max_count < 0 {
		mark := p.rx.marks
		p.rx.marks += 1
		loop := len(p.rx.prog)
		append(&p.rx.prog, Rx_Inst{op = .Split})
		append(&p.rx.prog, Rx_Inst{op = .Mark, n = mark})
		rx_place(p, body, origin)
		append(&p.rx.prog, Rx_Inst{op = .Progress, n = mark})
		append(&p.rx.prog, Rx_Inst{op = .Jump, a = loop})
		end := len(p.rx.prog)
		rx_set_split(p, loop, loop + 1, end, greedy)
		return
	}

	splits := make([dynamic]int, 0, 4, context.temp_allocator)
	for _ in 0 ..< max_count - min_count {
		s := len(p.rx.prog)
		append(&p.rx.prog, Rx_Inst{op = .Split})
		rx_place(p, body, origin)
		append(&splits, s)
	}
	end := len(p.rx.prog)
	for s in splits {
		rx_set_split(p, s, s + 1, end, greedy)
	}
}

// rx_set_split points a Split at "take the body" and "skip it" in the
// order the quantifier's greediness asks for: the VM always tries `a`
// before `b`, so greedy puts the body first and reluctant puts the exit
// first.
@(private = "file")
rx_set_split :: proc(p: ^Rx_Parser, at: int, body, exit: int, greedy: bool) {
	if greedy {
		p.rx.prog[at].a = body
		p.rx.prog[at].b = exit
	} else {
		p.rx.prog[at].a = exit
		p.rx.prog[at].b = body
	}
}

// rx_parse_quantifier reads `?`, `*`, `+`, or `{n,m}`, each optionally
// followed by `?` for the reluctant form.
@(private = "file")
rx_parse_quantifier :: proc(p: ^Rx_Parser) -> (min_count, max_count: int, greedy, present: bool) {
	if p.at >= len(p.pat) {
		return 0, 0, true, false
	}
	switch p.pat[p.at] {
	case '?':
		min_count, max_count = 0, 1
	case '*':
		min_count, max_count = 0, -1
	case '+':
		min_count, max_count = 1, -1
	case '{':
		return rx_parse_quantity(p)
	case:
		return 0, 0, true, false
	}
	p.at += 1
	greedy = rx_take_greedy(p)
	return min_count, max_count, greedy, true
}

// rx_parse_quantity reads `{n}`, `{n,}`, or `{n,m}`. A '{' that is not
// the start of a valid quantity is a literal brace, which is what the
// `regex-no-metacharacters` data ("a?+*.{}()[]c") relies on when it is
// *not* run under the q flag.
@(private = "file")
rx_parse_quantity :: proc(p: ^Rx_Parser) -> (min_count, max_count: int, greedy, present: bool) {
	save := p.at
	p.at += 1 // '{'
	lo, lo_ok := rx_parse_int(p)
	if !lo_ok {
		p.at = save
		return 0, 0, true, false
	}
	hi := lo
	if p.at < len(p.pat) && p.pat[p.at] == ',' {
		p.at += 1
		if p.at < len(p.pat) && p.pat[p.at] == '}' {
			hi = -1
		} else {
			bound, bound_ok := rx_parse_int(p)
			if !bound_ok {
				p.at = save
				return 0, 0, true, false
			}
			hi = bound
		}
	}
	if p.at >= len(p.pat) || p.pat[p.at] != '}' {
		p.at = save
		return 0, 0, true, false
	}
	p.at += 1
	if hi >= 0 && hi < lo {
		p.ok = false
		return 0, 0, true, false
	}
	greedy = rx_take_greedy(p)
	return lo, hi, greedy, true
}

@(private = "file")
rx_take_greedy :: proc(p: ^Rx_Parser) -> bool {
	if p.at < len(p.pat) && p.pat[p.at] == '?' {
		p.at += 1
		return false
	}
	return true
}

@(private = "file")
rx_parse_int :: proc(p: ^Rx_Parser) -> (n: int, ok: bool) {
	start := p.at
	for p.at < len(p.pat) && p.pat[p.at] >= '0' && p.pat[p.at] <= '9' {
		n = n * 10 + int(p.pat[p.at] - '0')
		if n > 1 << 20 {
			return 0, false
		}
		p.at += 1
	}
	return n, p.at > start
}

@(private = "file")
rx_parse_atom :: proc(p: ^Rx_Parser) {
	if .Ignore_Whitespace in p.rx.flags {
		// The `x` flag drops unescaped whitespace *outside* a class. It is
		// dropped here rather than in a pre-pass so that "[ ]" keeps its
		// space, which is what regex-ignore-whitespaces-class-expression
		// checks.
		for p.at < len(p.pat) && rx_is_pattern_space(p.pat[p.at]) {
			p.at += 1
		}
		if p.at >= len(p.pat) {
			return
		}
	}
	if p.at >= len(p.pat) {
		p.ok = false
		return
	}

	switch c := p.pat[p.at]; c {
	case '^':
		p.at += 1
		append(&p.rx.prog, Rx_Inst{op = .Assert_Start})
	case '$':
		p.at += 1
		append(&p.rx.prog, Rx_Inst{op = .Assert_End})
	case '.':
		p.at += 1
		append(&p.rx.prog, Rx_Inst{op = .Any})
	case '(':
		rx_parse_group(p)
	case '[':
		index, class_ok := rx_parse_class(p)
		if !class_ok {
			p.ok = false
			return
		}
		append(&p.rx.prog, Rx_Inst{op = .Class, n = index})
	case '\\':
		rx_parse_escape_atom(p)
	case ')', '|':
		p.ok = false
	case '*', '+', '?':
		// A quantifier with nothing to quantify.
		p.ok = false
	case:
		p.at += 1
		append(&p.rx.prog, Rx_Inst{op = .Char, r = c})
	}
}

@(private = "file")
rx_is_pattern_space :: proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r'
}

@(private = "file")
rx_parse_group :: proc(p: ^Rx_Parser) {
	p.at += 1 // '('
	capturing := true
	if p.at + 1 < len(p.pat) && p.pat[p.at] == '?' && p.pat[p.at + 1] == ':' {
		capturing = false
		p.at += 2
	}
	index := 0
	if capturing {
		p.rx.groups += 1
		index = p.rx.groups
		append(&p.rx.prog, Rx_Inst{op = .Save, n = 2 * index})
	}
	rx_parse_alt(p)
	if !p.ok {
		return
	}
	if p.at >= len(p.pat) || p.pat[p.at] != ')' {
		p.ok = false
		return
	}
	p.at += 1
	if capturing {
		append(&p.rx.prog, Rx_Inst{op = .Save, n = 2 * index + 1})
	}
}

// rx_parse_escape_atom handles a backslash outside a character class:
// a back-reference, a class escape (`\d`, `\p{L}`, …), or an escaped
// metacharacter.
@(private = "file")
rx_parse_escape_atom :: proc(p: ^Rx_Parser) {
	p.at += 1
	if p.at >= len(p.pat) {
		p.ok = false
		return
	}
	c := p.pat[p.at]
	if c >= '1' && c <= '9' {
		n := 0
		for p.at < len(p.pat) && p.pat[p.at] >= '0' && p.pat[p.at] <= '9' {
			n = n * 10 + int(p.pat[p.at] - '0')
			p.at += 1
		}
		if n > p.rx.groups {
			p.ok = false
			return
		}
		append(&p.rx.prog, Rx_Inst{op = .Backref, n = n})
		return
	}
	if index, is_class := rx_parse_class_escape(p); is_class {
		append(&p.rx.prog, Rx_Inst{op = .Class, n = index})
		return
	}
	if !p.ok {
		return
	}
	r, escaped := rx_parse_char_escape(p)
	if !escaped {
		p.ok = false
		return
	}
	append(&p.rx.prog, Rx_Inst{op = .Char, r = r})
}

// rx_parse_class_escape recognises the escapes that stand for a set of
// characters rather than one, and builds a single-shorthand class for
// them. The cursor is on the letter after the backslash.
@(private = "file")
rx_parse_class_escape :: proc(p: ^Rx_Parser) -> (index: int, is_class: bool) {
	short: Rx_Shorthand
	switch p.pat[p.at] {
	case 'd':
		short = .Digit
	case 'D':
		short = .Not_Digit
	case 's':
		short = .Space
	case 'S':
		short = .Not_Space
	case 'w':
		short = .Word
	case 'W':
		short = .Not_Word
	case 'i':
		short = .Name_Start
	case 'I':
		short = .Not_Name_Start
	case 'c':
		short = .Name_Char
	case 'C':
		short = .Not_Name_Char
	case 'p', 'P':
		negated := p.pat[p.at] == 'P'
		category, category_ok := rx_parse_category(p)
		if !category_ok {
			p.ok = false
			return 0, false
		}
		class := Rx_Class {
			negated    = negated,
			ranges     = make([dynamic]Rx_Range, p.rx.allocator),
			shorthands = make([dynamic]Rx_Shorthand, p.rx.allocator),
			subtract   = -1,
		}
		append(&class.shorthands, category)
		append(&p.rx.classes, class)
		return len(p.rx.classes) - 1, true
	case:
		return 0, false
	}
	p.at += 1
	class := Rx_Class {
		ranges     = make([dynamic]Rx_Range, p.rx.allocator),
		shorthands = make([dynamic]Rx_Shorthand, p.rx.allocator),
		subtract   = -1,
	}
	append(&class.shorthands, short)
	append(&p.rx.classes, class)
	return len(p.rx.classes) - 1, true
}

// rx_parse_category reads `\p{...}`. The cursor is on the 'p' or 'P'.
// Only the general categories are recognised; a block name
// (`\p{IsGreek}`) is refused rather than silently matching nothing,
// because a pattern that cannot be honoured must raise an error.
@(private = "file")
rx_parse_category :: proc(p: ^Rx_Parser) -> (short: Rx_Shorthand, ok: bool) {
	p.at += 1 // 'p' or 'P'
	if p.at >= len(p.pat) || p.pat[p.at] != '{' {
		return .Letter, false
	}
	p.at += 1
	start := p.at
	for p.at < len(p.pat) && p.pat[p.at] != '}' {
		p.at += 1
	}
	if p.at >= len(p.pat) {
		return .Letter, false
	}
	name := p.pat[start:p.at]
	p.at += 1 // '}'
	if len(name) == 0 || len(name) > 2 {
		return .Letter, false
	}
	if len(name) == 2 {
		switch {
		case name[0] == 'L' && name[1] == 'u':
			return .Upper, true
		case name[0] == 'L' && name[1] == 'l':
			return .Lower, true
		case name[0] == 'N' && name[1] == 'd':
			return .Decimal, true
		}
		return .Letter, false
	}
	switch name[0] {
	case 'L':
		return .Letter, true
	case 'N':
		return .Number, true
	case 'P':
		return .Punctuation, true
	case 'Z':
		return .Separator, true
	case 'S':
		return .Symbol, true
	case 'M':
		return .Mark, true
	case 'C':
		return .Other, true
	}
	return .Letter, false
}

// rx_parse_char_escape reads a single-character escape. The cursor is
// on the character after the backslash and is advanced past it.
@(private = "file")
rx_parse_char_escape :: proc(p: ^Rx_Parser) -> (r: rune, ok: bool) {
	c := p.pat[p.at]
	p.at += 1
	switch c {
	case 'n':
		return '\n', true
	case 'r':
		return '\r', true
	case 't':
		return '\t', true
	case '\\', '|', '.', '-', '^', '?', '*', '+', '{', '}', '(', ')', '[', ']', '$', '/':
		return c, true
	}
	// XSD lists the escapable characters exhaustively; anything else is
	// a malformed pattern rather than a redundant escape.
	return 0, false
}

// rx_parse_class parses `[...]`, including XSD's class subtraction.
// The cursor is on the '['.
@(private = "file")
rx_parse_class :: proc(p: ^Rx_Parser) -> (index: int, ok: bool) {
	p.at += 1 // '['
	class := Rx_Class {
		ranges     = make([dynamic]Rx_Range, p.rx.allocator),
		shorthands = make([dynamic]Rx_Shorthand, p.rx.allocator),
		subtract   = -1,
	}
	// Reserve this class's slot before parsing a nested subtraction, so
	// the indices a nested class takes cannot shift it.
	append(&p.rx.classes, class)
	index = len(p.rx.classes) - 1

	if p.at < len(p.pat) && p.pat[p.at] == '^' {
		p.rx.classes[index].negated = true
		p.at += 1
	}
	first := true
	for {
		if p.at >= len(p.pat) {
			return 0, false
		}
		c := p.pat[p.at]
		if c == ']' && !first {
			p.at += 1
			return index, true
		}
		first = false

		// `-[` opens a subtraction, but only when a '-' is not itself the
		// last character of the class.
		if c == '-' && p.at + 1 < len(p.pat) && p.pat[p.at + 1] == '[' {
			p.at += 1
			sub, sub_ok := rx_parse_class(p)
			if !sub_ok {
				return 0, false
			}
			p.rx.classes[index].subtract = sub
			if p.at >= len(p.pat) || p.pat[p.at] != ']' {
				return 0, false
			}
			p.at += 1
			return index, true
		}

		if c == '\\' {
			p.at += 1
			if p.at >= len(p.pat) {
				return 0, false
			}
			if short, is_class := rx_parse_class_escape(p); is_class {
				// A class escape inside a class contributes its own set;
				// its wrapper class holds exactly one shorthand.
				for s in p.rx.classes[short].shorthands {
					append(&p.rx.classes[index].shorthands, s)
				}
				continue
			}
			if !p.ok {
				return 0, false
			}
			lo, escaped := rx_parse_char_escape(p)
			if !escaped {
				return 0, false
			}
			if !rx_parse_range_tail(p, index, lo) {
				return 0, false
			}
			continue
		}

		p.at += 1
		if !rx_parse_range_tail(p, index, c) {
			return 0, false
		}
	}
}

// rx_parse_range_tail appends either the single character lo or the
// range `lo-hi` when a '-' follows that is not the class's last
// character and does not open a subtraction.
@(private = "file")
rx_parse_range_tail :: proc(p: ^Rx_Parser, index: int, lo: rune) -> bool {
	if p.at + 1 < len(p.pat) && p.pat[p.at] == '-' && p.pat[p.at + 1] != ']' && p.pat[p.at + 1] != '[' {
		p.at += 1
		hi := p.pat[p.at]
		if hi == '\\' {
			p.at += 1
			if p.at >= len(p.pat) {
				return false
			}
			escaped: bool
			hi, escaped = rx_parse_char_escape(p)
			if !escaped {
				return false
			}
		} else {
			p.at += 1
		}
		if hi < lo {
			return false
		}
		append(&p.rx.classes[index].ranges, Rx_Range{lo = lo, hi = hi})
		return true
	}
	append(&p.rx.classes[index].ranges, Rx_Range{lo = lo, hi = lo})
	return true
}

// Rx_Machine is one match attempt: the compiled program, the subject as
// runes, and the capture and loop-guard slots.
@(private = "file")
Rx_Machine :: struct {
	rx:      ^Regex,
	input:   []rune,
	saved:   []int,
	marks:   []int,
	fold:    bool,
	steps:   int,
	overrun: bool,
}

// Regex_Match is where a match landed, in rune offsets. groups[g] is
// the g-th capturing group; an unmatched group keeps {-1, -1}, which is
// the distinction REPLACE's `$N` needs and the reason this engine
// exists.
Regex_Match :: struct {
	start, end: int,
	groups:     [][2]int,
}

// Rx_Scratch is the working memory one subject needs: the subject as
// runes, and the capture and loop-guard slots.
//
// The caller owns it and reuses it across every search over the same
// subject, because REPLACE searches repeatedly. It is a parameter
// rather than a temp-allocator allocation on purpose: this engine runs
// inside a per-solution evaluation, and a library that quietly fills
// the host's temporary arena once per solution breaks the executor's
// contract that a streaming operator allocates nothing per solution.
@(private = "file")
Rx_Scratch :: struct {
	input:     []rune,
	saved:     []int,
	marks:     []int,
	groups:    [][2]int,
	allocator: runtime.Allocator,
}

@(private = "file")
rx_scratch_make :: proc(rx: ^Regex, text: string, allocator: runtime.Allocator) -> Rx_Scratch {
	return Rx_Scratch {
		input = utf8.string_to_runes(text, allocator),
		saved = make([]int, 2 * (rx.groups + 1), allocator),
		marks = make([]int, max(rx.marks, 1), allocator),
		groups = make([][2]int, max(rx.groups, 1), allocator),
		allocator = allocator,
	}
}

@(private = "file")
rx_scratch_destroy :: proc(s: ^Rx_Scratch) {
	delete(s.input, s.allocator)
	delete(s.saved, s.allocator)
	delete(s.marks, s.allocator)
	delete(s.groups, s.allocator)
	s^ = {}
}

// regex_search finds the leftmost match at or after `from`, searching
// over runes. ok is false when there is none; overrun is true when the
// step budget ran out, which the caller must report as a type error
// rather than as "no match".
@(private = "file")
regex_search :: proc(
	rx: ^Regex,
	scratch: ^Rx_Scratch,
	from: int,
	budget: ^int,
) -> (
	match: Regex_Match,
	ok: bool,
	overrun: bool,
) {
	input, saved, marks, groups := scratch.input, scratch.saved, scratch.marks, scratch.groups
	m := Rx_Machine {
		rx    = rx,
		input = input,
		saved = saved,
		marks = marks,
		fold  = .Case_Insensitive in rx.flags,
		steps = budget^,
	}
	for start := from; start <= len(input); start += 1 {
		for i in 0 ..< len(saved) {
			saved[i] = -1
		}
		end, matched := rx_run(&m, 0, start)
		if m.overrun {
			budget^ = m.steps
			return {}, false, true
		}
		if !matched {
			continue
		}
		match.start = start
		match.end = end
		match.groups = groups
		for g in 1 ..= rx.groups {
			if g - 1 < len(groups) {
				groups[g - 1] = {saved[2 * g], saved[2 * g + 1]}
			}
		}
		budget^ = m.steps
		return match, true, false
	}
	budget^ = m.steps
	return {}, false, false
}

// rx_run is the backtracking walk. It returns the offset the match
// ended at. Every point where the program can go two ways recurses, so
// the Odin call stack *is* the backtracking stack — which is why the
// step budget matters.
@(private = "file")
rx_run :: proc(m: ^Rx_Machine, pc0, sp0: int) -> (end: int, ok: bool) {
	pc, sp := pc0, sp0
	for {
		m.steps += 1
		if m.steps > REGEX_STEP_BUDGET {
			m.overrun = true
			return 0, false
		}
		inst := m.rx.prog[pc]
		switch inst.op {
		case .Char:
			if sp >= len(m.input) || !rx_rune_eq(m.input[sp], inst.r, m.fold) {
				return 0, false
			}
			pc += 1
			sp += 1

		case .Any:
			if sp >= len(m.input) {
				return 0, false
			}
			if .Dot_All not_in m.rx.flags && (m.input[sp] == '\n' || m.input[sp] == '\r') {
				return 0, false
			}
			pc += 1
			sp += 1

		case .Class:
			if sp >= len(m.input) || !rx_class_match(m.rx, inst.n, m.input[sp], m.fold) {
				return 0, false
			}
			pc += 1
			sp += 1

		case .Split:
			if e, taken := rx_run(m, inst.a, sp); taken {
				return e, true
			}
			if m.overrun {
				return 0, false
			}
			pc = inst.b

		case .Jump:
			pc = inst.a

		case .Save:
			// The slot has to be restored when the branch fails, or a
			// group that matched only on an abandoned path would still be
			// reported.
			previous := m.saved[inst.n]
			m.saved[inst.n] = sp
			if e, taken := rx_run(m, pc + 1, sp); taken {
				return e, true
			}
			m.saved[inst.n] = previous
			return 0, false

		case .Mark:
			previous := m.marks[inst.n]
			m.marks[inst.n] = sp
			if e, taken := rx_run(m, pc + 1, sp); taken {
				return e, true
			}
			m.marks[inst.n] = previous
			return 0, false

		case .Progress:
			if sp == m.marks[inst.n] {
				// The loop body matched nothing; iterating again would not
				// either. See rx_emit_repeat.
				return 0, false
			}
			pc += 1

		case .Backref:
			from, to := m.saved[2 * inst.n], m.saved[2 * inst.n + 1]
			if from < 0 || to < 0 {
				// A group that has not participated matches the empty
				// string rather than failing (XPath's rule).
				pc += 1
				continue
			}
			width := to - from
			if sp + width > len(m.input) {
				return 0, false
			}
			for i in 0 ..< width {
				if !rx_rune_eq(m.input[sp + i], m.input[from + i], m.fold) {
					return 0, false
				}
			}
			pc += 1
			sp += width

		case .Assert_Start:
			at_line_start := sp == 0
			if !at_line_start && .Multiline in m.rx.flags {
				at_line_start = m.input[sp - 1] == '\n' || m.input[sp - 1] == '\r'
			}
			if !at_line_start {
				return 0, false
			}
			pc += 1

		case .Assert_End:
			at_line_end := sp == len(m.input)
			if !at_line_end && .Multiline in m.rx.flags {
				at_line_end = m.input[sp] == '\n' || m.input[sp] == '\r'
			}
			if !at_line_end {
				return 0, false
			}
			pc += 1

		case .Match:
			return sp, true
		}
	}
}

@(private = "file")
rx_rune_eq :: proc(a, b: rune, fold: bool) -> bool {
	if a == b {
		return true
	}
	if !fold {
		return false
	}
	return unicode.to_lower(a) == unicode.to_lower(b)
}

// rx_class_match applies a class to one rune. Case folding widens the
// *test*, not the class: under `i` a rune matches if it does in any
// case, which is what `[0-9A-F]` under "i" needs for the UUID tests.
@(private = "file")
rx_class_match :: proc(rx: ^Regex, index: int, r: rune, fold: bool) -> bool {
	class := &rx.classes[index]
	hit := rx_class_hit(class, r)
	if !hit && fold {
		if lower := unicode.to_lower(r); lower != r {
			hit = rx_class_hit(class, lower)
		}
		if !hit {
			if upper := unicode.to_upper(r); upper != r {
				hit = rx_class_hit(class, upper)
			}
		}
	}
	if hit && class.subtract >= 0 && rx_class_match(rx, class.subtract, r, fold) {
		hit = false
	}
	if class.negated {
		hit = !hit
	}
	return hit
}

@(private = "file")
rx_class_hit :: proc(class: ^Rx_Class, r: rune) -> bool {
	for range in class.ranges {
		if range.lo <= r && r <= range.hi {
			return true
		}
	}
	for short in class.shorthands {
		if rx_shorthand_hit(short, r) {
			return true
		}
	}
	return false
}

@(private = "file")
rx_shorthand_hit :: proc(short: Rx_Shorthand, r: rune) -> bool {
	switch short {
	case .Digit:
		return unicode.is_digit(r)
	case .Not_Digit:
		return !unicode.is_digit(r)
	case .Space:
		// XSD's \s is exactly these four, not Unicode's whitespace class.
		return r == ' ' || r == '\t' || r == '\n' || r == '\r'
	case .Not_Space:
		return !(r == ' ' || r == '\t' || r == '\n' || r == '\r')
	case .Word:
		// XSD: everything except punctuation, separators, and the "other"
		// categories.
		return !(unicode.is_punct(r) || unicode.is_space(r) || unicode.is_control(r))
	case .Not_Word:
		return unicode.is_punct(r) || unicode.is_space(r) || unicode.is_control(r)
	case .Name_Start:
		return unicode.is_letter(r) || r == '_' || r == ':'
	case .Not_Name_Start:
		return !(unicode.is_letter(r) || r == '_' || r == ':')
	case .Name_Char:
		return unicode.is_letter(r) || unicode.is_digit(r) || r == '.' || r == '-' || r == '_' || r == ':'
	case .Not_Name_Char:
		return !(unicode.is_letter(r) || unicode.is_digit(r) || r == '.' || r == '-' || r == '_' || r == ':')
	case .Letter:
		return unicode.is_letter(r)
	case .Upper:
		return unicode.is_upper(r)
	case .Lower:
		return unicode.is_lower(r)
	case .Number:
		return unicode.is_number(r)
	case .Decimal:
		return unicode.is_digit(r)
	case .Punctuation:
		return unicode.is_punct(r)
	case .Separator:
		return unicode.is_space(r)
	case .Symbol:
		return unicode.is_symbol(r)
	case .Mark:
		return unicode.is_combining(r)
	case .Other:
		return unicode.is_control(r)
	}
	return false
}

// regex_matches is fn:matches: does the pattern occur anywhere in the
// subject? ok is false when the search exhausted its budget, which the
// caller reports as a type error.
regex_matches :: proc(rx: ^Regex, text: string, allocator := context.allocator) -> (matched: bool, ok: bool) {
	scratch := rx_scratch_make(rx, text, allocator)
	defer rx_scratch_destroy(&scratch)
	budget := 0
	_, found, overrun := regex_search(rx, &scratch, 0, &budget)
	if overrun {
		return false, false
	}
	return found, true
}

// regex_replace is fn:replace: every non-overlapping match rewritten
// with the replacement, whose `$N` are the capture groups. The caller
// owns the result.
//
// A pattern that matches the empty string advances one character rather
// than raising XPath's FORX0003 — the SPARQL suites do not exercise it,
// and looping forever is the one outcome that is certainly wrong.
regex_replace :: proc(
	rx: ^Regex,
	text: string,
	replacement: string,
	allocator := context.allocator,
) -> (
	result: string,
	ok: bool,
) {
	scratch := rx_scratch_make(rx, text, allocator)
	defer rx_scratch_destroy(&scratch)
	runes := scratch.input
	rep := utf8.string_to_runes(replacement, allocator)
	defer delete(rep, allocator)

	b := strings.builder_make(allocator)
	budget := 0
	at := 0
	for at <= len(runes) {
		match, found, overrun := regex_search(rx, &scratch, at, &budget)
		if overrun {
			strings.builder_destroy(&b)
			return "", false
		}
		if !found {
			break
		}
		for i in at ..< match.start {
			strings.write_rune(&b, runes[i])
		}
		if !rx_write_replacement(&b, rep, runes, scratch.groups[:rx.groups], match) {
			strings.builder_destroy(&b)
			return "", false
		}
		if match.end == match.start {
			if match.start < len(runes) {
				strings.write_rune(&b, runes[match.start])
			}
			at = match.start + 1
			continue
		}
		at = match.end
	}
	for i in at ..< len(runes) {
		strings.write_rune(&b, runes[i])
	}
	return strings.to_string(b), true
}

// rx_write_replacement expands `$N` and the `\$` / `\\` escapes. A
// group that did not participate contributes nothing, which is what
// `REPLACE("abcd","(ab)|(a)","[1=$1][2=$2]")` asks for.
@(private = "file")
rx_write_replacement :: proc(
	b: ^strings.Builder,
	rep: []rune,
	input: []rune,
	groups: [][2]int,
	match: Regex_Match,
) -> bool {
	for i := 0; i < len(rep); i += 1 {
		switch rep[i] {
		case '\\':
			// XPath: a backslash in the replacement must escape a '$' or
			// another backslash, and nothing else.
			if i + 1 >= len(rep) || (rep[i + 1] != '$' && rep[i + 1] != '\\') {
				return false
			}
			i += 1
			strings.write_rune(b, rep[i])
		case '$':
			if i + 1 >= len(rep) || rep[i + 1] < '0' || rep[i + 1] > '9' {
				return false
			}
			n := 0
			for i + 1 < len(rep) && rep[i + 1] >= '0' && rep[i + 1] <= '9' {
				i += 1
				n = n * 10 + int(rep[i] - '0')
			}
			from, to := -1, -1
			if n == 0 {
				from, to = match.start, match.end
			} else if n <= len(groups) {
				from, to = groups[n - 1][0], groups[n - 1][1]
			}
			if from < 0 || to < 0 {
				continue
			}
			for j in from ..< to {
				strings.write_rune(b, input[j])
			}
		case:
			strings.write_rune(b, rep[i])
		}
	}
	return true
}
