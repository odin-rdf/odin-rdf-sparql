NAME  := sparql-bench
BENCH := bench
OUT   := build/$(NAME)

# Odin source collections. The parser and the store are sibling checkouts
# rather than vendored copies, so they are reached through collections instead
# of relative paths -- `import "rdf:rdf"` for the data model and `rdf:rdf/turtle`
# and friends for the four format packages, `import "store:store"` for the match
# interface and `store:store/kvstore` for the backend. Both collections are
# required even where this project only names the
# store: the store's own sources import `rdf:`, and a collection is resolved in
# the importing compilation, not the imported checkout. ols.json declares the
# same pair so the language server resolves what the compiler does.
COLL := -collection:rdf=../odin-rdf-parser -collection:store=../odin-rdf-store

# Every package with Odin sources, pinned explicitly the way odin-rdf-store
# does -- discovery cannot express intent about what belongs (SPARQL-T-0001).
# sparql is the public engine package: parser, algebra, and the
# backend-independent evaluator. sparql/kvstore is its instantiation over the
# store's backend -- a separate package because the core names no backend
# (SPARQL-T-0011). It was one of two until odin-rdf-store retired its in-memory
# backend (STORE-A-0006); the split survives because the core/instantiation
# boundary is what a future backend would use, not because two exist today.
# tests/w3c/harness runs the vendored W3C suites; tests/guards holds the
# allocation-guard tests; tests/readme compiles and asserts the README's
# example (SPARQL-T-0009).
PKGS     := sparql sparql/srj sparql/srx sparql/kvstore tests/guards tests/w3c/harness tests/readme
SRC_DIRS := $(PKGS)

# STORE-A-0001 makes the store's Term_ID width a build-time choice, and this
# project compiles the store's sources into its own binaries. Query code must
# not assume 64-bit IDs, so the suite runs once per configuration rather than
# once. This is what CI should invoke -- `make test`, the whole matrix.
WIDTHS := 64 32

.PHONY: all help test check bench build-bench clean

all: test

# The description of a target is the `##` on its own recipe line, which is what
# help greps for -- prose above a target is for a reader of this file, not the
# listing. A target with no `##` is internal and stays out of it.
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# The test runner tracks allocations per test but only warns about leaks and bad
# frees by default, which a passing build hides. Promote them to failures.
TEST_FLAGS := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(COLL)

test: ## Run the full suite at both Term_ID widths
	@if [ -z "$(PKGS)" ]; then echo "no packages yet"; exit 0; fi; \
	for width in $(WIDTHS); do \
		echo "== Term_ID $$width-bit =="; \
		for pkg in $(PKGS); do \
			echo "-- $$pkg --"; \
			odin test $$pkg $(TEST_FLAGS) \
				-define:RDF_STORE_TERM_ID_BITS=$$width || exit 1; \
		done; \
	done

# Vets every package including the ones with no tests, so a package the suite
# never instantiates still has to compile clean.
check: ## Vet every package at the default Term_ID width
	@if [ -z "$(SRC_DIRS)" ]; then echo "no packages yet"; exit 0; fi; \
	for pkg in $(filter-out ./$(BENCH),$(SRC_DIRS)); do \
		echo "-- $$pkg --"; \
		odin check $$pkg -no-entry-point -vet -strict-style $(COLL) || exit 1; \
	done
	@test -d $(BENCH) && odin check $(BENCH) -vet -strict-style $(COLL) || true

# Benchmarks measure the engine, and a debug build measures the compiler
# instead, so they get the release flags.
bench: ## Build and run the benchmarks with release flags
	@test -d $(BENCH) || { echo "no $(BENCH)/ package yet"; exit 0; }; \
	mkdir -p build && odin run $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL)

build-bench: ## Build the benchmark binary without running it
	@test -d $(BENCH) || { echo "no $(BENCH)/ package yet"; exit 0; }; \
	mkdir -p build && odin build $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL)

clean: ## Remove build/
	rm -rf build
