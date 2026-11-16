.PHONY: check lint format typecheck test

LUA_DIRS := $(wildcard lua plugin tests)
VIMRUNTIME := $(shell nvim --clean --headless +'lua io.write(vim.env.VIMRUNTIME)' +qa)

# Everything CI runs.
check: lint typecheck test

lint:
	stylua --check $(LUA_DIRS)
	luacheck $(LUA_DIRS)

format:
	stylua $(LUA_DIRS)

typecheck:
	VIMRUNTIME='$(VIMRUNTIME)' lua-language-server --check . --checklevel=Warning --check_format=pretty

# make test CASE=harness runs the cases whose names contain `harness`.
test:
	nvim -l tests/run.lua $(CASE)
