-- :Team and its subcommands: load, the views, completion, and errors the way Neovim
-- shows them for a command you typed.
local H = dofile(vim.env.TEAM_ROOT .. '/tests/helpers.lua')

require('team').setup({
  confirm = false,
  teams_dir = false,
  spec = { { H.src('eps'), load = 'trigger' }, { H.src('solo'), team = 'eps', load = 'trigger' } },
  teams = {
    core = { load = 'trigger', plugins = { H.src('libby'), H.src('gamma.nvim') } },
    eps = { load = 'trigger', plugins = { H.src('delta') } },
    off = { enabled = false, plugins = { H.src('beta.nvim') } },
  },
})

---@param cmd string
---@return string? err
local function err_of(cmd)
  local ok, err = pcall(vim.cmd --[[@as function]], cmd)
  vim.v.errmsg = ''
  return not ok and tostring(err) or nil
end

H.after_startup(function()
  H.wait_later()
  local team = require('team')

  H.eq(
    vim.fn.getcompletion('Team ', 'cmdline'),
    { 'clean', 'disable', 'enable', 'load', 'log', 'profile', 'update' },
    'subcommands'
  )
  H.eq(vim.fn.getcompletion('Team lo', 'cmdline'), { 'load', 'log' }, 'by prefix')
  H.eq(vim.fn.getcompletion('Team load ', 'cmdline'), {
    'core',
    'eps',
    'default',
    'libby',
    'gamma.nvim',
    'delta',
    'solo',
    'eps',
  }, 'load: teams, then plugins in load order, not loaded')
  H.eq(vim.fn.getcompletion('Team enable ', 'cmdline'), { 'off' }, 'enable: teams that are off')
  H.eq(vim.fn.getcompletion('Team disable c', 'cmdline'), { 'core' }, 'disable: teams that are on')

  vim.cmd('Team load core')
  H.eq({ team.get('libby').state, team.get('gamma.nvim').state }, { 'loaded', 'loaded' }, 'a team')
  H.eq(team.get('libby').reason, ':Team load', 'why')
  vim.cmd('Team load solo')
  H.eq({ team.get('solo').state, team.get('delta').state }, { 'loaded', 'installed' }, 'a plugin')
  vim.cmd('Team load eps')
  H.eq({ team.get('delta').state, team.get('eps').state }, { 'loaded', 'installed' }, 'a team and a plugin: the team')

  H.ok(err_of('Team load nope'):find('no team or plugin is named `nope`', 1, true), 'unknown name')
  H.ok(err_of('Team load'):find('load what?', 1, true), 'nothing to load')
  H.ok(err_of('Team frob'):find('unknown subcommand `frob`; :Team clean|disable', 1, true), 'unknown subcommand')
  H.ok(err_of('Team enable'):find('enable which team?', 1, true), 'enable without a team')

  -- :Team opens the window; :Team profile and :Team log switch it to their view.
  vim.cmd('Team')
  local ui = require('team.ui')
  local buf, win = ui.handles()
  H.eq({ ui.is_open(), vim.api.nvim_get_current_win() == win }, { true, true }, 'the window, focused')
  H.ok(H.text(buf):find('core%s+loaded%s+on demand%s+2/2'), 'a team row:\n' .. H.text(buf))
  vim.cmd('Team profile')
  H.eq(select(2, ui.handles()), win, 'the same window')
  H.ok(H.text(buf):find('setup [%d.]+ ms: specs'), 'on the profile:\n' .. H.text(buf))
  H.ok(H.text(buf):find('plugin%s+team%s+ms%s+packadd%s+config%s+why'), 'the plugin table')
  H.ok(H.text(buf):find('libby%s+core%s+[%d.]+%s+[%d.]+%s+[%d.]+%s+:Team load'), 'a plugin cost row')
  vim.cmd('Team log')
  H.ok(H.text(buf):find('DEBUG  loaded `libby` (:Team load)', 1, true), 'on the log:\n' .. H.text(buf))
  H.press('q')
  H.eq(ui.is_open(), false, 'q closes it')
end)
