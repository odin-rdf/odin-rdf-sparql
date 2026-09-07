package sparql

import "core:time"

// The per-query budget (SPARQL-T-0053) — a ceiling on what running a
// query may cost, checked by the executor rather than by the caller's
// pull loop.
//
// **Why a caller cannot do this from outside.** `query_next` runs until
// the next solution or until the input is exhausted, so a consumer that
// wants "at most N rows or at most T seconds" can enforce the first
// between pulls and cannot enforce the second at all: the whole cost may
// fall inside one call. The case that filed this is a three-way join
// over a few hundred instances with a FILTER nothing satisfies — one
// `query_next` returning `false` after 24.3 seconds on a store where
// every honest query finishes inside 63 ms. The difference is not the
// answer's size; it is where the time is spent, and no bound expressible
// from outside the engine separates the two.
//
// # What the engine bounds, and what it does not
//
// **Two bounds, and deliberately not a third.**
//
//   - `ops` — the engine's own unit of work. Deterministic: the same
//     query over the same snapshot is cut in the same place on any
//     machine under any load, which is what makes a refusal explicable
//     and a test repeatable.
//   - `wall` — a duration from `query_init`. What a consumer actually
//     has ("this request has 5 seconds left"), and the only bound that
//     survives a machine being slower than the one the number was
//     chosen on.
//
// Both may be set; the first one reached stops the query.
//
// **There is no row bound here, and that is a decision rather than an
// omission.** The pull loop is the caller's: `query_next` hands back one
// solution at a time and a caller counting them enforces a row ceiling
// exactly, immediately, and at no cost inside the engine. A second way
// to spell it here would be a third answer to a question the algebra
// (`LIMIT`) and the consumer already answer, and it would not touch the
// case this exists for — the query it must stop produces no rows at all.
//
// # The unit
//
// An **operation** is one turn of the executor: one solution asked of a
// source operator, or one step of a scan inside a source that does not
// return between facts. Between the two there is no loop in the engine
// that can run long without ticking — the driver walk cannot spin
// without asking a source, and a source that spins is stepping a scan. It is not a promise about how many
// operations a given query costs — that is a property of the plan, the
// data and the join order, and it moves when any of them does. Treat it
// as a large round number chosen by experiment against your own data,
// the way a stack size is.
//
// # The cadence, and why it costs nothing
//
// The budget is checked every `BUDGET_CADENCE` operations, not every
// one. A clock read per join probe would be the expensive answer to a
// cheap problem, and the answer here is that the hot path is **one
// decrement and one branch**: `countdown` is pre-charged with the chunk,
// the check happens when it reaches zero, and only there is the clock
// read or the arithmetic done.
//
// **An unbudgeted query pre-charges `max(int)`**, so the branch is never
// taken and the check is never reached — no flag, no second compare, and
// nothing to predict wrongly. That is why this is unconditional rather
// than gated on a `-define` the way `counting.odin` is: what would be
// gated is one decrement, and a bound nobody can set is not a bound.
//
// The consequence to state plainly: **`ops` is honoured to within
// `BUDGET_CADENCE`.** A query given 1,000 operations may take up to
// 5,095 before it stops, and a deadline may be noticed up to one chunk
// late. Both are bounds on the pathological case, not accounting.
//
// # Telling a cut query apart from a finished one
//
// `query_next` answering `false` for both would make a truncated answer
// indistinguishable from a complete one, which is the failure this
// exists to prevent. `query_next`'s arity does not change — a consumer
// that sets no budget compiles and behaves exactly as before — so the
// verdict is read after the loop:
//
//	for {
//		row, more := sparql.query_next(&q)
//		if !more {
//			break
//		}
//		// …
//	}
//	if cut := sparql.query_stopped(&q); cut != .None {
//		// the answer is a prefix, and `cut` says which bound ended it
//	}
//
// It is an enum and not a `bool` because a consumer that must explain
// the refusal has two different things to say — "this cost more than the
// engine was allowed to spend" and "this took longer than you had" — and
// the second is the one a user retries.
//
// **A cut query stays cut.** Once a bound is reached every later
// `query_next` answers `false` without touching the store, and
// `query_stopped` keeps naming the bound until `query_destroy`. A
// `CONSTRUCT` or `DESCRIBE` cut mid-run hands back the graph it had
// built, which is a partial answer and says so through the same
// accessor.

// BUDGET_CADENCE is how many operations pass between two checks. Large
// enough that the check is lost in the noise of the operations it
// separates, small enough that a deadline in the seconds is noticed
// within a millisecond or two — the counting loops run at 0.1–1.7 µs a
// row, so a chunk is well under 10 ms of work in the worst case.
BUDGET_CADENCE :: 4096

// Budget is the ceiling handed to `query_init`. The zero value is no
// budget at all, which is every existing caller and today's behaviour.
Budget :: struct {
	// The most operations the query may spend. Zero or less is
	// unbounded. See the file comment for what an operation is and for
	// the `BUDGET_CADENCE` slack on the number.
	ops:  int,
	// How long the query may run, measured from `query_init` — so
	// preparation counts, which is where a query with many patterns
	// prices its join order. Zero or less is unbounded.
	wall: time.Duration,
}

// Budget_Stop is why a query stopped, read with `query_stopped`.
// `.None` is the ordinary answer: the query ran to exhaustion and its
// solutions are all of them.
Budget_Stop :: enum {
	None,
	Operations,
	Wall_Clock,
}

// Budget_Run is the running budget, one per Query. It is the Exec's,
// not a global: two queries prepared against the same store carry
// independent ceilings, which is the whole difference between this and
// the process-wide tally in `counting.odin` — that one is a benchmark
// instrument compiled out of every other build, and this one is API.
@(private)
Budget_Run :: struct {
	// Operations until the next check. The hot path reads and writes
	// nothing else.
	countdown: int,
	// What `countdown` was charged with, so a check knows how much was
	// spent without a second counter.
	chunk:     int,
	// Operations left in the whole budget. `max(int)` is unbounded.
	ops:       int,
	deadline:  time.Time,
	timed:     bool,
	stop:      Budget_Stop,
}

// budget_begin arms the budget for a run. An unbudgeted query is charged
// `max(int)`, so `budget_tick`'s branch is never taken and `budget_check`
// is never reached.
@(private)
budget_begin :: proc(r: ^Budget_Run, budget: Budget) {
	r^ = {}
	r.ops = budget.ops if budget.ops > 0 else max(int)
	r.timed = budget.wall > 0
	if r.timed {
		// The clock is read once here and then only once per chunk. It
		// is an absolute instant rather than a start plus a duration so
		// that the check is one comparison.
		r.deadline = time.time_add(time.now(), budget.wall)
	}
	if r.timed || r.ops != max(int) {
		r.chunk = min(BUDGET_CADENCE, r.ops)
	} else {
		r.chunk = max(int)
	}
	r.countdown = r.chunk
}

// budget_tick spends one operation and says whether the query may
// continue. This is the whole hot path.
@(private)
budget_tick :: proc(r: ^Budget_Run) -> bool {
	r.countdown -= 1
	if r.countdown > 0 {
		return true
	}
	return budget_check(r)
}

// budget_check is the once-a-chunk work: settle what the chunk cost,
// read the clock if there is a deadline, and charge the next chunk. It
// is a separate procedure so that the caller above stays two
// instructions long.
@(private)
budget_check :: proc(r: ^Budget_Run) -> bool {
	if r.stop != .None {
		// Already cut. Keep the countdown at zero so every later tick
		// arrives here rather than running a chunk's worth of work
		// first.
		r.countdown = 0
		return false
	}
	r.ops -= r.chunk
	if r.ops <= 0 {
		r.stop = .Operations
		r.countdown = 0
		return false
	}
	if r.timed && time.diff(time.now(), r.deadline) <= 0 {
		r.stop = .Wall_Clock
		r.countdown = 0
		return false
	}
	r.chunk = min(BUDGET_CADENCE, r.ops)
	r.countdown = r.chunk
	return true
}
