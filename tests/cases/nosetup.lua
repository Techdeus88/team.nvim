-- Without setup(): :Team says what to do, and :checkhealth team warns.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local ok, err = pcall(vim.cmd --[[@as function]], 'Team')
  vim.v.errmsg = ''
  H.ok(not ok and tostring(err):find("setup() has not run: require('team').setup({ ... })", 1, true), tostring(err))
  local text = H.health('team')
  H.ok(text:find('WARNING setup() has not run', 1, true), 'health warns:\n' .. text)
  H.ok(text:find('OK git version', 1, true), 'and checks git')
end)
