---
id: an-unterminated-long-string
level: task
title: "An unterminated long string reports the EOF line and a negative column"
short_code: "SPARQL-T-0042"
created_at: 2026-08-25T16:33:42.879345+00:00
updated_at: 2026-08-25T16:40:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#phase/completed"
  - "#bug"


exit_criteria_met: true
initiative_id: NULL
---

# An unterminated long string reports the EOF line and a negative column

## Objective **[REQUIRED]**

On an unterminated long string literal in a query — `"""…` or `'''…` never
closed — the scanner's `Error` carries three position fields drawn from two
different coordinate systems. `offset` is the opener's, because
`scan_long_string` passes `start`. `line` and `column` are computed at end
of input: `line` is whatever line the scanner walked to, and `column` is
`offset - s.line_start + 1` with `line_start` already moved past `offset`
by the newlines the literal legally contains, **so it comes out negative**.

Reproduced by `sparql/scanner_test.odin`, written before the fix:

```
"SELECT ?x\n  '''abc\ndef\nghi"   offset=12  line=4  column=-10   (the ''' is at 2:3)
"\"\"\"a\nb\""                    offset=0   line=2  column=-4    (the """ is at 1:1)
```

Make the three fields agree on one position — the opener's, which is what
`offset` already names and what a reader wants told.

**This is odin-rdf-parser's `RDF-T-0025`, line for line.** That item's own
notes named this scanner as carrying a copy and said the fix belongs on
this side; the family `CLAUDE.md` has recorded it as unfiled here since
2026-08-20. This is the filing.

## Backlog Item Details **[CONDITIONAL: Backlog Item]**

### Type
- [x] Bug - Something is broken

### Priority
- [x] P2 - Medium

Matching `RDF-T-0025`'s priority, for the same reasons: nothing computes a
wrong answer, and no suite notices — but the position is the one thing a
user reads when a multi-line literal is broken, and it names the wrong line
and then nothing at all.

### Impact Assessment **[CONDITIONAL: Bug]**
- **Where**: `sparql/scanner.odin`, `scan_long_string`'s end-of-input
  branch calling `set_error(s, .Unterminated_Long_String, start)`.
- **Confined to long strings.** Every other `set_error` call site in this
  scanner is sound: those passing `s.pos` report where the scanner stands,
  which is correct; those passing a saved `start` — variables, blank-node
  labels, language tags, numbers, keywords, IRIs, short strings — cover
  productions that cannot contain a raw newline, so `line_start` never
  moves between `start` and the error. A raw newline inside a short string
  is `Invalid_String_Character` at the newline, and an escape error
  *inside* a long string reports the scanner's current position, which is
  the right place for it.
- **Affected users**: anyone whose query fails to parse on an unclosed
  multi-line literal. **odin-rdf-app prints exactly these two fields** —
  `src/main.odin:235`, `"query is not valid SPARQL at %d:%d: %s"` with
  `err.line` and `err.column` — so a user of the app is told `at 4:-10`.
  Checked in that repository, not inferred from `RDF-T-0025`'s note.
- **Expected vs actual**: expected the opener's line and column, agreeing
  with `offset`; actual is the line the scanner stopped on and a negative
  column.
- **Why no suite catches it**: the 352 vendored syntax entries assert that
  a negative-syntax query *errors*, never where. The scanner's own
  position tests were all single-line, which is exactly the case the
  defect leaves correct.

## Acceptance Criteria **[REQUIRED]**

- [x] `Unterminated_Long_String` reports the opener's `line` and `column`,
      agreeing with `offset`, for a literal that crosses one or more
      newlines.
- [x] A scanner test pins it with newlines inside the unterminated literal,
      and fails on the unfixed scanner.
- [x] Every other `set_error` call site checked rather than assumed, and
      the finding recorded.
- [x] `make test` and `make check` green.

## Implementation Notes **[CONDITIONAL: Technical Task]**

### Technical Approach

The same change odin-rdf-parser made. `scan_long_string` already receives
the token, whose `line` and `column` were computed at token start in
`scanner_next` — the opener's, by construction. Build the error from those
with `offset = start`, rather than calling `set_error`, which recomputes
the column from a `line_start` the literal has moved. `set_error` itself
and every other caller stay unchanged: recomputing from the scanner's
current position is right everywhere else.

### Dependencies

None. It touches one branch of one procedure and no consumer of this
repository asserts the old behaviour.

### Risk Considerations

The `Error` struct and `Error_Kind` do not change, so no caller's code
moves. The one risk is fixing the position in the wrong direction — a
reader wants "the literal that opened at 2:3 is never closed", not "input
ended at 4:1" — and the tests pin the opener explicitly, including
`offset`, so a later refactor cannot quietly swap the coordinate system
back.

## Status Updates **[REQUIRED]**

- **2026-08-25 — filed and fixed the same hour.** `scan_long_string`'s
  end-of-input branch builds the error itself from `tok.line` / `tok.column`
  — the opener's, computed in `scanner_next` before the dispatch — with
  `offset = start`, instead of calling `set_error` and letting it recompute
  a column from a `line_start` the literal has moved. `set_error` is
  untouched and so is every other caller. The change is one branch of one
  procedure, and it is the same change odin-rdf-parser made at
  `RDF-T-0025`, which is what a line-for-line copy deserves.

  **Written as a reproduction first.**
  `sparql/scanner_test.odin:test_unterminated_long_string_position` pins
  three cases and asserts `offset`, `line` and `column` on each: a
  single-line literal (correct before the fix — the case that hid the
  defect for as long as the scanner has existed), a literal opening at 2:3
  and crossing three lines, and one opening at 1:1 whose trailing quote run
  is one short. On the unfixed scanner the second reported `line 4,
  column -10` and the third `line 2, column -4`; both now report the
  opener. The existing `test_error_positions` is unchanged and still
  passes, which is the check that nothing else moved.

  **The rest of the scanner was read rather than assumed.** All nineteen
  other `set_error` call sites are sound, and for two distinct reasons: the
  ones passing `s.pos` (`Invalid_String_Character`, `Invalid_Escape`,
  `Invalid_Percent_Encoding`, the two IRI ones) report where the scanner
  stands, which is where those errors are; the ones passing a saved `start`
  cover productions with no raw newline in them — variables, blank-node
  labels, language tags, numbers, keywords, short strings — so `line_start`
  cannot move between `start` and the error. An escape error *inside* a
  long string keeps reporting the scanner's current position, which is
  correct and deliberately left alone.

  **Verified**: `make test` 288/288 across six packages under
  `ODIN_TEST_FAIL_ON_BAD_MEMORY`, `make check` clean including the
  instrumented build. No W3C entry's verdict moves — the 352 syntax entries
  assert that a bad query errors, never where — which is exactly why this
  needed a unit test and not a suite.

  **Not done here, and it is one line in another repository**: the family
  `CLAUDE.md` still records this copy as "not yet filed there".
