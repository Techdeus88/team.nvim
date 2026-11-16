local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('plugin keyy')
vim.keymap.set('n', 'gK', function()
  trace('gK count ' .. vim.v.count)
end)
