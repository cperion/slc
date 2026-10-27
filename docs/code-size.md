# Tuning code size and compile time

slc evaluates a word's body in place wherever it is applied. That is what lets known
data fold away, and it is why a program that applies a large word at many sites gets
many copies of it. The C grows, and so does the time slc and the C compiler spend on
it. `call` puts a function boundary at one application, and `slc size` finds where.
This page is the loop for using them; the language rules are in
[spec §12.7](staged-lua-c-v0.5.md#127-call-a-function-boundary-at-one-site) and the
guide's [section 11.1](designing-and-writing-slc.md#111-tuning-code-size-and-compile-time).

## The loop

```sh
luajit slc.lua program.slc | wc -l                  # 1. how much C
time luajit slc.lua -o program.c program.slc        #    how long slc takes
time cc -O1 -c program.c                            #    how long the C compiler takes
luajit slc.lua size program.slc                     # 2. where it comes from
```

Edit one `call` in, then measure again. Keep it if it paid; revert it if it did not.
When the program compiles in a time you accept, stop.

A program over 20,000 lines of C prints a note on stderr pointing at `slc size`.

## Reading the report

```text
examples/strmaps.slc: 19,443 lines of C from 113 source lines (172x), 71 functions

largest functions
    1,190  uint32_t strmap_reserved_keys(void)
      910  uint32_t strmap_words(Str text)

words evaluated in place at several sites (what one `call` would share)
      saves   sites       each  word
      2,907      24        594  put  (./lib/map.slc:193)
      strmaps.slc:81  x7  6,842 statements   words:put(key, 1)
      strmaps.slc:7   x2  1,876 statements   words:ensure(word, 0)
```

* **largest functions** are the generated C functions by line count. One function that
  dominates is a user function that applies many large words.
* **saves** is the number of residual statements that one shared copy per
  specialization key would remove from the program. **sites** is how many times the
  word was applied in place, **each** how many statements one application adds.
* The lines under a word are its heaviest sites in your source, with the source text:
  these are the applications to put `call` before.
* Words whose application adds under 40 statements, or that save under 100, are left
  out: a call would cost as much as the copy.
* Figures count nested words inside the words that contain them. Act on the first
  entry, then run the report again.

## A worked example

`examples/maps.slc` began at 46,129 lines of C, 9.4 s in slc and 2.4 s in `cc -O1`.
`slc size` named, in order, the key digest, the probe, growth, insertion and the key
copy of `lib/map.slc`, then hash finalization and `put`. Each got a `call`, one at a
time, measuring after each and keeping it when the C shrank by a useful amount. It now
is 10,984 lines, 1.6 s in slc and 0.7 s in the C compiler. A 20-million-operation map
loop runs about 8% slower than with everything in place, which is the cost of a call
where there was none. `strmaps.slc` went from 61,846 to 16,292 lines and from 19.9 s to
1.6 s in slc.

The data-stack library had the same shape: growing a stack was inlined at every access.
Two `call`s in `lib/stacks.slc` took `stores` from 3,100 to 1,600 lines and `strings`
from 4,100 to 2,800.

## The runtime is in the count

A program's C carries the runtime words it reaches (spec §42.4). `hello` is 13 lines;
a program that waits on a channel carries the scheduler, about 5,000 lines in
`channels.slc`. `first_of` is a shared function per shape of select, not a copy per use.
A program that never waits carries none of that, so a size surprise in a program with
tasks is usually the program, not the runtime.

## When not to use `call`

* **Hot paths.** Measure the run time of the loop that matters before and after. If it
  slows more than you accept, take the `call` back out, or leave it on the cold part
  only.
* **Small words.** The report will not list them. Do not add `call` to them by hand.
* **Known inputs you want folded.** Arguments known at the site are part of the
  function's key. A `call` with a known argument is a call to a function specialized
  on it, and is not folded away into the caller.

## Things that surprise

* A word containing `call` still runs at compile time on known inputs: `call` is
  ignored while evaluating at compile time, so `host(hash.sip24(...))` works.
* `return call f(x)` returns the call. It is not a tail jump.
* `call` needs a native word. An untyped Lua function is an error; a foreign function
  is already a call.
