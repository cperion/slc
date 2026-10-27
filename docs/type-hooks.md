# Type hooks

The language contract is §41 of [the specification](staged-lua-c-v0.5.md); this
file is the implementation note.

A type can define what the language's operations mean on its values. Hooks are
Lua functions or native words stored on the type under `__`-names. They run while
specializing and return staged values, places or words, so whatever they build
folds and residualizes with the caller. This is the exotype idea (Terra, PLDI
2014) on slc's staging: layout is a `struct`; behavior is hooks.

| Hook | Runs for | Returns |
|---|---|---|
| `__member(x, name)` | `x.name`, `x:name(...)` | a value, place or word; `nil` falls back to fields, then methods |
| `__index(x, key)` | `x[key]` | a value or a place |
| `__newindex(x, key, v)` | `x[key] = v` | nothing |
| `__cast(v, T)` | a host value or other-typed value where a `T` is expected, and `T(v)` | a `T`, or `nil` to refuse |
| `__add` `__sub` `__mul` `__div` `__mod` `__unm` | arithmetic | a `T`; the other operand is first converted through `__cast` |
| `__eq` `__lt` `__le` | comparisons; `~=`, `>`, `>=` derive from them | a `Bool` |

While a type's hook runs, that type's hooks are not consulted again, so a hook
reads its own representation with ordinary field access. `rawmember(x, name)`
does the same outside a hook.

Comparisons are staged only in typed bodies (spec §6.2, §7), so a hook that
compares is a native word. Assignment to a native field or element works in plain
Lua code too (`w.items[k] = v`):

```lua
function Fixed.__lt(a: Fixed, b: Fixed): Bool
    return a.raw < b.raw
end
```

A hook that only builds values or chooses words can be an untyped Lua function.

Every built-in member lookup goes through these hooks. `Str`, `Chars(n)`, and
the Store, Grow, Map and StrMap `x[k]` places register on their types; `Ptr`,
`Slice`, `Atomic`, `Chan`, `Array`, `Pool` and `Slot` register per family in
`S.family_hooks`; types with computed `properties` and `builtin_methods` (Store,
Grow, Map, StrMap, the program arguments) serve them through `S.member_tables`.
`raw_member` is left with only sums, struct fields and methods. A Lua string converted to `Str` is `Str.__cast`.
`examples/user_types.slc` defines a fixed-point number and a ring window with
the same hooks.

`examples/ring.slc` is a bounded ring buffer written purely as a library: a
struct with a `Grow`, methods, and a typed `__index` hook that returns a `Ref`.

Not yet routed: `coerce` for the built-in kinds and struct fields and methods
themselves (the `raw_member` default).
