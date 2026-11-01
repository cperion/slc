# Formatting SLC

`slc fmt` keeps SLC's word-oriented style without treating it as ordinary Lua.
It uses the compiler's parser and the lossless lexer; it does not execute the
source or resolve imports. The one annotation it removes is a repeated
constructor type (see `type_style`). It also removes unused names from opened
`do` parameters (see `opening_style`).

## Commands

Run from the project root with LuaJIT and LPeg on the loader paths, as described
in the [README](../README.md#requirements):

```sh
luajit slc.lua fmt program.slc                  # formatted source on stdout
luajit slc.lua fmt -                            # stdin to stdout (also the default)
luajit slc.lua fmt --check examples/*.slc        # CI: report files needing formatting
luajit slc.lua fmt --write program.slc lib/*.slc # explicitly update these files
luajit slc.lua fmt --config path/to/style.lua program.slc
```

There is no implicit repository-wide rewrite. Stdout mode takes one input;
`--check` and `--write` accept several files. Shell globs select files; the
formatter does not recursively discover sources. Use `--` before filenames
that begin with a dash. Stdin cannot be combined with `--write` or other inputs.

Exit status is **0** on success, **1** when `--check` finds differences, and **2**
for a syntax, configuration, usage, or I/O error. Check mode never writes source.
Write mode parses and formats every input before changing any file, so a bad
input does not leave an earlier input reformatted. Filesystem write failures
can still interrupt the subsequent writes; this is not a multi-file transaction.

## Settings

No configuration file is required. These are the defaults:

```lua
-- .slcfmt.lua
return {
    indent_width = 4,
    column_width = 100,
    call_style = "minimal",
    spine_style = "pure",
    type_style = "inferred",
    table_style = "shorthand",
    opening_style = "anonymous",
}
```

The nearest `.slcfmt.lua` is found by walking upward from each input's directory.
For stdin, the search starts at the working directory. `--config` selects one
file for all inputs instead. Settings not specified use the defaults; configurations
are not merged with parent directories. The configuration must return a table;
it runs without standard-library or process globals. Use a trusted configuration
file, not arbitrary downloaded Lua code.

| Setting | Values | Meaning |
|---|---|---|
| `indent_width` | integer 1–8 | Spaces per block or continued delimited list. |
| `column_width` | integer 20–240 | Soft wrapping target, not a hard limit. |
| `call_style` | `"minimal"`, `"preserve"` | Remove safe call parentheses (and fold a spine's closers), or retain call spelling. |
| `type_style` | `"inferred"`, `"preserve"` | Drop a local's annotation when its initializer is an application of that same type (below), or keep every annotation. |
| `table_style` | `"shorthand"`, `"preserve"` | `"shorthand"` writes a table entry `name = name` as `.name` (syntax §2.4); `"preserve"` keeps the spelling, including any `.name` already written. |
| `opening_style` | `"anonymous"`, `"preserve"` | Remove an unused name from an opened `do` parameter, or keep named openings. |
| `spine_style` | `"pure"`, `"all"`, `"none"` | Which link bodies of an `endall` spine lose their indent. |

Unknown settings and invalid values are errors, not silently ignored options.

## Inferred types

A native local takes its type from its initializer (syntax §5.1), so
`local p: Point = Point { x = 1 }` repeats itself. With `type_style = "inferred"`
the annotation is removed when the initializer is exactly an application of the
annotated type expression:

```lua
local p: Point = Point { x = 1 }          -- local p = Point { x = 1 }
local count: U32 = U32(0)                 -- local count = U32 0
local out: Grow U32 = (Grow U32) {}       -- local out = (Grow U32) {}
```

It is also removed when the initializer is a name whose declared type is the same
bare type name: a typed parameter, an earlier annotated local, a numeric `for`
variable, or a local initialized by a constructor. The name must resolve to that
declaration (scopes and shadowing are followed), and `Str` and `Text` are never
dropped.

```lua
local f = do(n: U32): U32
    local i: U32 = n                      -- local i = n
    local j: U32 = i                      -- local j = i
    return j
end
```

The formatter never evaluates the program, so it decides only what the syntax
shows. These keep their annotation: `local w: U64 = n` (a different type),
`local j: U32 = r` with `r: Ref U32` (a reference keeps write-through),
`local k: U64 = U64(n) + 1` (an expression, not the constructor itself),
`local z: U32 = 0` (a host number), `local q: U8 = U32 0` (a different type),
a name it cannot resolve to a typed declaration, and `for i: U32 = 1, n`. The rewrite is applied only when the reparsed program equals
the original with exactly those annotations removed.

## Anonymous openings

With `opening_style = "anonymous"`, the formatter writes an unused opened
parameter `do(ctx..)` as `do(..)`. A type annotation stays: `do(ctx..: T)` becomes
`do(..: T)`. Ordinary parameters and `local ctx..` declarations are not changed.

Only the parameter-name token is removed. Comments and strings are preserved;
mentions inside them, field names, and table keys are not uses of the parameter.
References, assignments, reopening the receiver, and captures in nested blocks
keep the name. The analysis is conservative: a nested reference also keeps the
name when an intervening binding might shadow it.

The formatter keeps the name if the block contains an anonymous-home read
(`(..)`) or refers to the internal `__home` binding, since introducing a home
could change that lookup. It also avoids conflicting `__home` parameters and
repeated parameter names that affect which argument is opened.
The candidate is reparsed and checked against exactly the intended parameter
change. Set `opening_style = "preserve"` to retain named openings.

## Default style

```lua
local Point = struct { x: U32, y: U32 }
local move = do(x: U32): U32
    local p = Point { x = x, y = 2 }
    local r = Ref p
    p.x = p.x + 1
    return r.x
end
```

- Spaces around operators and after commas/type colons; no spaces around member
  selection or a method colon. No trailing whitespace outside literal/comment text.
- A table entry `name = name` is written `.name` (`Point { .x, .y, z = 3 }`), per
  `table_style`; set it to `"preserve"` to keep the long form.
- Indentation follows parsed blocks and delimiters, including trailing lambdas,
  context openings and `endall`; `spine_style` decides how a spine's link bodies
  indent.
- Existing statement/application line boundaries stay in place, except that safe
  call rewrites join whitespace just inside removed argument delimiters, and a
  folded spine's run of closers becomes one `endall` line. Single-line blocks
  stay single-line; runs of empty lines become one empty line.
- Long delimited lists can wrap after commas. Long application chains, comments,
  and literals may exceed `column_width`: wrapping must not change application.
- Comments and literal contents retain their exact bytes. Long strings and long
  comments are not reindented internally. Whitespace line endings become LF;
  a shebang and literal/comment bytes are preserved. Nonempty output ends in LF.
- Inferred declarations stay inferred, and explicit annotations remain explicit.

With `call_style = "minimal"`, `Ref(h)` becomes `Ref h`, and a safe unary-call
chain such as `f(a)(b)` can become `f a b`. Unary call statements also use this
style: `consume(value)` becomes `consume value`. Whitespace just inside the call
delimiters can be joined, so multiline arguments and chains get the same treatment.
A sole `do` block argument also loses its call parentheses: `items:each(do(item)
... end)` becomes `items:each do(item) ... end`, even with a multiline body or a
next-line `do`. The block body's line boundaries remain intact.
Comments are not a blanket barrier: `f(--[[ note ]] x)` becomes
`f --[[ note ]] x`, and `f(x -- note` followed by a newline and `)` can become
`f x -- note`. Comment and literal bytes are preserved. Rewrites repeat until no
further safe removal is available; `call_style = "preserve"` retains the original
parentheses and argument line boundaries.

Minimal style also omits empty parentheses from named call **statements**:
`refresh()` becomes `refresh`, `screen.refresh()` becomes `screen.refresh`, and
`screen:refresh()` becomes `screen:refresh`. It never does this in a value or
return expression: `local result = refresh()` and `return refresh()` keep `()`.
`call_style = "preserve"` retains both explicit and already-bare spellings.
Reparsing prevents adjacent statements from becoming an argument chain; host
Lua postfix ambiguities are also kept delimited.

### Compiler-informed word applications

In typed bodies, minimal style also rewrites `add(x, y)` to `add x y` when the
callee is provably an SLC word. This uses the same non-executing application
analysis as staged code generation ([application.lua](<../slc/application.lua>)), rather than assuming
that every callable follows word saturation:

```lua
local add = do(a: U32, b: U32): U32 = a + b
local plus = add
local run = do(x: U32, y: U32): U32
    return plus(x, y)                     -- return plus x y
end
```

The facts come from the whole file without running it: local typed lambdas and
functions, immutable aliases, provably unsaturated partial applications, the
prelude's declared arities (`band`, `shl`, …), `extern` declarations with a
literal parameter list, and the words an imported SLC module exports
(`local stacks = require "slc.stacks"` makes `stacks.span(s, at, n)` a word
call). Modules are found the way compilation finds them and are parsed, never
executed; a Lua module on the path stays unknown. Scopes, shadowing, opened
contexts and later writes invalidate a fact; method callees remain unknown.

A word gets every group as one supply; a function with a declared arity takes
groups up to that arity, so only calls within it are regrouped. Host call sites
keep their multi-argument groups.

A compound argument becomes a spaced group (syntax §2.4, rule 3):

```lua
f(x + 1, y)            -- f (x + 1) y
place(s, fresh + out)  -- place s (fresh + out)
f(g(x), y)             -- f (g x) y      when g is a word
f(x, "s")              -- f x ("s")      a name's chain would take the string
```

A call in the middle of the supply is regrouped only when it is a word (one
value); spreads, explicit `call` boundaries, overapplication and postfix results
(`f(x, y).value`) keep their groups. A group whose arguments sit on several
lines is joined only when the call then fits `column_width`.

Decisions are made once per round from the syntax tree, innermost first, and
the whole round is verified with one reparse. If it does not verify, each
application chain is accepted only if it verifies on its own.

## Trailing-block spines

A spine is a stack of calls whose bodies are the next call, closed by one
`endall`:

```lua
    counted stats do
    counted stats do
    transaction document do(draft..)
        insert n
    endall
```

`spine_style` decides how the link bodies indent:

| Value | Behaviour |
|---|---|
| `"pure"` (default) | A link whose body is exactly the next trailing call keeps that call aligned with its opener; any other body indents once. |
| `"all"` | Every link body loses its indent; only the innermost body indents. |
| `"none"` | Every link body indents, so the spine reads as nested blocks. |

`endall` always sits where the innermost `end` would: aligned with the last
opener of the chain, so a flat spine closes at its base and a nested spine closes
at its innermost level. With `call_style = "minimal"`, a run of `end`s that
closes a spine inside a typed body folds into one `endall`; a comment between
the closers blocks the fold, and host Lua keeps its `end`s because `endall` is a
typed-body form.

Formatting reparses candidate call rewrites and the final output and compares
syntax trees in the compiler's proven application normal form, ignoring source
positions and equivalent application spelling. Unknown call groups retain their
original structure.
A parse failure or a changed tree is an error; the input is not rewritten.
This check is not a type checker or a substitute for compiling the program.
Custom macro grammars outside the supported SLC/Lua forms are not interpreted by
the formatter and can be rejected rather than guessed at.

## Checks and embedding

```sh
make test-format
```

The tests cover golden output, comments/literals, call boundaries, `endall`,
configuration discovery, CLI status codes and failed-write preflight. They also
format every example/library twice and compare generated C before and after
formatting every example (ignoring diagnostic source-line changes).

From Lua:

```lua
local fmt = require 'slc.fmt'
local formatted = fmt.format(source, { indent_width = 2 }, "program.slc")
```

The library returns formatted text or raises an error. It does not search for
configuration files or read/write source files; that is the CLI's responsibility.
