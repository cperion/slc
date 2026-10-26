-- Run from the repository root with Neovim 0.10+.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root .. '/tools/tree-sitter-slc')
require('slc_treesitter').setup()
vim.cmd('filetype on')
local query = assert(vim.treesitter.query.get('slc', 'highlights'))
local count = 0
local function parse(text, label)
  local parser = vim.treesitter.get_string_parser(text, 'slc')
  local tree = parser:parse()[1]
  assert(not tree:root():has_error(), label .. ': ' .. tree:root():sexpr())
  count = count + 1
  return tree, parser
end
local function read(path) return table.concat(vim.fn.readfile(path), '\n') .. '\n' end
for _, pattern in ipairs({ 'examples/*.slc', 'lib/*.slc', 'tools/tree-sitter-slc/tests/*.slc' }) do
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do parse(read(path), path) end
end
local fixture = root .. '/tools/tree-sitter-slc/tests/highlights.slc'
vim.cmd.edit(vim.fn.fnameescape(fixture))
assert(vim.bo.filetype == 'slc', '*.slc filetype detection failed')
assert(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()], 'highlighter did not start')
assert(vim.bo.commentstring == '-- %s')
local parser = vim.treesitter.get_parser(0, 'slc')
local tree = parser:parse()[1]
local captured = {}
for id, node in query:iter_captures(tree:root(), 0) do
  local name = query.captures[id]
  local text = vim.treesitter.get_node_text(node, 0)
  captured[name .. ':' .. text] = true
end
for _, pair in ipairs({
  {'keyword', 'struct'}, {'keyword', 'export'}, {'keyword.function', 'do'},
  {'keyword.function', 'endall'}, {'type.builtin', 'U32'}, {'variable.parameter', 'x'},
  {'function', 'inc'}, {'function.call', 'print'}, {'function', 'ok'},
  {'number', '2'}, {'operator', '+'}, {'string.escape', '\\n'},
}) do
  assert(captured[pair[1] .. ':' .. pair[2]], 'missing capture ' .. table.concat(pair, ':'))
end
local string_count, comment_count = 0, 0
for id, node in query:iter_captures(tree:root(), 0) do
  local capture = query.captures[id]
  local first, _, last = node:range()
  if capture == 'string' and first == 7 then
    string_count = string_count + 1
    assert(last == 9, 'long string closed at mismatched delimiter')
  elseif capture == 'comment' and first == 10 then
    comment_count = comment_count + 1
    assert(last == 12, 'long comment ended too early')
  elseif (first >= 8 and first <= 9) or (first >= 11 and first <= 12) then
    error('code capture inside long string/comment: ' .. capture)
  end
end
assert(string_count == 1 and comment_count == 1, 'missing long string/comment captures')
local newline_tree = parse('local x = f a\nx = x + 1\n', 'newline application boundary')
assert(newline_tree:root():named_child_count() == 2, 'name application crossed newline')
assert(newline_tree:root():named_child(1):type() == 'assignment_statement')
parse([[
local run = do(): Unit
    if flag then
        activity do
            activity do
                tick()
            endall
    end
    activity do
        tick()
    end
end
]], 'endall stops at control blocks and does not affect later lambdas')
local ok, missing = pcall(require('slc_treesitter').setup, { parser = root .. '/build/no-such-slc-parser.so' })
assert(not ok and tostring(missing):find('make tree%-sitter'), 'missing parser must produce build guidance')
require('slc_treesitter').setup({ parser = root .. '/build/tree-sitter-slc/slc.so' })
assert(vim.fn.exists('#SlcTreesitter#FileType') == 1)
assert(vim.filetype.match({ filename = 'ordinary.lua' }) == 'lua', 'Lua filetype changed')
-- Exercise real incremental buffer edits and external-scanner state restoration.
local original = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local function compare_fresh(label)
  local incremental = parser:parse()[1]:root()
  local fresh = vim.treesitter.get_string_parser(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n', 'slc'):parse()[1]:root()
  assert(incremental:sexpr() == fresh:sexpr(), 'incremental mismatch: ' .. label)
end
vim.api.nvim_buf_set_text(0, 2, 6, 2, 9, {'increment'})
compare_fresh('rename')
vim.api.nvim_buf_set_lines(0, 0, 0, false, {'-- inserted before long strings and endall'})
compare_fresh('insert line')
vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
compare_fresh('restore')
assert(not parser:parse()[1]:root():has_error())
vim.api.nvim_buf_set_lines(0, 22, 23, false, {'        end', '    end'})
compare_fresh('expand endall')
assert(not parser:parse()[1]:root():has_error())
vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
compare_fresh('restore endall')
vim.api.nvim_buf_set_text(0, 7, 13, 7, 17, {'[=['})
compare_fresh('change long-string delimiter')
vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
compare_fresh('restore long-string delimiter')
-- Incomplete source must recover; a restored buffer must parse cleanly.
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'local f = do(x: U32): U32', 'return x +'})
assert(parser:parse()[1]:root():has_error(), 'incomplete code unexpectedly accepted')
compare_fresh('incomplete source')
vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
compare_fresh('restore after error')
assert(not parser:parse()[1]:root():has_error())
print(('SLC Tree-sitter: %d parse cases passed; highlight captures, filetype, startup, and incremental edits passed'):format(count))
vim.cmd('qa!')
