-- slc size: where the generated C comes from.
--
-- Applying a word evaluates its body in place, so a large word applied at many
-- sites is that many copies. This measures, per application evaluated in place,
-- how many residual statements it added, and names the words (and the sites)
-- where one `call` would share a copy instead.
local S = require 'slc.stage'

local M = {}

local Profile = {}
Profile.__index = Profile

function M.new()
    return setmetatable({ stack = {}, keys = {}, order = {} }, Profile)
end

-- an application begins: remember where the program stood
function Profile:enter(w, key)
    local entry = { w = w, key = key, start = S.emitted(), child = 0,
                    site = S.site(''):gsub(': $', '') }
    self.stack[#self.stack + 1] = entry
    return entry
end

-- ... and ends: it added `delta` statements, `child` of them in applications inside it
function Profile:leave(entry)
    -- an application that was abandoned (a loop round redone) never leaves; drop it
    while #self.stack > 0 and self.stack[#self.stack] ~= entry do table.remove(self.stack) end
    table.remove(self.stack)
    local delta = S.emitted() - entry.start
    local parent = self.stack[#self.stack]
    if parent then parent.child = parent.child + delta end
    local rec = self.keys[entry.key]
    if not rec then
        rec = { w = entry.w, apps = 0, incl = 0, own = 0, sites = {} }
        self.keys[entry.key] = rec
        self.order[#self.order + 1] = rec
    end
    rec.apps, rec.incl, rec.own = rec.apps + 1, rec.incl + delta, rec.own + (delta - entry.child)
    local site = rec.sites[entry.site]
    if not site then site = { n = 0, incl = 0 }; rec.sites[entry.site] = site end
    site.n, site.incl = site.n + 1, site.incl + delta
end

-- words ranked by what one shared copy per key would save
function Profile:ranked()
    local by_word = {}
    for _, rec in ipairs(self.order) do
        local name = rec.w.name
        local word = by_word[rec.w]
        if not word then
            word = { w = rec.w, name = name, apps = 0, incl = 0, saved = 0, sites = {} }
            by_word[rec.w] = word
        end
        word.apps = word.apps + rec.apps
        word.incl = word.incl + rec.incl
        word.saved = word.saved + (rec.apps > 1 and (rec.incl - rec.incl / rec.apps) or 0)
        for site, s in pairs(rec.sites) do
            local have = word.sites[site]
            if not have then have = { n = 0, incl = 0 }; word.sites[site] = have end
            have.n, have.incl = have.n + s.n, have.incl + s.incl
        end
    end
    local list = {}
    for _, word in pairs(by_word) do list[#list + 1] = word end
    table.sort(list, function(a, b)
        if a.saved ~= b.saved then return a.saved > b.saved end
        return a.name < b.name
    end)
    return list
end

local function function_sizes(c_text)
    local sizes, name, start = {}, nil, nil
    local n = 0
    for line in (c_text .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if not name and line:match('^[%a_].*%)%s*{$') then
            name, start = line:gsub('%s*{$', ''), n
        elseif name and line == '}' then
            sizes[#sizes + 1] = { name = name, lines = n - start + 1 }
            name = nil
        end
    end
    table.sort(sizes, function(a, b) return a.lines > b.lines end)
    return sizes, n
end

local function source_line(path_by_base, site)
    local base, line = site:match('^([^:]+):(%d+)$')
    if not base then return nil end
    local path = path_by_base[base]
    if not path then return nil end
    local f = io.open(path)
    if not f then return nil end
    local n = 0
    for text in f:lines() do
        n = n + 1
        if n == tonumber(line) then f:close(); return (text:gsub('^%s+', '')) end
    end
    f:close()
end

local function commas(n)
    local s = tostring(math.floor(n + 0.5))
    while true do
        local t, k = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
        s = t
        if k == 0 then break end
    end
    return s
end

-- the report, as text
function M.report(profile, c_text, source_path, top)
    local out = {}
    local function say(...) out[#out + 1] = string.format(...) end
    local sizes, c_lines = function_sizes(c_text)
    local src_lines = 0
    local f = io.open(source_path)
    if f then for _ in f:lines() do src_lines = src_lines + 1 end f:close() end
    say('%s: %s lines of C from %d source lines (%.0fx), %d functions',
        source_path, commas(c_lines), src_lines, src_lines > 0 and c_lines / src_lines or 0, #sizes)
    say('')
    say('largest functions')
    for i = 1, math.min(top, #sizes) do
        say('  %7s  %s', commas(sizes[i].lines), sizes[i].name)
    end
    local paths = { [source_path:match('[^/]*$')] = source_path }
    local ranked = profile:ranked()
    say('')
    say('words evaluated in place at several sites (what one `call` would share)')
    say('  %9s  %6s  %9s  %s', 'saves', 'sites', 'each', 'word')
    local shown = 0
    for _, word in ipairs(ranked) do
        -- a word small enough that the call costs as much as the copy is not a candidate
        if word.saved >= 100 and word.incl / word.apps >= 40 and shown < top then
            shown = shown + 1
            say('  %9s  %6d  %9s  %s  (%s)', commas(word.saved), word.apps, commas(word.incl / word.apps),
                word.name, word.w.loc or 'no location')
            local sites = {}
            for site, s in pairs(word.sites) do sites[#sites + 1] = { site = site, n = s.n, incl = s.incl } end
            table.sort(sites, function(a, b) return a.incl > b.incl end)
            for i = 1, math.min(3, #sites) do
                local s = sites[i]
                local text = source_line(paths, s.site)
                say('      %s  x%d  %s statements%s', s.site, s.n, commas(s.incl), text and ('   ' .. text) or '')
            end
        end
    end
    if shown == 0 then say('  none: nothing large is evaluated in place at several sites') end
    say('')
    say('"saves" and "each" count residual statements. Put `call` before the application')
    say('at a site above (`call m:put(k, v)`), or inside the library word that is applied')
    say('everywhere; every `call` of the same word and key then shares one function.')
    return table.concat(out, '\n') .. '\n'
end

function M.run(args, slc, read)
    local top, input = 8, nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == '--top' then i = i + 1; top = tonumber(args[i]) or top
        else input = a end
        i = i + 1
    end
    if not input then io.stderr:write('usage: slc size program.slc|project [--top N]\n'); os.exit(2) end
    local proj = require('slc.project').resolve(input)
    local path = proj.entry
    local profile = M.new()
    S.size_profile = profile
    local ok, c_text = pcall(function() return (slc.compile(read(path), path, { paths = proj.paths })) end)
    S.size_profile = nil
    if not ok then io.stderr:write(tostring(c_text), '\n'); os.exit(1) end
    io.write(M.report(profile, c_text, path, top))
    os.exit(0)
end

-- a one-line note when a program is large, for the commands that print C
function M.note(c_text, source_path)
    local n = select(2, c_text:gsub('\n', ''))
    if n > 20000 then
        io.stderr:write(('slc: note: %s generated %s lines of C; `slc size %s` shows where `call` would share code\n')
            :format(source_path, commas(n), source_path))
    end
end

return M
