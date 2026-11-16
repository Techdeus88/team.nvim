local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('plugin entery')
-- One autocmd alone, one in a group of its own, on the event that loads it.
vim.api.nvim_create_autocmd('User', {
  pattern = 'GoX',
  callback = function(ev)
    trace('entery lone ' .. tostring(ev.data and ev.data.n))
  end,
})
vim.api.nvim_create_autocmd('User', {
  group = vim.api.nvim_create_augroup('entery', {}),
  pattern = 'GoX',
  callback = function()
    trace('entery group')
  end,
})
