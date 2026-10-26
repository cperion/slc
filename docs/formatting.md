# Formatting SLC

`slc fmt` keeps SLC's word-oriented style without treating it as ordinary Lua.
It uses the compiler's parser and the lossless lexer; it does not execute the
source, resolve imports, or remove type annotations.

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
| `spine_style` | `"pure"`, `"all"`, `"none"` | Which link bodies of an `endall` spine lose their indent. |

Unknown settings and invalid values are errors, not silently ignored options.

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
- Indentation follows parsed blocks and delimiters, including trailing lambdas,
  context openings and `endall`; `spine_style` decides how a spine's link bodies
  indent.
- Existing statement/application line boundaries stay in place, except that a
  folded spine's run of closers becomes one `endall` line. Single-line blocks
  stay single-line; runs of empty lines become one empty line.
- Long delimited lists can wrap after commas. Long application chains, comments,
  and literals may exceed `column_width`: wrapping must not change application.
- Comments and literal contents retain their exact bytes. Long strings and long
  comments are not reindented internally. Whitespace line endings become LF;
  a shebang and literal/comment bytes are preserved. Nonempty output ends in LF.
- Inferred declarations stay inferred, and explicit annotations remain explicit.

With `call_style = "minimal"`, `Ref(h)` becomes `Ref h`, and a safe unary-call
chain such as `f(a)(b)` can become `f a b`. A sole `do` block argument also loses
its call parentheses when `do` is on the owning call's line: `items:each(do(item)
... end)` becomes `items:each do(item) ... end`, even with a multiline body.
Comments inside the block are preserved. A next-line `do` remains delimited;
`call_style = "preserve"` leaves the original parentheses intact.

Necessary grouping, empty calls, other commented argument lists and uncertain
rewrites remain delimited. In particular,
`f(a, b)` is **not** blindly changed to `f a b`: one two-argument host call is not
necessarily the same as two successive calls. Complex host-macro argument
rewrites are deliberately conservative, even when the native-body grammar would
permit them.

## Trailing-block spines

A spine is a stack of calls whose bodies are the next call, closed by one
`endall`:

```lua
    counted stats do
    counted stats do
    transaction document do(editing...)
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
syntax trees, ignoring only source positions and equivalent application spelling.
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
