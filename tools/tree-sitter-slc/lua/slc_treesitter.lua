-- GPL-3.0-or-later. See ../../../COPYING.
local M = {}

-- Uses Neovim's built-in Tree-sitter API, not nvim-treesitter's installer API.
function M.setup(opts)
  opts = opts or {}
  local source = debug.getinfo(1, 'S').source:sub(2)
  local runtime = vim.fn.fnamemodify(source, ':p:h:h')
  local root = vim.fn.fnamemodify(runtime, ':h:h')
  local parser = opts.parser or (root .. '/build/tree-sitter-slc/slc.so')
  if vim.fn.filereadable(parser) ~= 1 then
    error('SLC parser not found: ' .. parser .. '; run make tree-sitter in the SLC repository')
  end
  vim.opt.runtimepath:prepend(runtime)
  vim.treesitter.language.add('slc', { path = parser })
  vim.filetype.add({ extension = { slc = 'slc' } })
  local group = vim.api.nvim_create_augroup('SlcTreesitter', { clear = true })
  local function start(buf)
    vim.treesitter.start(buf, 'slc')
    vim.bo[buf].commentstring = '-- %s'
  end
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'slc',
    callback = function(event) start(event.buf) end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'slc' then start(buf) end
  end
end

return M
