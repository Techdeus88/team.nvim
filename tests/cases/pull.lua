-- A trigger team that a `later` team needs is pulled into the queue: its batch loads in
-- turn, ahead of the team that needs it, and its stub goes so the real command works.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {},
  teams = {
    trigt = { cmd = 'Argy', plugins = { H.src('argy') } },
    needer = { load = 'later', deps = { 'trigt' }, plugins = { H.src('libby') } },
  },
})

H.after_startup(function()
  H.wait_later()
  local team = require('team')
  H.ok(H.noted('team `trigt` loads at `later`, not `trigger`, because team `needer` needs it'), 'the pull warns')
  H.eq({ team.get('argy').state, team.get('argy').reason, team.get('argy').seq }, { 'loaded', 'later', 1 }, 'pulled')
  H.eq(team.get('libby').seq, 2, 'ahead of the team that needs it')
  vim.cmd('Argy real')
  H.eq(_G.argy.args, 'real', 'the real command, no stub left')
end)
