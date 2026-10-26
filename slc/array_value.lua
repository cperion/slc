-- Immutable fixed-array contents, not storage. Indices are native (zero-based).
-- Missing elements share a typed zero/default value; updates copy only overrides.
local A = {}

function A.new(t, zero, items)
    local copy, count = {}, 0
    for i, v in pairs(items or {}) do
        assert(type(i) == 'number' and i == math.floor(i) and i >= 0 and i < t.length)
        copy[i], count = v, count + 1
    end
    return { T = t, zero = zero, items = copy, count = count }
end

function A.get(a, i)
    assert(i >= 0 and i < a.T.length and i == math.floor(i))
    local v = a.items[i]
    if v ~= nil then return v end
    return a.zero
end

function A.set(a, i, v)
    assert(i >= 0 and i < a.T.length and i == math.floor(i) and v ~= nil)
    local items = {}
    for k, x in pairs(a.items) do items[k] = x end
    items[i] = v
    return A.new(a.T, a.zero, items)
end

function A.indices(a)
    local indices = {}
    for i in pairs(a.items) do indices[#indices + 1] = i end
    table.sort(indices)
    return indices
end

function A.all(a, predicate)
    if a.count < a.T.length and not predicate(a.zero) then return false end
    for _, v in pairs(a.items) do if not predicate(v) then return false end end
    return true
end

function A.equal(a, b, equal)
    if a == b then return true end
    if a.T ~= b.T then return false end
    local indices, count = {}, 0
    for i in pairs(a.items) do indices[i], count = true, count + 1 end
    for i in pairs(b.items) do if not indices[i] then indices[i], count = true, count + 1 end end
    if count < a.T.length and not equal(a.zero, b.zero) then return false end
    for i in pairs(indices) do if not equal(A.get(a, i), A.get(b, i)) then return false end end
    return true
end

return A
