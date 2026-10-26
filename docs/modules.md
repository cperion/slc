# Lua modules, with SLC source loading

Status: implemented. [Specification §3.0](staged-lua-c-v0.5.md#30-modules-are-lua-values)
owns the language contract. There is no separate `import` API or compatibility alias.

## Source usage

```lua
local hash = require "slc.hash"
local io = require "slc.io"
local ffi = require "ffi"
local model = require "model"
```

A module returns ordinary Lua values: a vocabulary table, a function, a type,
or another value. `require` is Lua's own function, inherited by the SLC prelude.
It is not a keyword, special expression or custom cache wrapper.

Bundled SLC vocabularies use `slc.*` names. This avoids taking over Lua's
`require "io"` or another host module. For example, `slc.io` loads
[the SLC I/O vocabulary](../lib/io.slc), whereas `io` is Lua's existing library.
A project might provide `model.slc` or `model/init.slc` beside its entry file.
Module names use dots for subdirectories, just as Lua module names do.

## Search and execution

1. Lua checks its current `package.loaded` table.
2. The host's existing `package.loaders` run in their existing order. This keeps
   preload, ordinary Lua source, native modules and custom searchers working.
3. An appended searcher handles SLC source. For `slc.name`, it first checks
   `lib/name.slc` and `lib/name/init.slc` beside the compiler. Then it checks
   templates from the current `package.path`, replacing a final `.lua` with
   `.slc`. Each `?` is replaced by the slash-separated module name.

The entry program's directory contributes `?.lua` and `?/init.lua` at the front
of `package.path` during compilation. Lookup is relative to that entry and the
configured paths, not an implicit change of working directory for every module.
Custom path templates not ending in `.lua` stay with their existing loader;
there is no new module-path configuration language.

The SLC searcher translates a found source, loads the resulting Lua chunk, and
sets its environment to the SLC prelude. Lua's require machinery calls that
chunk, passing the module name. Normal Lua modules retain their normal Lua
loader and environment, and can themselves `require` SLC modules.

A found but invalid module fails immediately. Missing-file diagnostics list SLC
candidates alongside the existing Lua loader diagnostics. No syntax/evaluation
error silently falls through to a second implementation.

## Caching and compilation lifetime

A process can compile several programs. SLC modules can contain words, types,
extern descriptors and specialization caches tied to one compilation. Caching
those values globally would let a later program reuse an earlier program's state.
Clearing only `.slc` entries is insufficient: a Lua wrapper can retain them too.

The compiler therefore scopes **Lua's existing cache**, rather than implementing
another one:

- Before compilation, copy the host's loaded table into a fresh table. Install it
  as both `package.loaded` and the registry's `_LOADED` table used by native LuaJIT
  `require`.
- Existing host modules retain their identity. Every newly loaded module—Lua,
  SLC or native—is cached in that compilation's table.
- Use scoped copies of the loader and preload tables, and a scoped source path.
- Restore the host's loaded, loader and preload tables and source/native paths
  on success or failure, including translation errors and `no_c`/dump modes.

Compiler implementation modules are loaded before entering this scope. Their
registration hooks and native-backend state have host lifetime; library-word
caches in those modules must still be scoped to the compilation. Text methods
now look up their vocabulary through `require` instead of retaining it forever.

Lua's rules apply without reinterpretation: no returned value yields `true`
unless the loader published a value in `package.loaded`; `false` does not suppress
a subsequent reload; cycles and previous loader failures use LuaJIT's usual
error sentinel. Clearing that cache entry allows the usual explicit retry.

This is **not a sandbox**. Existing host module tables are shared, not deeply
copied. Explicit writes to host globals, FFI declarations, C-library process
state and external effects are not undone. Concurrent or nested compilation is
not supported by the single-context staging engine; nested entry is rejected
before resetting its state. Returned residual IR/native artifacts remain usable;
this does not introduce a new API for evaluating old staged words after their
compilation has ended.

## Tests

```sh
make test-modules
make test
make test-native
```

[Module tests](../tests/modules.lua) cover normal Lua/FFI dependencies, namespaces,
project modules, package initializers, Lua-source/preload precedence, return
values, explicit cache publication, repeated compilation, transitive Lua wrappers,
cycles, error recovery, nested-entry rejection and host-state restoration.
The ordinary example suite exercises internal compiler requests for bundled
libraries through the same loading mechanism on C and JIT paths.
