vim.api.nvim_create_user_command('Pair', function()
  _G.trace = _G.trace or {}
  table.insert(_G.trace, 'Pair ran')
end, {})
