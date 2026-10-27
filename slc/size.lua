-- slc size: where the generated C comes from.
--
-- Applying a word evaluates its body in place, so a large word applied at many
-- sites is that many copies. This measures, per application evaluated in place,
-- how many lines of C it became, and names the words (and the sites) where one
-- `call` would share a copy instead. It also says which module wrote the lines.
--
-- A statement's line count comes from the backend (`Fn:block` in cgen), so the
-- figures are the C that was emitted, not the statements the evaluator produced.
local S = require 'slc.stage'
local root = (debug.getinfo(1, 'S').source:match('^@(.*)/[^/]*$') or '.'):gsub('/slc$', '')

local M = {}

local Profile = {}
Profile.__index = Profile

function M.new()
    return setmetatable({ stack = {}, apps = {}, modules = {}, keys = {} }, Profile)
end

-- the module being written: the innermost word under evaluation, or the body of
-- a materialized function (stage.lua pushes that one itself)
function Profile:push(name) self.modules[#self.modules + 1] = name end
function Profile:pop() self.modules[#self.modules] = nil end
function Profile:module() return self.modules[#self.modules] end

-- an application begins: remember where the program stood
function Profile:enter(w, key)
    local entry = { w = w, key = key, start = S.emitted(), site = S.size_site(),
                    fn = S.size_function(), module = S.size_module(w.loc) }
    self.stack[#self.stack + 1] = entry
    self:push(entry.module)
    return entry
end

-- ... and ends: remember the range of residual statements it covers. The line
-- counts they became are known only after the backend runs (see `measure`).
function Profile:leave(entry)
    -- an application that was abandoned (a loop round redone) never leaves; drop it
    while #self.stack > 0 and self.stack[#self.stack] ~= entry do table.remove(self.stack) end
    table.remove(self.stack)
    self:pop()
    local rec = self.keys[entry.key]
    if not rec then rec = { w = entry.w }; self.keys[entry.key] = rec end
    self.apps[#self.apps + 1] = { key = entry.key, w = entry.w, site = entry.site or '',
                                  fn = entry.fn, module = entry.module,
                                  first = entry.start + 1, last = S.emitted() }
end

-- after emission: lines of each application, and the running total per statement
function Profile:measure()
    local stream = S.emitted()
    local prefix, hot = { [0] = 0 }, { [0] = 0 }
    for i = 1, stream do
        local st = S.statement(i)
        prefix[i] = prefix[i - 1] + (st.lines or 0)
        hot[i] = hot[i - 1] + (st.loop and 1 or 0)
    end
    self.prefix = prefix
    for _, a in ipairs(self.apps) do
        -- an undone attempt (`--profile share`) takes its statements with it
        local last = math.min(a.last, stream)
        a.lines = last >= a.first and (prefix[last] - prefix[a.first - 1]) or 0
        -- inside a loop the shared body would be called per iteration
        a.hot = last >= a.first and (hot[last] > hot[a.first - 1]) or false
    end
end

-- did this application reach the C? the runtime stages words a program may never
-- name; what a function nothing exports or calls emitted is not part of the program
local function reached(a)
    return a.fn == nil or a.fn.emitted == true
end

-- words ranked by what one shared copy per key would save, in lines
function Profile:ranked()
    local by_word = {}
    for _, a in ipairs(self.apps) do
        if reached(a) and a.lines > 0 then
            local word = by_word[a.w]
            if not word then
                word = { w = a.w, name = a.w.name, apps = 0, lines = 0, saved = 0, hot = 0,
                         sites = {} }
                by_word[a.w] = word
            end
            word.apps, word.lines = word.apps + 1, word.lines + a.lines
            if a.hot then word.hot = word.hot + 1 end
            local site = word.sites[a.site]
            if not site then site = { n = 0, lines = 0, hot = false }; word.sites[a.site] = site end
            site.n, site.lines = site.n + 1, site.lines + a.lines
            if a.hot then site.hot = true end
        end
    end
    -- what one shared copy per specialization key would remove
    local per_word_key = {}
    for _, a in ipairs(self.apps) do
        if reached(a) and a.lines > 0 then
            local wk = per_word_key[a.w]
            if not wk then wk = {}; per_word_key[a.w] = wk end
            local k = wk[a.key]
            if not k then k = { apps = 0, lines = 0 }; wk[a.key] = k end
            k.apps, k.lines = k.apps + 1, k.lines + a.lines
        end
    end
    for w, keys in pairs(per_word_key) do
        local saved = 0
        for _, k in pairs(keys) do
            if k.apps > 1 then saved = saved + k.lines - k.lines / k.apps end
        end
        by_word[w].saved = saved
    end
    local list = {}
    for _, word in pairs(by_word) do list[#list + 1] = word end
    table.sort(list, function(a, b)
        if a.saved ~= b.saved then return a.saved > b.saved end
        return a.name < b.name
    end)
    return list
end

-- the C, by the module that wrote it
function Profile:by_module()
    local totals, order, counted = {}, {}, 0
    for i = 1, S.emitted() do
        local st = S.statement(i)
        local lines = st.lines or 0
        if lines > 0 then
            local name = st.module or '(generated)'
            if not totals[name] then totals[name] = 0; order[#order + 1] = name end
            totals[name] = totals[name] + lines
            counted = counted + lines
        end
    end
    table.sort(order, function(a, b) return totals[a] > totals[b] end)
    local list = {}
    for _, name in ipairs(order) do list[#list + 1] = { name = name, lines = totals[name] } end
    return list, counted
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

-- where the site string names a file: the program's own file by base name, or a
-- library/runtime module by its path relative to the compiler's root
local function source_line(path_by_base, site)
    local base, line = site:match('^([^:]+):(%d+)$')
    if not base then return nil end
    local path = path_by_base[base]
    if not path and base:match('^[%w_]+/[%w_/]+%.slc$') then path = root .. '/' .. base end
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
    profile:measure()
    local out = {}
    local function say(...) out[#out + 1] = string.format(...) end
    local sizes, c_lines = function_sizes(c_text)
    local src_lines = 0
    local f = io.open(source_path)
    if f then for _ in f:lines() do src_lines = src_lines + 1 end f:close() end
    say('%s: %s lines of C from %d source lines (%.0fx), %d functions',
        source_path, commas(c_lines), src_lines, src_lines > 0 and c_lines / src_lines or 0, #sizes)
    local modules, counted = profile:by_module()
    if #modules > 0 then
        say('')
        say('where the C comes from')
        local limit = math.max(top, 8)
        for i, m in ipairs(modules) do
            if i <= limit then
                say('  %8s  %3.0f%%  %s', commas(m.lines), 100 * m.lines / c_lines, m.name)
            elseif i == limit + 1 then
                local rest, other = 0, 0
                for j = i, #modules do rest, other = rest + modules[j].lines, other + 1 end
                say('  %8s  %3.0f%%  %d further modules', commas(rest), 100 * rest / c_lines, other)
            end
        end
        local rest = c_lines - counted
        if rest > 0 then
            say('  %8s  %3.0f%%  declarations, headers and function prologues',
                commas(rest), 100 * rest / c_lines)
        end
    end
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
        -- a word of a line or two, copied a handful of times, is not worth a boundary;
        -- a small body copied hundreds of times is, and the `each` column says which
        if word.saved >= 100 and word.lines / word.apps >= 4 and shown < top then
            shown = shown + 1
            say('  %9s  %6d  %9s  %s  (%s)%s', commas(word.saved), word.apps,
                commas(word.lines / word.apps), word.name, word.w.loc or 'no location',
                word.hot == word.apps and '  every site is in a loop' or '')
            local sites = {}
            for site, s in pairs(word.sites) do
                -- a runtime word may have no site of the program's own
                if site ~= '' then
                    sites[#sites + 1] = { site = site, n = s.n, lines = s.lines, hot = s.hot }
                end
            end
            table.sort(sites, function(a, b) return a.lines > b.lines end)
            for i = 1, math.min(3, #sites) do
                local s = sites[i]
                local text = source_line(paths, s.site)
                say('      %s  x%d  %s lines%s%s', s.site, s.n, commas(s.lines),
                    s.hot and '  (in a loop)' or '', text and ('   ' .. text) or '')
            end
        end
    end
    if shown == 0 then say('  none: nothing large is evaluated in place at several sites') end
    say('')
    say('"saves" and "each" count lines of C. Put `call` before the application at a')
    say('site above (`call m:put(k, v)`), or inside the library word that is applied')
    say('everywhere; every `call` of the same word and key then shares one function.')
    say('A call site and its argument setup add lines back, so measure the C after a')
    say('change: `saves` is the copies one shared function removes, not the net diff.')
    return table.concat(out, '\n') .. '\n'
end

-- compile one program under one `call` policy, with a profile attached
local function compile_with(slc, read, path, proj, policy)
    local profile = M.new()
    S.call_policy, S.call_skipped = policy, 0
    S.size_profile = profile
    local started = os.clock()
    local ok, c_text = pcall(function() return (slc.compile(read(path), path, { paths = proj.paths })) end)
    local seconds = os.clock() - started
    S.call_policy = 'written'
    S.size_profile = nil
    local skipped = S.call_skipped
    S.call_skipped = 0
    return ok, c_text, seconds, skipped, profile
end

-- the three profiles side by side: the range a `call` decision moves within
local function compare(slc, read, path, proj)
    local order = { 'share', 'written', 'inline' }
    local got = {}
    for _, policy in ipairs(order) do
        local ok, c_text, seconds, skipped, profile = compile_with(slc, read, path, proj, policy)
        got[policy] = { ok = ok, out = c_text, seconds = seconds, skipped = skipped }
        if ok then
            local sizes, lines = function_sizes(c_text)
            got[policy].lines, got[policy].functions = lines, #sizes
        end
    end
    local src_lines = 0
    local src = io.open(path)
    if src then for _ in src:lines() do src_lines = src_lines + 1 end src:close() end
    local out = {}
    local function say(...) out[#out + 1] = string.format(...) end
    say('%s: %d source lines, compiled three ways', path, src_lines)
    say('')
    say('  %-8s %10s %11s %9s  %s', 'profile', 'lines of C', 'functions', 'compile', 'how `call` is read')
    local meaning = {
        share = 'every application that can cross one',
        written = 'as written',
        inline = 'ignored: everything in place',
    }
    for _, policy in ipairs(order) do
        local r = got[policy]
        if r.ok then
            say('  %-8s %10s %11s %9s  %s', policy, commas(r.lines), commas(r.functions),
                ('%.1f s'):format(r.seconds), meaning[policy])
            if policy == 'share' and r.skipped > 0 then
                say('  %-8s %10s %11s %9s  %s', '', '', '', '',
                    ('%s applications kept in place (a callback, or an argument that cannot cross)'):format(
                        commas(r.skipped)))
            end
        else
            -- sharing everything is best effort: a program whose applications cannot
            -- all cross a boundary has no all-shared form, and that is a finding
            say('  %-8s %10s %11s %9s  %s', policy, '-', '-', ('%.1f s'):format(r.seconds),
                ('no all-shared form: %s'):format(tostring(r.out):match('[^\n]*')))
        end
    end
    local inline, written, share = got.inline, got.written, got.share
    if inline.ok and written.ok and share.ok then
        say('')
        -- neither extreme is a target: the inlined end is a pile of copies, the shared
        -- end is a call on every path that reaches one. The middle is where a program
        -- wants to be, and the geometric mean is the fair middle for sizes
        if share.lines > written.lines then
            -- small words with a prologue: the boundary costs more than the copy
            say('sharing everything makes this program bigger: %s lines against %s as written,',
                commas(share.lines), commas(written.lines))
            say('so here every boundary costs more than the copy it removes.')
            return table.concat(out, '\n') .. '\n'
        end
        local geo = math.sqrt(inline.lines * share.lines)
        local mean = (inline.lines + share.lines) / 2
        say('the extremes bracket this program: %s lines with everything in place, %s all-shared;',
            commas(inline.lines), commas(share.lines))
        say('their geometric mean is %s and their arithmetic mean %s.', commas(geo), commas(mean))
        local shrink = inline.lines / math.max(1, written.lines)
        if shrink < 1.05 then
            say('as written is %s: %.2fx the all-shared end and the inlined one.',
                commas(written.lines), written.lines / math.max(1, share.lines))
        else
            say('as written is %s: %.2fx the all-shared end, %.1fx below the inlined one.',
                commas(written.lines), written.lines / math.max(1, share.lines), shrink)
        end
        if written.lines > inline.lines then
            say('above both extremes: here a `call` costs more than the copies it shares.')
        elseif written.lines > geo then
            say('above the geometric mean: the report names the sites; sharing one there')
            say('buys C with a call on the path that reaches it.')
        else
            say('below both means: sharing more would buy size with calls on the paths that')
            say('reach them, which is between the extremes and where a program wants to be.')
        end
    end
    return table.concat(out, '\n') .. '\n'
end

function M.run(args, slc, read)
    local top, input, policy, want_compare = 8, nil, 'written', false
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == '--top' then i = i + 1; top = tonumber(args[i]) or top
        elseif a == '--profile' then
            i = i + 1
            policy = args[i]
            if policy ~= 'write' and policy ~= 'inline' and policy ~= 'share' and policy ~= 'written' then
                io.stderr:write('slc size: --profile is written, inline or share\n')
                os.exit(2)
            end
            if policy == 'write' then policy = 'written' end
        elseif a == '--compare' then want_compare = true
        else input = a end
        i = i + 1
    end
    if not input then
        io.stderr:write('usage: slc size program.slc|project [--top N] [--profile written|inline|share] [--compare]\n')
        os.exit(2)
    end
    local proj = require('slc.project').resolve(input)
    local path = proj.entry
    if want_compare then
        io.write(compare(slc, read, path, proj))
        os.exit(0)
    end
    local ok, c_text, _, skipped, profile = compile_with(slc, read, path, proj, policy)
    if not ok then io.stderr:write(tostring(c_text), '\n'); os.exit(1) end
    if policy ~= 'written' then
        io.write(('%s: `call` read as %s; %s applications kept in place (a callback, or an argument that cannot cross)\n\n')
            :format(path, policy, commas(skipped)))
    end
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
