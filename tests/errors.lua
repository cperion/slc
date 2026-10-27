-- each case: a program that must not compile, and part of the diagnostic
return {
    { name = 'known map rejects dynamic entries', expect = 'must be known',
      src = [[local f = do(k: U32): U32
    local m = Map.known(U32, U32, { { k, 1 } })
    return m.length
end
export f
]] },
    { name = 'known map indexing is not mutable', expect = 'immutable',
      src = [[local m = Map.known(U32, U32, { { 1, 10 } })
local f = do(): Unit
    m[1] = 20
end
export f
]] },
    { name = 'known map missing key fails during specialization', expect = 'map-key',
      src = [[local m = StrMap.known(U32, {})
local f = do(): U32 return m["missing"] end
export f
]] },
    { name = 'known map has no mutators', expect = 'immutable',
      src = [[local m = Map.known(U32, U32, {})
local f = do(): Unit m:put(1, 2) end
export f
]] },
    { name = 'inferred local keeps its native type', expect = 'expected U32',
      src = [[local f = do(x: U32): U32
    local y = x
    y = Bool true
    return y
end
export f
]] },
    { name = 'inferred resizable storage cannot be reassigned', expect = 'cannot be reassigned',
      src = [[local f = do(): U32
    local text = Text {}
    text = Text {}
    return text.length
end
export f
]] },
    { name = 'host rebinding in a residual loop stays forbidden', expect = 'cannot be rebound',
      src = [[local f = do(n: U32): U32
    local host_count = 0
    for i: U32 = 1, n do
        host_count = host_count + 1
    end
    return host_count
end
export f
]] },
    { name = 'floating map keys', expect = 'Map key must have fixed semantic equality',
      src = [[local M = Map(F64, U32)]] },
    { name = 'borrowed map values', expect = 'Map value must be fixed-size owned data',
      src = [[local M = Map(U32, Str)]] },
    { name = 'nested mutable maps', expect = 'Map value must be fixed-size owned data',
      src = [[local M = Map(U32, Map(U32, U32))]] },
    { name = 'a map created while compiling', expect = 'runtime storage',
      src = [[local M = Map(U32, U32)
local f = do(): U32
    local m: M = M {}
    return m.length
end
local n = host(f())
]] },
    { name = 'a map reassigned', expect = 'cannot be reassigned',
      src = [[local M = Map(U32, U32)
local f = do(): U32
    local m: M = M {}
    m = M {}
    return m.length
end
export f
]] },
    { name = 'a map passed by value', expect = 'passed as Ref',
      src = [[local M = Map(U32, U32)
local f = do(m: M): U32 = m.length
export f
]] },
    { name = 'signed overflow at compile time', line = 1, expect = 'signed overflow',
      src = [[local f = do(a: I32): I32 = a * 2
local x = f(2147483647)
]] },
    { name = 'division by zero at compile time', expect = 'division by zero',
      src = [[local f = do(a: U32, b: U32): U32 = a / b
local x = f(1, 0)
]] },
    { name = 'partial application with a dynamic argument', line = 3, expect = 'not static',
      src = [[local add = do(a: U32, b: U32, c: U32): U32 = a + b + c
local g = do(x: U32): U32
    local h = add(x)
    return h(1, 2)
end
export g
]] },
    { name = 'typed parameters without a result type', expect = 'need a result type',
      src = [[local f = do(x: U32) = x + 1
]] },
    { name = 'rebinding a host local in a dynamic branch', line = 4, expect = 'cannot be rebound',
      src = [[local f = do(flag: Bool, x: U32): U32
    local y = 1
    if flag then
        y = y * 2
    end
    return y
end
export f
]] },
    { name = 'assigning a parameter', expect = 'parameters are immutable',
      src = [[local f = do(x: U32): U32
    x = x + 1
    return x
end
export f
]] },
    { name = 'assigning outside the typed body', expect = 'can only assign bindings it declares',
      src = [[local count = 0
local f = do(x: U32): U32
    count = count + 1
    return x
end
]] },
    { name = 'mismatched operand types', expect = 'convert one explicitly',
      src = [[local f = do(a: U32, b: I32): U32 = a + b
export f
]] },
    { name = 'literal out of range', expect = 'does not fit in U8',
      src = [[local f = do(a: U8): U8 = a + 300
export f
]] },
    { name = 'nonterminating specialization under known control', expect = 'does not terminate',
      src = [[local function up(k: U32): U32
    return up(k + 1) + 1
end
local g = do(x: U32): U32 = up(0) + x
export g
]] },
    { name = 'missing return', line = 6, expect = 'without returning',
      src = [[local f = do(flag: Bool): U32
    if flag then
        return 1
    end
end
export f
]] },
    { name = 'dynamic bound in a generation-time loop', expect = 'bounds must be known',
      src = [[local f = do(n: U32): U32
    local t: U32 = 0
    for i = 1, n do
        t = t + 1
    end
    return t
end
export f
]] },
    { name = 'non-Bool native condition', expect = 'must be Bool',
      src = [[local f = do(n: U32): U32
    if n then
        return 1
    end
    return 0
end
export f
]] },
    { name = 'reading an uninitialized typed local', line = 3, expect = 'read before it is written',
      src = [[local f = do(n: U32): U32
    local t: U32
    return t + n
end
export f
]] },
    { name = 'compile-time call of a foreign effect', expect = 'cannot evaluate at compile time',
      src = [[local p = extern("p", { U32 }, Unit)
local f = do(x: U32): Unit
    p(x)
end
f(3)
]] },
    { name = 'reference stored in a struct', expect = 'cannot be stored in aggregates',
      src = [[local S = struct { r: Ref U32 }
]] },
    { name = 'a store assigned after creation', expect = 'cannot be reassigned',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): U32
    local s: Store N = Store(N) {}
    s = Store(N) {}
    return x
end
export f
]] },
    { name = 'a store passed by value', expect = 'passed as Ref',
      src = [[local N = struct { v: U32 }
local f = do(s: Store N): U32 = 1
]] },
    { name = 'a store returned', expect = 'cannot be returned',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): Store N = x
]] },
    { name = 'a struct holding a store passed by value', expect = 'resizable values are passed as Ref',
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N }
local take = do(g: G): U32 = 1
]] },
    { name = 'a store copied', expect = 'moves only by reference',
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N }
local f = do(x: U32): U32
    local g: G = G { nodes = Store(N) {} }
    local h: G = g
    return x
end
export f
]] },
    { name = 'a store declared without being created', expect = 'created where it is declared',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): U32
    local s: Store N
    return x
end
export f
]] },
    { name = 'a resizable field that is not last', expect = 'must be the last field',
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N, count: U32 }
]] },
    { name = 'recursion that accumulates data stacks', expect = 'unbounded data stacks are rejected',
      src = [[local N = struct { v: U32 }
local function walk(n: U32): U32
    local s: Store N = Store(N) {}
    s:add(N { v = n })
    if n == 0 then
        return s.length
    end
    return walk(n - 1) + s.length
end
local g = do(n: U32): U32 = walk(n)
export g
]] },
    { name = 'returning a reference to a local', expect = 'returns a reference to its own local',
      src = [[local leak = do(x: U32): Ref U32
    local y: U32 = x
    return Ref(y)
end
local f = do(x: U32): U32
    local r = leak(x)
    return r
end
export f
]] },
    { name = 'a store created at compile time', expect = 'cannot be created at compile time',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): U32
    local s: Store N = Store(N) {}
    return x
end
local y = f(3)
]] },
    { name = 'an opened field colliding with a visible local', expect = 'spread-shadow',
      src = [[local E = struct { cursor: U32 }
local f = do(x: U32): U32
    local cursor: U32 = x
    local e: E = E { cursor = 1 }
    local e...
    return cursor
end
export f
]] },
    { name = 'a declaration shadowing an introduced name', expect = 'spread-shadow',
      src = [[local E = struct { cursor: U32 }
local f = do(x: U32): U32
    local e: E = E { cursor = x }
    local e...
    local cursor = 3
    return cursor
end
export f
]] },
    { name = 'two openings introducing the same name', expect = 'spread-shadow',
      src = [[local A = struct { n: U32 }
local B = struct { n: U32 }
local f = do(x: U32): U32
    local a: A = A { n = x }
    local b: B = B { n = x }
    local a...
    local b...
    return n
end
export f
]] },
    { name = 'two keyed spreads with a common field', expect = 'spread-overlap',
      src = [[local P = struct { x: U32, y: U32 }
local f = do(a: P, b: P): P = P { ...a, ...b, x = 1 }
export f
]] },
    { name = 'a keyed spread bringing an unknown field', expect = "has no field 'z'",
      src = [[local P = struct { x: U32 }
local Q = struct { x: U32, z: U32 }
local f = do(q: Q): P = P { ...q, z = 1 }
export f
]] },
    { name = 'a record spread into an ordered list', expect = 'spread-source',
      src = [[local P = struct { x: U32, y: U32 }
local add = do(a: U32, b: U32): U32 = a + b
local f = do(p: P): U32 = add(...p)
export f
]] },
    { name = 'a pack used as a value', expect = 'pack-use',
      src = [[local first = do(x: U32): U32 = x
local f = do(...xs): U32 = first(xs)
local g = do(a: U32): U32 = f(a)
export g
]] },
    { name = 'a pack index out of range', expect = 'pack-index',
      src = [[local f = do(...xs): U32 = xs[2]
local g = do(a: U32): U32 = f(a)
export g
]] },
    { name = 'a rest requirement that is not last', expect = 'rest-position',
      src = [[local f = do(...xs, y: U32): U32 = y
]] },
    { name = 'assigning an opened context', expect = 'context-use',
      src = [[local E = struct { n: U32 }
local f = do(x: U32): U32
    local e... = E { n = x }
    e = E { n = 1 }
    return n
end
export f
]] },
    { name = 'a compile-time parameter given a runtime value', expect = 'compile-time parameter',
      src = [[local pick = do(k, x: U32): U32 = x
local f = do(x: U32): U32 = pick(x, x)
export f
]] },
    { name = 'reading the home where none is opened', expect = 'context-required',
      src = [[local f = do(x: U32): U32
    return (...)
end
]] },
    { name = 'a match missing an alternative', expect = "alternative 'dot' has no handler",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v }
export f
]] },
    { name = 'a match handling an unknown alternative', expect = "no alternative 'nope' to handle",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = 0, nope() = 1 }
export f
]] },
    { name = 'a match missing an alternative, even with a known tag', expect = 'has no handler',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(x: U32): U32 = S.num(x) { num(v) = v }
export f
]] },
    { name = 'a duplicate handler', expect = "duplicate key 'num'",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = 0, num(v) = 1 }
export f
]] },
    { name = 'handlers with different result types on a runtime tag', expect = 'expected Bool, got U32',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = true }
export f
]] },
    { name = 'selecting a payload by name', expect = 'reached by matching',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s.num
export f
]] },
    { name = 'a payload for a Unit alternative', expect = 'takes no payload',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(x: U32): S = S.dot(x)
export f
]] },
    { name = 'a reference in an alternative', expect = 'holds a reference',
      src = [[local Node = struct { v: U32 }
local Link = oneof { none: Unit, some: Ref Node }
]] },
    { name = 'an empty oneof', expect = 'at least one named alternative',
      src = [[local Never = oneof { }
]] },
    { name = 'a known index outside a known length', expect = 'index-range',
      src = [[local f = do(b: Slice U8): U32
    local h = b:sub(0, 4)
    return U32(h[4])
end
export f
]] },
    { name = 'writing through a slice', expect = 'not-a-place',
      src = [[local f = do(b: Slice U8): Unit
    b[0] = 1
end
export f
]] },
    { name = 'pointer arithmetic', expect = 'not defined for Ptr U8',
      src = [[local f = do(p: Ptr U8): Ptr U8 = p + 1
export f
]] },
    { name = 'ordering pointers', expect = 'ordering is not offered',
      src = [[local f = do(p: Ptr U8, q: Ptr U8): Bool = p < q
export f
]] },
    { name = 'a pointer made a reference', expect = 'cannot become a checked borrow',
      src = [[local f = do(p: Ptr U32): U32
    local r = Ref(p)
    return 0
end
export f
]] },
    { name = 'pushing onto a Grow while it is viewed', expect = 'is borrowed',
      src = [[local f = do(n: U32): U32
    local g: Grow U32 = (Grow U32) {}
    g:push(n)
    return g:view() do(xs)
        g:push(1)
        return xs.length
    end
end
export f
]] },
    { name = 'a view outliving its view', expect = 'cannot outlive its view',
      src = [[local f = do(n: U32): U32
    local g: Grow U32 = (Grow U32) {}
    g:push(n)
    local xs = g:view() do(v) return v end
    return 0
end
export f
]] },
    { name = 'a slice stored in a struct', expect = 'borrows cannot be stored',
      src = [[local S = struct { bytes: Slice U8 }
]] },
    { name = 'a signed index', expect = 'must be an unsigned integer',
      src = [[local f = do(p: Ptr U8, i: I32): U8 = p[i]
export f
]] },
    { name = 'an opaque type held by value', expect = 'hold it as Ptr FILE',
      src = [[local FILE = opaque "FILE"
local S = struct { f: FILE }
]] },
    { name = 'a variadic argument that is a record', expect = 'must be a native scalar',
      src = [[local printf = extern("printf", { CString }, I32, { header = "<stdio.h>", variadic = true })
local P = struct { x: U32 }
local f = do(x: U32): Unit
    printf("%u", P { x = x })
end
export f
]] },
    { name = 'a CString from a number', expect = 'expected a CString',
      src = [[local puts = extern("puts", { CString }, I32, { header = "<stdio.h>" })
local f = do(x: U32): Unit
    puts(3)
end
export f
]] },
    { name = 'a foreign struct without a header', expect = 'a header such as',
      src = [[local Stat = cstruct("struct stat", nil, { { "size", I64, "st_size" } })
]] },
    { name = 'activity parameter shadowing its own field', expect = 'spread-shadow',
      src = [[local Fd = struct { fd: I32 }
local with = do(body): I32
    local f: Fd = Fd { fd = 3 }
    body(Ref(f))
    return 0
end
local g = do(x: I32): I32
    with do(fd...)
        local y = fd
    end
    return x
end
export g
]] },
    { name = 'reading an atomic plainly', expect = 'is read with :load()',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n
export f
]] },
    { name = 'writing an atomic plainly', expect = 'is written with :store(v)',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    c.n = 3
end
export f
]] },
    { name = 'a load with release order', expect = "memory order 'release' is not valid",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n:load("release")
export f
]] },
    { name = 'a store with acquire order', expect = "memory order 'acquire' is not valid",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    c.n:store(1, "acquire")
end
export f
]] },
    { name = 'an unknown memory order', expect = "unknown memory order 'strong'",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n:add(1, "strong")
export f
]] },
    { name = 'an atomic passed by value', expect = 'shared through Ref, never copied',
      src = [[local f = do(n: Atomic U32): U32 = 0
]] },
    { name = 'copying a struct holding an atomic', expect = 'is read with :load()',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    local d: C = c
end
export f
]] },
    { name = 'add on an atomic Bool', expect = 'offers load, store, exchange, cas;',
      src = [[local L = struct { held: Atomic Bool }
local f = do(l: Ref L): Bool = l.held:add(true)
export f
]] },
    { name = 'an atomic struct', expect = 'Atomic holds an integer, a Bool or a pointer',
      src = [[local P = struct { x: U32 }
local A = Atomic P
]] },
    { name = 'a task assigning a copy', expect = "'total' is a copy taken at spawn; a task cannot assign it", line = 4,
      src = [[local f = do(n: U32): U64
    local total: U64 = 0
    local bump = do(c: Chan U32): Unit
        total = total + 1
    end
    tasks do(scope...)
        spawn(bump, channel(U32, 1))
    end
    return total
end
export f
]] },
    { name = 'a spawned block assigning a copy', expect = "'count' is a copy taken at spawn", line = 5,
      src = [[local f = do(n: U32): U32
    local count: U32 = 0
    tasks do(scope...)
        spawn do
            count = count + 1
        end
    end
    return count
end
export f
]] },
    { name = 'a spawned block mentioning a reference', expect = "a task shares no memory: the outside value 'c' is a Ref C",
      src = [[local C = struct { n: U32 }
local f = do(c: Ref C): Unit
    tasks do(scope...)
        spawn do
            local m: U32 = c.n
        end
    end
end
export f
]] },
    { name = 'a wait inside recursion in a task', expect = 'a task cannot suspend inside it',
      src = [[local walk
walk = do(c: Chan U32, depth: U32): U32
    if depth == 0 then
        c:send(1)
        return 1
    end
    return walk(c, depth - 1) + walk(c, depth - 1)
end
local f = do(d: U32): Unit
    tasks do(scope...)
        local c = channel(U32, 64)
        spawn do
            local n: U32 = walk(c, d)
        end
    end
end
export f
]] },
    { name = 'first_of closed without a receive', expect = '`closed` runs when every received channel is closed, but no case receives',
      src = [[local f = do(c: Chan U32): Unit
    first_of { send(c, 1) do end, closed = do end }
end
export f
]] },
    { name = 'spawning with a reference', expect = "spawn: parameter 'c' of bump is a Ref C; a task shares no memory",
      src = [[local C = struct { n: U32 }
local bump = do(c: Ref C): Unit
    c.n = c.n + 1
end
local f = do(c: Ref C): Unit
    tasks do(scope...)
        spawn(bump, c)
    end
end
export f
]] },
    { name = 'a channel of pointers', expect = 'Chan Ptr U8: values crossing a channel are copies',
      src = [[local f = do(c: Chan (Ptr U8)): Unit
end
]] },
    { name = 'a channel of records holding a pointer', expect = "its field 'p' is a Ptr U8",
      src = [[local M = struct { p: Ptr U8 }
local f = do(c: Chan M): Unit
end
]] },
    { name = 'a task with a result', expect = "a task's result goes nowhere; send it on a channel",
      src = [[local g = do(n: U32): U32 = n + 1
local f = do(n: U32): Unit
    tasks do(scope...)
        spawn(g, n)
    end
end
export f
]] },
    { name = 'a channel leaving its scope', expect = 'a channel cannot leave its tasks scope',
      src = [[local f = do(): Unit
    local c = tasks do(scope...)
        return channel(U32, 1)
    end
end
export f
]] },
    { name = 'a first_of that cannot end', expect = 'first_of: when every channel is closed',
      src = [[local f = do(c: Chan U32): Unit
    first_of { recv(c) do(v) end }
end
export f
]] },
    { name = 'a receive missing a handler', expect = "alternative 'closed' has no handler",
      src = [[local f = do(c: Chan U32): U32
    local r: U32 = 0
    c:recv() { value = do(v) r = v end }
    return r
end
export f
]] },
    { name = 'spawning something that is not a word', expect = 'spawn: expects a block (spawn do ... end) or a typed word',
      src = [[local f = do(n: U32): Unit
    tasks do(scope...)
        spawn(42, n)
    end
end
export f
]] },
    { name = 'a channel unknown method', expect = "Chan U32 offers send, recv, close, each; not 'push'",
      src = [[local f = do(c: Chan U32): Unit
    c:push(1)
end
export f
]] },
    { name = 'a known index outside an array', expect = 'index-range: index 4 is outside an array of length 4', line = 3,
      src = [[local f = do(): U32
    local a: Array(U32, 4)
    return a[4]
end
export f
]] },
    { name = 'an empty array type', expect = 'n must be a positive integer known while compiling',
      src = [[local A = Array(U32, 0)
]] },
    { name = 'an array of references', expect = 'Array holds fixed-size values, not Ref U32',
      src = [[local A = Array(Ref(U32), 4)
]] },
    { name = 'an array literal of the wrong length', expect = 'Array(U8, 3) { ... } lists 3 elements, got 2',
      src = [[local f = do(): U8
    local a: Array(U8, 3) = Array(U8, 3) { 1, 2 }
    return a[0]
end
export f
]] },
    { name = 'a slot used after it was sent', expect = 'this slot was sent at', line = 8,
      src = [[local B = struct { n: U32 }
local f = do(): Unit
    tasks do(scope...)
        local p = pool(B, 2)
        local c = channel(Slot B, 2)
        local s = p:take()
        c:send(s)
        p[s].n = 1
    end
end
export f
]] },
    { name = 'a slot released twice', expect = 'this slot was released at',
      src = [[local B = struct { n: U32 }
local f = do(): Unit
    tasks do(scope...)
        local p = pool(B, 2)
        local s = p:take()
        p:release(s)
        p:release(s)
    end
end
export f
]] },
    { name = 'a pool of pointers', expect = 'Pool Ptr U8: slots move between tasks',
      src = [[local f = do(p: Pool (Ptr U8)): Unit
end
]] },
    { name = 'a slot inside a oneof on a channel', expect = 'a Slot inside a oneof cannot move',
      src = [[local B = struct { n: U32 }
local M = oneof { buf: Slot B, none: Unit }
local f = do(c: Chan M): Unit
end
]] },
    { name = 'reading a slot directly', expect = 'is a handle: its contents are addressed through its pool, pool[slot]',
      src = [[local B = struct { n: U32 }
local f = do(s: Slot B): U32 = s.n
export f
]] },
    { name = 'I/O as a case of first_of', expect = 'I/O cannot lose a first_of: give io.read a deadline',
      src = [[local io = require "slc.io"
local f = do(c: Chan U32, file: io.File): Unit
    local buf: Array(U8, 8)
    first_of {
        recv(c) do(v) end,
        io.read(file, buf) do(n) end,
        closed = do end,
    }
end
export f
]] },
    { name = 'a read larger than its buffer', expect = 'io.read: 16 bytes do not fit a buffer of 8',
      src = [[local io = require "slc.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 16) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a read into something that is not a byte array', expect = 'io.read needs an Array(U8, N) to fill',
      src = [[local io = require "slc.io"
local f = do(file: io.File): Unit
    local n: U32 = 0
    io.read(file, n) { done = do(k) end, failed = do(e) end }
end
export f
]] },
    { name = 'an unknown I/O option', expect = "io.read: unknown option 'timeout'",
      src = [[local io = require "slc.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 8, { timeout = ms(5) }) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a timed read matched without timed_out', expect = "alternative 'timed_out' has no handler",
      src = [[local io = require "slc.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 8, { deadline = ms(5) }) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a store addressed with the wrong key', expect = 'Id: expected Id N, got U32',
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N }
local f = do(g: Ref G, k: U32): U32 = g.nodes[k].v
export f
]] },
    { name = 'a wait inside a blocking block', expect = 'a blocking block runs outside the scheduler: it cannot wait (send)',
      src = [[local f = do(): Unit
    tasks do(scope...)
        local c = channel(U32, 1)
        spawn do
            blocking do
                c:send(1)
            end
        end
    end
end
export f
]] },
    { name = 'an operator hook written as a method', expect = '__add is a hook, not a method',
      src = [[local N = struct { v: U32 }
function N:__add(other: N): N
    return N { v = self.v + other.v }
end
local f = do(a: N, b: N): N = a + b
export f
]] },
    { name = 'call before something that is not an application', expect = 'call needs an application',
      src = [[local f = do(x: U32): U32
    local y = call x
    return y
end
export f
]] },
    { name = 'call on an untyped Lua function', expect = 'call needs a native word',
      src = [[local twice = do(x) return x end
local f = do(x: U32): U32
    return call twice(x)
end
export f
]] },
    { name = 'text compared with ==', expect = 'text is compared with words, not operators',
      src = [[local f = do(a: Str): Bool = a == "x"
export f
]] },
    { name = 'a known index outside known text', expect = 'index-range: index 3 is outside text of length 3',
      src = [[local f = do(): U8
    local s: Str = "abc"
    return s[3]
end
export f
]] },
    { name = 'known text longer than its Chars(n)', expect = 'Chars(2) holds 2 bytes; this text has 3',
      src = [[local f = do(): U32
    local c: Chars(2) = Chars(2)("abc")
    return c.length
end
export f
]] },
    { name = 'a separator of two bytes', expect = 'split: the separator is one byte',
      src = [[local f = do(s: Str): Unit
    s:split(", ") do(p) end
end
export f
]] },
    { name = 'a Str stored in a struct', expect = "field 's' is a Str, a view of someone else's bytes",
      src = [[local Holder = struct { s: Str }
]] },
    { name = 'Chars overflow on the known word path', expect = 'Chars(4) holds 4 bytes; this text has 5',
      src = [[local f = do(s: Str): U32
    local c: Chars(4) = Chars(4)(s)
    return c.length
end
assert(host(f("abcde")) == 5)
]] },
    { name = 'raw array address is still a runtime boundary', expect = 'cannot evaluate at compile time',
      src = [[local f = do(): U8
    local c: Chars(4) = Chars(4)("abc")
    local p = Ptr(c.bytes)
    return p[0][0]
end
host(f())
]] },
}
