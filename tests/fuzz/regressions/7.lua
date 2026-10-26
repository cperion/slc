-- a fuzzer finding, shrunk: every run of f must agree on every vector
-- first mismatch when found: native v2: expected 6744367909165791010, got 422163272906196610
return {
    seed = 7,
    params = { "I16", "I64", "I64", "U8" },
    vectors = { { -17018, 0, -263180099, 5 }, { -32250, -1525350740, 4, 19 }, { 7971, 9, 13, 179 }, { -4, -1924980331, 12, 12 }, { 4633, 315343032, 1344419492, 7 }, { -15, 1909194514, 17, 16 } },
    program = "-- fuzz program 7\
local g1_r\
g1_r = do(n: U32, p1: U32, p2: U32): U64\
    if n == 0 then\
        return U64(0)\
    end\
    return U64(bxor(U64(g1_r(n - 1, U32(0), p2)), U64(n)))\
end\
local g1 = do(p1: U32, p2: U32): U64\
    return g1_r(band(U32(p1), 7), p1, p2)\
end\
local f = do(a1: I16, a2: I64, a3: I64, a4: U8): U64\
    local h: U64 = 17\
    h = h * 31 + U64(I8(U8((U16(I8(I8(I8(a1)))) - U16(I8(I8(I8(g1(U32(19), U32(9))))))))))\
    return h\
end\
",
    ast = nil,
}
