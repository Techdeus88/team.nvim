-- args: notes.md
-- now_if_args with a file on the command line is now: a plugin's own, and a team's.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = { { H.src('eps'), load = 'now_if_args' } },
  teams = { edit = { load = 'now_if_args', plugins = { H.src('libby') } } },
})

H.after_startup(function()
  H.eq(vim.fn.argc(), 1, 'started with a file')
  H.eq(require('team').get('eps').state, 'loaded', "a plugin's own now_if_args")
  H.eq(require('team').get('libby').state, 'loaded', "a team's now_if_args")
  H.eq(require('team.state').teams.edit.state, 'loaded', 'and the team')
end)
