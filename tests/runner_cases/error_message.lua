-- Its checks pass, but an error nobody checked for was shown.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')
vim.schedule(function()
  error('boom')
end)
H.after_startup(function() end)
