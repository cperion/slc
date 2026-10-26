# SLC Tree-sitter highlighting for Neovim

This is an in-repository SLC editor parser, not the Lua parser with extra keywords.
It handles Lua host code and SLC's typed locals/functions, `do` lambdas, `struct`,
`export`, application, handlers, spread, opened parameters and `endall`.
Queries highlight keywords, types, functions, parameters, fields, literals and
comments. Native types are highlighted by spelling; this is not semantic type
resolution. The compiler remains the authority for valid programs.

## Build

From the SLC repository root:

```sh
make tree-sitter
make test-tree-sitter
```

Requirements: Tree-sitter CLI (tested with 0.26.11), Node.js, a C99 compiler,
GNU make, and Neovim 0.10 or newer (tested with 0.12.5). The build targets parser
ABI 14. The current build command targets Unix systems with shared-library
support; Windows is not tested. Override `TREE_SITTER`, `CC`, or `NVIM` if needed.

Generated sources and the parser library stay in `build/tree-sitter-slc/`.
Rebuild after changing the grammar or scanner, then restart Neovim to load the
new library. No npm dependency, downloaded Lua grammar, or compiler change is
needed.

## Neovim setup

Add this to your `init.lua`, replacing the checkout path:

```lua
local slc = vim.fn.expand('~/dev/slc') -- repository root containing Makefile
vim.opt.runtimepath:prepend(slc .. '/tools/tree-sitter-slc')
require('slc_treesitter').setup()
```

Or, with lazy.nvim:

```lua
{
  dir = vim.fn.expand('~/dev/slc/tools/tree-sitter-slc'),
  lazy = false,
  config = function()
    require('slc_treesitter').setup()
  end,
}
```

Use one setup, not both. Open a `*.slc` file: the filetype is `slc` and highlighting
starts automatically. The setup also sets `commentstring` to `-- %s`. Existing
`slc` buffers are attached when setup runs. Setup fails with a build instruction
if the parser library is missing; it does not silently fall back to Lua.

This uses Neovim's built-in Tree-sitter APIs and works without nvim-treesitter.
Do not add `slc` to nvim-treesitter's `ensure_installed`: this parser is local,
not registered in its upstream installer. Your existing Lua highlighting is
unchanged. You can provide a different compiled parser location explicitly:

```lua
require('slc_treesitter').setup({ parser = '/absolute/path/to/slc.so' })
```

Check `:set filetype?` and `:Inspect` to verify the filetype and highlight captures.
Colors come from your colorscheme's standard `@keyword`, `@type`, `@function`,
`@comment`, and other Tree-sitter highlight groups.

## Scope and checks

This is syntax highlighting, not an LSP, type checker, formatter, indentation
engine, or nvim-treesitter registry submission. The editor grammar deliberately
accepts some constructs that the compiler rejects (for example, non-place
assignment targets); a clean Tree-sitter parse does not establish compiler
acceptance.

`make test-tree-sitter` compiles with warnings as errors, parses every example
and library `.slc` file, checks highlight captures and filetype/startup integration
in headless Neovim, and compares incremental edits against fresh parses,
including incomplete source recovery. The test runs with `-u NONE` and does not
modify your Neovim configuration.

Grammar, scanner, queries, integration and tests use the project's
GPL-3.0-or-later terms; see [COPYING](../../COPYING).
