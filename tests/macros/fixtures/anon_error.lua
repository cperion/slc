local function k (a) return function (g) return g(a) end end
k(1)(function (n)
    return n.bad()
end)
