# Working on SLC

SLC is an independent Lua-hosted specializing compiler. It is not ABC or Let's VM,
and their implementation constraints do not apply here.

## Authorities and workflow

- Start from the user's request, the current source and tests.
- `docs/syntax.md` owns language/ABI contracts; `docs/architecture.md` owns the
  compiler, the runtime and the SLC/Lua/C boundary; `docs/designing-and-writing-slc.md`
  explains programming style. Distinguish intended semantics, implementation behavior
  and freshly observed evidence.
- Inspect before editing. Discuss material semantic/architectural changes and obtain
  approval before implementation. Do not silently add fallbacks or compatibility paths.
- Keep changes focused. Preserve unrelated work and raw experimental evidence.
- Do not delegate to other agents unless the user requests it.

## Version control

Use colocated jj/Git, with jj for history and bookmark mutations. Check `jj status`,
`jj log` and the relevant diff first. Describe coherent changes before editing;
review the final diff and run relevant checks before completing a change.
The local integration bookmark is `master`. Do not create remotes or push without
explicit authorization. Keep both tool identities consistent; do not rewrite others'
authorship or published history.

## SLC source style

- Use inferred local types where the initializer makes the type clear; keep type
  annotations where the native contract or numeric width needs them.
- Aggressively prefer same-line, parenthesis-free calls where the grammar permits
  them: `Ref h`, `U64 value`, `round h`, `hash.init k0 k1`. This applies beyond
  unary calls. Keep parentheses only for required grouping or disambiguation;
  do not mechanically write Lua/C-style call parentheses in SLC code.

## Architecture

- **SLC-first, consistently across all features.** Implement every expressible
  feature and library algorithm in ordinary SLC words, so it specializes and
  residualizes with the calling program. This applies to existing features as
  well as new ones; compiler-side Lua and generated C are not the default place
  for library behavior. "Runtime" describes when an operation executes, not
  which language implements it: SLC runtime algorithms must be able to fold,
  specialize and residualize together with the program. Thin SLC wrappers around
  opaque C algorithms do not meet this requirement.
- Lua supplies type construction, host metaprogramming and the minimal compiler
  primitives. Keep C limited to genuinely necessary runtime/platform mechanisms.
  Do not hide an expressible algorithm in C or Lua merely because that is easier
  to implement. Backend inlining is not a substitute for SLC specialization.
- When a feature cannot yet be expressed in SLC, identify the precise missing
  primitive and add the smallest general capability needed; do not grow a
  feature-specific compiler subsystem. Review older features against this rule
  as they are touched. Correct architectural drift before extending it.
- Prioritize language design and implementation. Use focused checks while
  developing; do not repeatedly run broad validation campaigns instead of making
  feature progress. Run the relevant acceptance checks at coherent milestones.
- Work in substantial, end-to-end feature milestones, not one-helper migrations.
  Keep small implementation steps internal; do not stop for a report, checkpoint,
  or repeated C/JIT campaign after each helper. Complete a coherent subsystem
  before milestone validation/reporting, unless a concrete blocker or a material
  user-owned decision requires interruption.

- Lua supplies host values, closures and generators. Native types determine native
  semantics; knownness determines binding time.
- Saturated words evaluate in place. Function boundaries, effects, mutation and
  generalization must follow the specification, not backend-specific guesses.
- Goose storage and task/channel/slot contracts apply to the residual program.
  Preserve checks, lifetimes, ownership transfers and foreign-boundary behavior.
- C and libgccjit use the same prepared IR. Do not duplicate language semantics,
  runtime algorithms or helper definitions between backends.
- The macro engine is ordinary source in `macro.lua` and `macro/`, with SLC's
  extensions in `macro/let.lua` and `macro/slc.lua`. Do not restore a runtime bundle
  bootstrap or edit generated bundles as the source of truth.
- Preserve LuaMacro/lexer attribution and notices. Follow the incoming prototype's
  GPL-3.0-or-later terms and the runtime's GCC Runtime Library Exception 3.1;
  `COPYING`, `COPYING.RUNTIME` and `THIRD_PARTY.md` record them. Do not invent or
  silently change licensing terms.

## Checks and artifacts

`make doctor`, `make test-macros`, `make test`, and `make test-native` are the project
entry points. `tests/run.lua` also exercises supported C/JIT backends, native harnesses,
rejection diagnostics, documentation listings and available sanitizer paths.

Report actual pass/fail/skip results. A missing library, unsupported I/O backend or
sanitizer environment is not proof of a compiler regression or a successful test.
Never silently turn failed acceptance checks into skips.

Keep generated C/objects/executables, dependency copies, caches and logs under
ignored `build/`, `.local/` or `.cache/`. Keep example source and fixtures tracked.
This project must not depend on paths inside the neighboring ABC repository.
