-- phases: 2
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')
H.after_startup(function()
  H.ok(H.phase == 1, 'only phase 1 passes')
end)
