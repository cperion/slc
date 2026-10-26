LUA ?= luajit

# LuaJIT needs LPeg's Lua 5.1 ABI, not the system Lua's newer ABI.
ROCKS_CPATH := $(shell command -v luarocks >/dev/null 2>&1 && luarocks --lua-version=5.1 path --lr-cpath 2>/dev/null)
ifeq ($(origin LUA_CPATH),undefined)
export LUA_CPATH := $(ROCKS_CPATH);;
endif
export SLC_CACHE ?= $(CURDIR)/build/cache
export TMPDIR ?= $(CURDIR)/build/tmp
export SLC_WORKERS ?= 2
ifeq ($(origin SLC_GCCJIT),undefined)
ifneq ($(wildcard $(CURDIR)/.local/lib/libgccjit.so.0),)
export SLC_GCCJIT := $(CURDIR)/.local/lib/libgccjit.so.0
endif
endif

.PHONY: help doctor dirs test test-macros test-native run
help:
	@printf '%s\n' 'make doctor       Check LuaJIT, LPeg, C compiler and optional libgccjit' 'make test         Macro checks and complete packaged C/JIT test suite' 'make test-macros  Source-module and macro CLI regressions' 'make test-native  Require libgccjit and run in-process checks' 'make run PROGRAM=examples/csv.slc ARGS="examples/data/sales.csv price"'

dirs:
	@mkdir -p "$(TMPDIR)" "$(SLC_CACHE)" build/logs

doctor: dirs
	@$(LUA) tools/doctor.lua
	@$(CC) --version

test-macros: dirs
	$(LUA) tests/macros.lua

test: test-macros
	$(LUA) tests/run.lua

test-native: dirs
	$(LUA) -e 'require("slc.cjit").lib()'
	$(LUA) tests/native.lua

run: dirs
	@test -n "$(PROGRAM)" || { printf '%s\n' 'Set PROGRAM=path/to/program.slc'; exit 2; }
	$(LUA) slc.lua run "$(PROGRAM)" $(ARGS)
