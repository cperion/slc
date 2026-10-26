package.path = '/home/claude/slc/?.lua;' .. package.path
local S = require 'slc.stage'
local G = require 'slc.cgen'
local T = require 'slc.types'
local U32, Bool, Unit, I32 = T.U32, T.Bool, T.Unit, T.I32

-- Box: struct + methods, eliminated when private
local function Box(t)
  local B = S.struct('Box', {{'value', t}})
  S.method(B, 'get', { params={}, result=t, body=function(self) S.ret(self.value) end })
  S.method(B, 'set', { params={{'value', t}}, result=Unit, body=function(self, value) S.setindex(self, 'value', value) end })
  return B
end
local NumberBox = Box(U32)
local affine = S.word{ name='affine', params={{'a',U32},{'b',U32},{'x',U32}}, result=U32, body=function(a,b,x) S.ret(a*x+b) end }
local transform = affine(4,3)
local process = S.word{ name='process', params={{'enabled',Bool},{'x',U32}}, result=U32, body=function(enabled, x)
  local box = S.decl(NumberBox, NumberBox{ value = transform(x) }, 'box')
  S.if_(enabled, function() box:set(box:get() * 2) end)
  if S.dead() then return end
  S.ret(box:get())
end}
local enabled_process = process(true)
print('answer', enabled_process(10))
local entry = S.word{ name='entry', params={{'x',U32}}, result=U32, body=function(x) S.ret(enabled_process(x)) end }
S.export(entry, 'entry')

-- dynamic box: escape through a recursive method call by reference
local Counter = S.struct('Counter', {{'value', U32}})
S.method(Counter, 'add', { params={{'n',U32}}, result=Unit, body=function(self, n) S.setindex(self, 'value', self.value + n) end })
local count_to = S.word{ name='count_to', params={{'n',U32}}, result=U32, body=function(n)
  local c = S.decl(Counter, Counter{ value = 0 }, 'c')
  local i = S.decl(U32, 0, 'i')
  S.while_(function() return S.lt(i, n) end, function()
    c:add(i)
    S.set(i, i + 1)
  end)
  S.ret(c.value)
end}
print('count_to 5', count_to(5))
S.export(count_to, 'count_to')

-- and / or with effects
local log = S.extern('log_u32', {U32}, Bool)
local check = S.word{ name='check', params={{'a',Bool},{'x',U32}}, result=Bool, body=function(a, x)
  local p = S.and_(a, function() return S.gt(x, 3) end)
  local q = S.or_(p, function() return log(x) end)
  S.ret(q)
end}
S.export(check, 'check')

-- refs: a word taking a Ref, materialized through export
local bump = S.word{ name='bump', params={{'r', T.ref(U32)}, {'k', U32}}, result=Unit, body=function(r, k)
  S.set(r.place, r + k)
end}
local use_bump = S.word{ name='use_bump', params={{'x',U32}}, result=U32, body=function(x)
  local v = S.decl(U32, x, 'v')
  bump(S.Ref(v), 5)
  bump(S.Ref(v), 6)
  S.ret(v)
end}
S.export(use_bump, 'use_bump')
S.export(bump, 'bump')

-- signed folding rejects UB
local ok, err = pcall(function()
  local w = S.word{ name='ov', params={{'a',I32}}, result=I32, body=function(a) S.ret(a * 2) end }
  return w(2147483647)
end)
print('UB check:', ok, err)

io.write(G.emit(S.module))
