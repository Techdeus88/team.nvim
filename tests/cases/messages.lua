-- Warnings and errors of one tick show as one line through vim.notify, short enough for
-- the command line so nothing waits at "Press ENTER"; the whole text is in the log.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {},
  teams = {
    tools = { load = 'now', plugins = { { H.src('broken.nvim'), opts = {} }, { H.src('nosetup'), config = true } } },
  },
})

H.after_startup(function()
  H.wait_later()
  H.eq(#H.notes, 1, 'two failures during init.lua: one message')
  local n = H.notes[1]
  H.eq(n.level, vim.log.levels.ERROR, 'at the worst level')
  H.ok(n.msg:find('^team%.nvim: 2 problems: `broken%.nvim`'), n.msg)
  H.ok(vim.fn.strdisplaywidth(n.msg) <= vim.o.columns - 30, 'clear of the ruler: ' .. n.msg)
  H.ok(n.msg:find('(:Team log)', 1, true), 'pointing at the log')
  H.ok(not n.msg:find('\n', 1, true) and vim.fn.strdisplaywidth(n.msg) <= vim.o.columns, 'one line that fits')
  H.eq(#H.problems(), 2, 'the log has both, whole')

  H.notes = {}
  require('team.events').report('short one', vim.log.levels.WARN)
  H.eq(#H.notes, 0, 'shown on the next tick')
  vim.wait(20)
  H.eq(H.notes, { { msg = 'team.nvim: short one', level = vim.log.levels.WARN } }, 'one short message as it is')
end)
