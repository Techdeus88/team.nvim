-- triggers.lua: each trigger loads what is behind it, in load order, then replays what
-- fired so the plugin sees it: only the event's new autocmds, the command as typed,
-- the keys as pressed with count and operator. A team's batch loads together on its trigger.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

_G.trace = {}
local function mark(s)
  return function()
    table.insert(_G.trace, s)
  end
end
vim.filetype.add({ extension = { cnc = 'cnc' } })
-- Yours, on the event that loads entery: the replay must not run it again.
vim.api.nvim_create_autocmd('User', { pattern = 'GoX', callback = mark('mine GoX') })
-- Yours, on a key a stub takes over: it comes back when the stub goes.
vim.keymap.set('n', 'gm', mark('my gm'))

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = {
    { H.src('entery'), event = 'User GoX' },
    { H.src('vimmy'), ft = 'cnc' },
    { H.src('argy'), cmd = 'Argy' },
    { H.src('compy'), cmd = 'Comp' },
    { H.src('needy'), cmd = 'ArgyNeed' },
    { H.src('keyy'), keys = 'gK' },
    { H.src('opy'), keys = { { 'L', mode = 'o' } } },
    { H.src('plainy'), keys = { { '<F5>', mark('spec rhs'), desc = 'plainy key' }, 'gm' } },
    { H.src('cmdone'), cmd = 'Shared' },
    { H.src('cmdtwo'), cmd = 'Shared' },
    { H.src('eps'), cmd = 'Taken' },
    { H.src('solo'), cmd = 'Pair' },
    { H.src('pairy'), cmd = 'Pair' },
    { H.src('vimcmd'), cmd = 'VimShared' },
    { H.src('nvim-dashed'), cmd = 'VimShared' },
  },
  teams = {
    go = {
      event = 'User TeamGo',
      pre = mark('pre go'),
      post = mark('post go'),
      plugins = { H.src('libby'), H.src('gamma.nvim') },
    },
  },
})

H.after_startup(function()
  H.wait_later()
  local team = require('team')
  local function st(name)
    return team.get(name).state
  end
  for _, name in ipairs({ 'entery', 'vimmy', 'argy', 'keyy', 'plainy', 'cmdone', 'libby' }) do
    H.eq(st(name), 'installed', name .. ' waits for its trigger')
  end

  -- An event: the plugin's own autocmds run once each, yours not again.
  vim.api.nvim_exec_autocmds('User', { pattern = 'GoX', data = { n = 7 } })
  H.eq(_G.trace, { 'mine GoX', 'plugin entery', 'entery lone 7', 'entery group' }, 'event, replayed')
  H.eq(team.get('entery').reason, 'event User GoX', 'why it loaded')
  _G.trace = {}
  vim.api.nvim_exec_autocmds('User', { pattern = 'GoX' })
  H.eq(_G.trace, { 'mine GoX', 'entery lone nil', 'entery group' }, 'the next time, no stub is left')

  -- A filetype: a Vimscript autocmd calling s: functions, and the plugin's ftplugin.
  vim.cmd.edit(vim.fs.joinpath(H.home, 'x.cnc'))
  H.eq({ st('vimmy'), vim.b.vimmy }, { 'loaded', 1 }, 'ft, its FileType autocmd ran once')
  H.eq(vim.b.cnc_ftplugin, 1, 'and its ftplugin applied, once')
  H.eq(team.get('vimmy').reason, 'ft cnc', 'why it loaded')

  -- A command, as typed: range, bang and arguments.
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c', 'd' })
  vim.cmd('2,3Argy! hello  world')
  H.eq(_G.argy, { args = 'hello  world', bang = true, line1 = 2, line2 = 3, range = 2 }, 'cmd, replayed')
  H.eq(vim.fn.getcompletion('Comp ', 'cmdline'), { 'one', 'two' }, 'completing loads it and asks the real command')
  H.eq(st('compy'), 'loaded', 'compy loaded by completion')
  local ok, err = pcall(vim.cmd --[[@as function]], 'ArgyNeed')
  H.eq(st('needy'), 'loaded', 'the stub takes any arguments and loads the plugin')
  H.ok(not ok and tostring(err):find('E471', 1, true), "then the real command's own error: " .. tostring(err))
  vim.v.errmsg = ''
  _G.trace = {}
  vim.cmd('Shared')
  H.eq(_G.trace, { 'plugin cmdone', 'plugin cmdtwo', 'Shared ran' }, 'both behind one command, then it runs once')

  -- Keys: with a count; in operator-pending mode with the operator; one the spec maps.
  _G.trace = {}
  H.press('3gK')
  H.eq(_G.trace, { 'plugin keyy', 'gK count 3' }, 'keys, replayed with the count')
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abc def' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  H.press('dL')
  H.eq({ st('opy'), vim.api.nvim_get_current_line() }, { 'loaded', '' }, 'the operator applied to the replayed motion')
  _G.trace = {}
  H.press('<F5>')
  H.eq(_G.trace, { 'plugin plainy', 'spec rhs' }, 'a key the spec maps, mapped once loaded, then run')
  H.eq(vim.fn.maparg('<F5>', 'n', false, true).desc, 'plainy key', 'with its options')
  _G.trace = {}
  H.press('gm')
  H.eq(_G.trace, { 'my gm' }, 'your mapping is back once the stub is gone')

  -- A team on a trigger: its batch together, pre before, post after.
  _G.trace = {}
  vim.api.nvim_exec_autocmds('User', { pattern = 'TeamGo' })
  H.eq(_G.trace, { 'pre go', 'plugin libby', 'plugin gamma', 'post go' }, 'the batch on its trigger')
  H.eq({ require('team.state').teams.go.state, team.get('gamma.nvim').reason }, { 'loaded', 'event User TeamGo' }, 'go')

  -- A Vimscript `command` without a bang, while another plugin is behind it too: the stub
  -- has gone before the plugin defines it.
  vim.cmd('VimShared')
  H.eq({ st('vimcmd'), st('nvim-dashed'), vim.g.vimshared }, { 'loaded', 'loaded', 1 }, 'no E174')

  -- Two plugins behind one command; one loads another way and does not define it: the
  -- stub comes back for the other.
  H.eq(team.load('solo'), true, 'solo loads another way')
  _G.trace = {}
  vim.cmd('Pair')
  H.eq({ st('pairy'), _G.trace }, { 'loaded', { 'Pair ran' } }, 'the stub came back and loaded pairy')

  -- A command defined by something else before the plugin loaded is left alone.
  vim.api.nvim_create_user_command('Taken', mark('my Taken'), {})
  H.eq(team.load('eps'), true, 'eps loads')
  H.ok(H.noted('`eps`: its command `:Taken` was defined by something else before it loaded'), 'and says so')
  _G.trace = {}
  vim.cmd('Taken')
  H.eq(_G.trace, { 'my Taken' }, 'your command is still yours')
end)
