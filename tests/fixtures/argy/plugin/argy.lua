local function trace(s)
  _G.trace = _G.trace or {}
  table.insert(_G.trace, s)
end
trace('plugin argy')
vim.api.nvim_create_user_command('Argy', function(a)
  _G.argy = { args = a.args, bang = a.bang, line1 = a.line1, line2 = a.line2, range = a.range }
end, { nargs = '*', bang = true, range = true })
