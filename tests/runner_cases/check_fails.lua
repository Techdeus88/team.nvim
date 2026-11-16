local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')
H.after_startup(function()
  H.eq(1, 2, 'one')
end)
