# LuaMacro 2.5.0 (vendored)

Source: <https://github.com/stevedonovan/LuaMacro> (master branch)
Version: 2.5.0 (the `luam` usage banner)
Fetched: 2026-10-19 from
<https://codeload.github.com/stevedonovan/LuaMacro/tar.gz/refs/heads/master>
Archive SHA-256: `8c9ca9eba01364a26032f9ec34e86b489a52fe1f475bf463c43e181cfb3e4b14`

Vendored here (the run-time tree):

```
luam
macro.lua
macro/**/*.lua
readme.md
```

Not vendored because the experiment does not need them: `tests/`, `docgen`,
`docgen.bat`, `config.ld`.

Local changes: **`luam` only**; see [PATCHES.md](PATCHES.md). No other vendored
file is modified. The `macro/let.lua` module used by the experiment is project
code, not upstream, and lives in `tools/luamacro/macro/`.

## License

LuaMacro is distributed under the MIT/X11 license declared in `macro.lua`
(`@author Steve Donovan`, `@copyright 2011`, `@license MIT/X11`):

```
Copyright (c) 2011 Steve Donovan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

The LPeg Lua lexer in `macro/lexer.lua` is by Peter Odding (2007) and disclaims
copyright; its blessing is retained in the file.

The repository's own code remains under its WTFPL license; this notice does not
relicense the vendored source.

## Updating

Replace the vendored files with the desired upstream revision, reapply
[PATCHES.md](PATCHES.md) to `luam`, and run `make validate-luamacro`.
