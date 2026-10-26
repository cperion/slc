-- The persistent contents model must not alias copies or expand zero arrays.
local A = require 'slc.array_value'
local equal = function(a, b) return a == b end
local t = { length = 1000000000 }
local zero = A.new(t, 0)
assert(zero.count == 0 and next(zero.items) == nil)
assert(A.get(zero, 999999999) == 0)
local a = A.set(zero, 999999999, 7)
local b = A.set(a, 0, 3)
assert(A.get(zero, 999999999) == 0)
assert(A.get(a, 0) == 0 and A.get(b, 0) == 3)
assert(a.count == 1 and b.count == 2)
local indices = A.indices(b)
assert(indices[1] == 0 and indices[2] == 999999999 and #indices == 2)
assert(A.equal(zero, A.set(zero, 5, 0), equal))
assert(not A.equal(a, b, equal))
assert(A.all(b, function(v) return type(v) == 'number' end))
assert(not A.all(b, function(v) return v > 0 end))
local small = { length = 2 }
assert(A.equal(A.new(small, 0, { [0] = 1, [1] = 2 }),
    A.new(small, 99, { [0] = 1, [1] = 2 }), equal))
local input = { [0] = 1 }
local copied = A.new(small, 0, input)
input[0] = 9
assert(A.get(copied, 0) == 1)
assert(not pcall(A.set, copied, 2, 3))
assert(not pcall(A.get, copied, -1))
print('immutable array contents: ok')
