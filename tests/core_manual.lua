package.path = '/home/claude/slc/?.lua;' .. package.path
local S = require 'slc.stage'
local G = require 'slc.cgen'
local T = require 'slc.types'
local U32, Bool = T.U32, T.Bool

local affine = S.word{ name='affine', params={{'a',U32},{'b',U32},{'x',U32}}, result=U32,
  body=function(a,b,x) S.ret(a*x+b) end }
local transform = affine(4, 3)
print('known:', affine(4,3,10))

local use = S.word{ name='use', params={{'x',U32}}, result=U32, body=function(x) S.ret(affine(4,3,x)) end }
S.export(use, 'use')

local choose = S.word{ name='choose', params={{'enabled',Bool},{'k',U32},{'x',U32}}, result=U32,
  body=function(enabled,k,x)
    S.if_(enabled, function() S.ret(x*k) end)
    if S.dead() then return end
    S.ret(x+k)
  end }
print('choose known:', choose(true, 8, 7))
S.export(choose(true, 8), 'times8')
local use2 = S.word{ name='use2', params={{'flag',Bool},{'x',U32}}, result=U32,
  body=function(flag,x) S.ret(choose(flag, 8, x)) end }
S.export(use2, 'use2')

local f = S.word{ name='f', params={{'flag',Bool},{'x',U32}}, result=U32, body=function(flag, x)
  local y = S.decl(U32, x, 'y')
  S.if_(flag, function() S.set(y, y*2) end, function() S.set(y, y+1) end)
  S.ret(y)
end }
S.export(f, 'f')

local tri = S.word{ name='triangular', params={{'n',U32}}, result=U32, body=function(n)
  local total = S.decl(U32, 0, 'total')
  S.for_(U32, 1, n, 1, function(i) S.set(total, total + i) end)
  S.ret(total)
end}
print('tri 5:', tri(5))
S.export(tri, 'runtime_sum')

-- recursion: dynamic recursion materializes
local fact
fact = S.word{ name='fact', params={{'n',U32}}, result=U32, body=function(n)
  S.if_(S.le(n, 1), function() S.ret(1) end)
  if S.dead() then return end
  S.ret(n * fact(n - 1))
end}
print('fact 10:', fact(10))
S.export(fact, 'fact')

io.write(G.emit(S.module))
