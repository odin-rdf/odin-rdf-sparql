NAME  := sparql-bench
BENCH := bench
OUT   := build/$(NAME)

# Odin source collections. The parser and the record store are sibling
# checkouts rather than vendored copies, so they are reached through
# collections instead of relative paths -- `import "rdf:rdf"` for the data
# model and `rdf:rdf/turtle` and friends for the four format packages,
# `import "record:record"` for the system of record and
# `record:record/ingest` for its document loaders. `rdf:` is required even
# where this project only names the record: its own sources import it, and
# a collection is resolved in the importing compilation, not the imported
# checkout. ols.json declares the same set so the language server resolves
# what the compiler does.
#
# **`store:` is gone as of SPARQL-T-0031.** This engine was written
# backend-independent over odin-rdf-store's match interface and
# instantiated in `sparql/kvstore`; odin-rdf-record is the one and only
# store from here on (owner, 2026-08-24), so the seam is retired rather
# than re-pointed and nothing in this repository links LMDB.
COLL := -collection:rdf=../odin-rdf-parser -collection:record=../odin-rdf-record

# Every package with Odin sources, pinned explicitly the way odin-rdf-store
# does -- discovery cannot express intent about what belongs (SPARQL-T-0001).
# sparql is the engine: parser, algebra, evaluator, and -- since
# SPARQL-T-0031 collapsed the instantiation seam -- the prepared-query API
# that `sparql/kvstore` used to hold. sparql/srj and sparql/srx are the two
# results serializations; they stay separate because they are output
# formats, never instantiations.
#
# tests/guards holds the allocation guards; tests/readme compiles and
# asserts the README's examples (SPARQL-T-0009); tests/w3c/harness runs
# the vendored W3C suites. The three of them plus the nine test files
# that lived in the deleted sparql/kvstore were ported to odin-rdf-record
# across SPARQL-T-0032 and -T-0033 -- the nine are in `sparql` now,
# because their subject was always SPARQL and only incidentally a
# backend.
#
# **The port's red edge is closed.** `PENDING` lived here for two tasks,
# listing what did not yet compile so that what was missing was visible
# in this file rather than only in a task; it is empty and gone, and so
# are the two bridge packages that stood in for the suite while it was
# (tests/smoke, tests/portcheck).
PKGS     := sparql sparql/srj sparql/srx tests/guards tests/w3c/harness tests/readme
# bench/ has an entry point, so it is vetted outside the PKGS loop rather
# than inside it -- and both of its builds are, since a `when`-gated
# branch that nothing compiles is a branch that rots (SPARQL-T-0040).
SRC_DIRS := $(PKGS) $(BENCH)

# **There is no Term_ID width matrix any more** (SPARQL-T-0031). It existed
# because STORE-A-0001 made odin-rdf-store's Term_ID width a build-time
# choice and this project compiled the store's sources into its own
# binaries. odin-rdf-record's widths are fixed by design -- its inline term
# encoding was frozen at first write -- so there is one configuration and
# `make test` runs once. odin-rdf-shacl became exempt the same way and for
# the same reason (2026-08-20).

.PHONY: all help test check check-aliases bench build-bench clean

all: test

# The description of a target is the `##` on its own recipe line, which is what
# help greps for -- prose above a target is for a reader of this file, not the
# listing. A target with no `##` is internal and stays out of it.
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# The test runner tracks allocations per test but only warns about leaks and bad
# frees by default, which a passing build hides. Promote them to failures.
TEST_FLAGS := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(COLL)

test: ## Run the full suite
	@if [ -z "$(PKGS)" ]; then echo "no packages yet"; exit 0; fi; \
	for pkg in $(PKGS); do \
		echo "-- $$pkg --"; \
		odin test $$pkg $(TEST_FLAGS) || exit 1; \
	done


# Vets every package including the ones with no tests, so a package the suite
# never instantiates still has to compile clean.
check: ## Vet every package
	@if [ -z "$(SRC_DIRS)" ]; then echo "no packages yet"; exit 0; fi; \
	for pkg in $(filter-out $(BENCH),$(SRC_DIRS)); do \
		echo "-- $$pkg --"; \
		odin check $$pkg -no-entry-point -vet -strict-style $(COLL) || exit 1; \
	done
	@echo "-- $(BENCH) --"
	@odin check $(BENCH) -vet -strict-style $(COLL) || exit 1
	@odin check $(BENCH) -vet -strict-style $(COLL) -define:SPARQL_COUNT_READS=true || exit 1
	@echo "-- sparql (instrumented) --"
	@odin check sparql -no-entry-point -vet -strict-style $(COLL) -define:SPARQL_COUNT_READS=true || exit 1
	@echo "-- import aliases --"
	@$(MAKE) --no-print-directory check-aliases

# Benchmarks measure the engine, and a debug build measures the compiler
# instead, so they get the release flags.
#
# **Two builds, not one** (SPARQL-T-0040). Read counting lives behind
# `-define:SPARQL_COUNT_READS` in `sparql/counting.odin`, and a
# counter inside the timed binary would be measuring itself, so the timed
# run carries no counter at all -- `when SPARQL_COUNT_READS` compiles to
# nothing. The instrumented run takes no timings and is where the pinned
# counts are asserted; it is also the one that fails the target when a
# count moves. odin-rdf-shacl's `make bench` has the same shape and for
# the same reason.
bench: ## Build and run the benchmarks with release flags (timing, then instrumented)
	@test -d $(BENCH) || { echo "no $(BENCH)/ package yet"; exit 0; }; \
	mkdir -p build
	@odin run $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL) || exit 1
	@echo
	@odin run $(BENCH) -out:$(OUT)-counted -o:speed -no-bounds-check $(COLL) -define:SPARQL_COUNT_READS=true || exit 1

build-bench: ## Build both benchmark binaries without running them
	@test -d $(BENCH) || { echo "no $(BENCH)/ package yet"; exit 0; }; \
	mkdir -p build
	@odin build $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL) || exit 1
	@odin build $(BENCH) -out:$(OUT)-counted -o:speed -no-bounds-check $(COLL) -define:SPARQL_COUNT_READS=true || exit 1

# An import alias that repeats the package's own name is noise, and the
# port left a lot of it behind: `import sparql "../../sparql"` and
# `import record "record:record"` say nothing an unaliased import does
# not. odin-rdf-shacl ends its `check` with this grep for the same
# reason; it is here since SPARQL-T-0033, when every import in the
# repository was being rewritten anyway.
#
# Aliases that are *not* redundant stay: `rdf "rdf:rdf"` is one (the
# unaliased form binds `rdf` too, but the collection prefix makes the
# intent worth stating), and any alias that renames rather than repeats.
check-aliases:
	@bad=$$(grep -rn 'import \([a-z_][a-z_0-9]*\) "[^"]*/\1"' --include='*.odin' . || true); \
	if [ -n "$$bad" ]; then \
		echo "redundant import alias -- the alias repeats the package name:"; \
		echo "$$bad"; \
		exit 1; \
	fi

clean: ## Remove build/
	rm -rf build
