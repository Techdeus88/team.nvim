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

  vim.cmd('Team')
  local status = H.text()
  H.eq(vim.api.nvim_buf_get_name(0), 'team://status', 'the status view')
  H.ok(status:find('core  loaded  trigger  2 members', 1, true), 'a team row:\n' .. status)
  H.ok(status:find('libby%s+loaded%s+batch%s+:Team load'), 'a plugin row')
  H.ok(status:find('beta.nvim%s+disabled%s+%S+%s+team `off`'), 'why one is off')
  H.eq(vim.bo.modifiable, false, 'read-only')
  H.press('q')
  H.eq(vim.fn.bufnr('team://status'), -1, 'q closes it')

  vim.cmd('Team profile')
  local profile = H.text()
  H.ok(profile:find('setup [%d.]+ ms: specs'), 'setup steps:\n' .. profile)
  H.ok(profile:find('libby%s+core%s+[%d.]+ ms%s+packadd [%d.]+ ms%s+config [%d.]+ ms%s+:Team load'), 'plugin cost')
  H.ok(profile:find('teams, slowest first', 1, true), 'team costs')
  vim.cmd('Team profile')
  H.eq(#vim.tbl_filter(function(w)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == 'team://profile'
  end, vim.api.nvim_list_wins()), 1, 'again: the same window, refreshed')

  vim.cmd('Team log')
  H.ok(H.text():find('DEBUG  loaded `libby` (:Team load)', 1, true), 'the log:\n' .. H.text())
end)
