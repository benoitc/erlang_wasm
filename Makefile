.PHONY: all compile check test ct lint xref dialyzer docs bench suites clean

all: compile

compile:
	rebar3 compile

# What every change has to pass. Same list as `.github/workflows/ci.yml'.
check: lint xref dialyzer ct

test: ct

ct:
	rebar3 ct

lint:
	rebar3 lint

xref:
	rebar3 xref

dialyzer:
	rebar3 dialyzer

docs:
	rebar3 ex_doc

# The benchmark arms the performance record in `test/audit/PERF.md' cites.
# `realbench' is the one a speed claim comes from; read
# `bench/paths/README.md' before believing any of them.
bench:
	rebar3 bench

# Neither upstream suite is vendored. Both are skipped when absent, so a
# conformance run without them proves nothing.
suites:
	@test -d testsuite || \
	    git clone --depth 1 https://github.com/WebAssembly/testsuite.git
	@test -d wasi-testsuite || \
	    git clone --depth 1 --branch prod/testsuite-base \
	        https://github.com/WebAssembly/wasi-testsuite.git

clean:
	rebar3 clean
	rm -rf _build/test/logs
