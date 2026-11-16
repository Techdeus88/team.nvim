local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('plugin cmdone')
vim.api.nvim_create_user_command('Shared', function()
  trace('Shared ran')
end, {})
